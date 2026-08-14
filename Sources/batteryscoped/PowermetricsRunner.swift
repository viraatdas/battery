import BatteryCore
import Foundation

/// Runs `/usr/bin/powermetrics` once and hands back its plist bytes.
///
/// powermetrics is root-only and can hang if the system is wedged, so every
/// invocation is bounded by a watchdog and every failure is a returned error
/// rather than a thrown one — the daemon must survive a broken powermetrics.
public enum PowermetricsRunner {

    public static let executablePath = "/usr/bin/powermetrics"

    public enum RunFailure: Error, CustomStringConvertible {
        case notPermitted
        case notInstalled
        case launchFailed(String)
        case timedOut(seconds: Double)
        case exited(code: Int32, stderr: String)
        case emptyOutput

        public var description: String {
            switch self {
            case .notPermitted:
                return "powermetrics requires root"
            case .notInstalled:
                return "powermetrics not found at \(PowermetricsRunner.executablePath)"
            case .launchFailed(let message):
                return "could not launch powermetrics: \(message)"
            case .timedOut(let seconds):
                return "powermetrics timed out after \(seconds)s"
            case .exited(let code, let stderr):
                let detail = stderr.isEmpty ? "" : ": \(stderr)"
                return "powermetrics exited \(code)\(detail)"
            case .emptyOutput:
                return "powermetrics produced no output"
            }
        }
    }

    /// True when this process can actually run powermetrics.
    public static func isAvailable(isRoot: Bool = (getuid() == 0)) -> Bool {
        isRoot && FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// Takes one `tasks` sample. `sampleMs` is powermetrics' own averaging
    /// window; the call blocks for roughly that long.
    public static func sampleTasks(
        sampleMs: Int = 1000,
        timeout: TimeInterval = 20
    ) -> Result<Data, RunFailure> {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return .failure(.notInstalled)
        }
        guard getuid() == 0 else { return .failure(.notPermitted) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--samplers", "tasks",
            "--show-process-energy",
            "--format", "plist",
            "-i", String(max(100, sampleMs)),
            "-n", "1",
        ]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        // Drain both pipes off-thread: a full 64 KB pipe buffer would otherwise
        // block powermetrics forever and deadlock the watchdog with it.
        let collector = OutputCollector()
        let group = DispatchGroup()
        for (handle, isStdout) in [(output.fileHandleForReading, true), (errors.fileHandleForReading, false)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = handle.readDataToEndOfFile()
                collector.append(data, isStdout: isStdout)
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            return .failure(.timedOut(seconds: timeout))
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)

        let stdout = collector.stdout
        let stderr = String(decoding: collector.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // powermetrics can exit non-zero *after* writing a usable sample, so
        // only treat a bad status as fatal when there is nothing to parse.
        if stdout.isEmpty {
            if process.terminationStatus != 0 {
                return .failure(.exited(code: process.terminationStatus, stderr: stderr))
            }
            return .failure(.emptyOutput)
        }
        return .success(stdout)
    }

    /// Thread-safe accumulator for the two pipe readers.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()

        func append(_ data: Data, isStdout: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isStdout {
                stdoutData.append(data)
            } else {
                stderrData.append(data)
            }
        }

        var stdout: Data {
            lock.lock()
            defer { lock.unlock() }
            return stdoutData
        }

        var stderr: Data {
            lock.lock()
            defer { lock.unlock() }
            return stderrData
        }
    }
}
