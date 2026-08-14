import BatteryCore
import Foundation

/// Parses the plist that `powermetrics --samplers tasks --format plist` emits.
///
/// Key names drift between macOS releases, so every field is looked up through
/// a list of aliases and every task is parsed defensively: a task we cannot make
/// sense of is dropped rather than failing the whole sample. The daemon runs
/// unattended for weeks, so a surprising plist must degrade, never crash.
public enum PowermetricsParser {

    public enum ParseError: Error, CustomStringConvertible {
        case notAPropertyList
        case unexpectedRoot

        public var description: String {
            switch self {
            case .notAPropertyList:
                return "powermetrics output was not a property list"
            case .unexpectedRoot:
                return "powermetrics property list root was not a dictionary"
            }
        }
    }

    /// Aliases seen across macOS versions, most specific first.
    static let nameKeys = ["name", "task_name", "process_name", "command"]
    static let pidKeys = ["pid", "task_pid", "process_id"]
    static let energyKeys = [
        "energy_impact",
        "energy_impact_per_s",
        "task_energy_impact",
        "energy",
    ]
    static let cpuKeys = [
        "cputime_ms_per_s",
        "cputime_sample_ms_per_s",
        "cputime_per_s",
        "cpu_ms_per_s",
    ]
    static let pathKeys = ["path", "bundle_path", "executable_path", "bundle_identifier"]

    /// Parses process samples out of raw powermetrics plist bytes.
    ///
    /// Throws only when the payload is not a plist dictionary at all; anything
    /// wrong *inside* a well-formed plist is skipped silently.
    public static func parse(_ data: Data, timestampMs: Int64) throws -> [ProcessSample] {
        guard !data.isEmpty else { throw ParseError.notAPropertyList }

        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw ParseError.notAPropertyList
        }
        guard let root = object as? [String: Any] else { throw ParseError.unexpectedRoot }

        // "tasks" is the documented key; "coalitions" shows up when powermetrics
        // groups by coalition instead. Accept either shape.
        let rawTasks = (root["tasks"] as? [Any]) ?? (root["coalitions"] as? [Any]) ?? []

        var samples: [ProcessSample] = []
        samples.reserveCapacity(rawTasks.count)
        for entry in rawTasks {
            guard let task = entry as? [String: Any],
                  let sample = self.sample(from: task, timestampMs: timestampMs) else { continue }
            samples.append(sample)
        }
        return samples
    }

    /// Converts one task dictionary, or nil when it is too broken to use.
    ///
    /// A usable task needs a non-empty name; everything else has a defensible
    /// default (an absent counter means zero, not "drop the process").
    static func sample(from task: [String: Any], timestampMs: Int64) -> ProcessSample? {
        guard let name = string(task, nameKeys)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty else { return nil }

        let pidValue = number(task, pidKeys) ?? -1
        let pid: Int32
        if pidValue.isFinite, pidValue >= Double(Int32.min), pidValue <= Double(Int32.max) {
            pid = Int32(pidValue)
        } else {
            pid = -1
        }

        let bundlePathHint = string(task, pathKeys)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        return ProcessSample(
            timestampMs: timestampMs,
            pid: pid,
            name: name,
            bundlePathHint: bundlePathHint,
            energyImpact: finite(number(task, energyKeys)),
            cpuMsPerS: finite(number(task, cpuKeys)),
            category: Categorizer.categorize(name: name, bundlePathHint: bundlePathHint)
        )
    }

    // MARK: - Helpers

    private static func finite(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return value
    }

    private static func string(_ task: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = task[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func number(_ task: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            switch task[key] {
            case let value as NSNumber:
                return value.doubleValue
            case let value as String:
                if let parsed = Double(value) { return parsed }
            default:
                continue
            }
        }
        return nil
    }
}

/// Free-function form of `PowermetricsParser.parse`, for callers that just want
/// bytes in and samples out.
public func parsePowermetricsPlist(_ data: Data, timestampMs: Int64) throws -> [ProcessSample] {
    try PowermetricsParser.parse(data, timestampMs: timestampMs)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
