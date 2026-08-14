import BatteryCore
import Foundation
import IOKit

/// Errors surfaced while reading the battery out of the IORegistry.
public enum BatteryReaderError: Error, CustomStringConvertible {
    case serviceNotFound
    case propertiesUnavailable(kern_return_t)

    public var description: String {
        switch self {
        case .serviceNotFound:
            return "No AppleSmartBattery service found (desktop Mac or VM?)"
        case .propertiesUnavailable(let code):
            return "IORegistryEntryCreateCFProperties failed (code \(code))"
        }
    }
}

/// Reads battery state straight from the `AppleSmartBattery` IORegistry node.
///
/// Nothing here shells out: `ioreg`/`pmset` are just thin clients over the same
/// registry, and going direct keeps the daemon cheap enough to run every few
/// seconds. Reading requires no privileges, which is what lets the sampler work
/// in the un-installed, non-root degraded mode.
public enum BatteryReader {

    /// Raw IORegistry key/value pairs for `AppleSmartBattery`.
    public static func rawProperties() throws -> [String: Any] {
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { throw BatteryReaderError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let properties = unmanaged?.takeRetainedValue() else {
            throw BatteryReaderError.propertiesUnavailable(result)
        }
        return (properties as NSDictionary) as? [String: Any] ?? [:]
    }

    /// Reads the battery and converts it into a `BatterySample`.
    ///
    /// `timestampMs` is injected so callers (and tests) control the clock.
    public static func read(timestampMs: Int64) throws -> BatterySample {
        try sample(from: rawProperties(), timestampMs: timestampMs)
    }

    // MARK: - Pure conversion

    /// Pure IORegistry-dictionary → `BatterySample` conversion, so the unit
    /// mess below can be tested without a battery present.
    public static func sample(from properties: [String: Any], timestampMs: Int64) -> BatterySample {
        let currentCapacity = number(properties, "CurrentCapacity") ?? 0
        let maxCapacity = number(properties, "MaxCapacity") ?? 0
        let designCapacity = number(properties, "DesignCapacity") ?? 0
        let rawCurrent = number(properties, "AppleRawCurrentCapacity")
        let rawMax = number(properties, "AppleRawMaxCapacity")

        let voltageMv = number(properties, "Voltage")
            ?? number(properties, "AppleRawBatteryVoltage")
            ?? 0
        // `Amperage` is an average; `InstantAmperage` is the live value. Prefer
        // the live one when it is present and non-zero, which tracks bursty
        // drain far better at a 30 s cadence.
        let instant = number(properties, "InstantAmperage")
        let average = number(properties, "Amperage")
        let amperageMa = clampAmperage((instant ?? 0) != 0 ? (instant ?? 0) : (average ?? instant ?? 0))

        let isCharging = boolean(properties, "IsCharging") ?? false
        let externalPower = boolean(properties, "ExternalConnected")
            ?? boolean(properties, "AppleRawExternalConnected")
            ?? false

        let percent = derivePercent(
            currentCapacity: currentCapacity,
            maxCapacity: maxCapacity,
            rawCurrentCapacity: rawCurrent,
            rawMaxCapacity: rawMax
        )
        let maxCapacityPct = deriveMaxCapacityPct(
            maxCapacity: maxCapacity,
            rawMaxCapacity: rawMax,
            nominalCapacity: number(properties, "NominalChargeCapacity"),
            designCapacity: designCapacity
        )

        return BatterySample(
            timestampMs: timestampMs,
            percent: percent,
            isCharging: isCharging,
            externalPower: externalPower,
            wattsDrawn: watts(voltageMv: voltageMv, amperageMa: amperageMa),
            voltageMv: Int(voltageMv.rounded()),
            amperageMa: Int(amperageMa.rounded()),
            cycleCount: Int(number(properties, "CycleCount") ?? 0),
            maxCapacityPct: maxCapacityPct,
            temperatureC: normalizeTemperature(number(properties, "Temperature"))
        )
    }

    /// Instantaneous power. Sign follows the amperage, so discharging is
    /// negative and charging is positive.
    public static func watts(voltageMv: Double, amperageMa: Double) -> Double {
        (voltageMv / 1000.0) * (amperageMa / 1000.0)
    }

    /// Charge level, 0...100.
    ///
    /// Some Macs report `CurrentCapacity` as a percentage (and `MaxCapacity` as
    /// a flat 100); others report both in mAh. The ratio is only meaningful when
    /// both are in the same unit, so mixed pairs fall back to the raw mAh pair.
    public static func derivePercent(
        currentCapacity: Double,
        maxCapacity: Double,
        rawCurrentCapacity: Double? = nil,
        rawMaxCapacity: Double? = nil
    ) -> Double {
        let currentIsPercentLike = currentCapacity <= 100
        let maxIsPercentLike = maxCapacity <= 100

        if maxCapacity > 0, currentIsPercentLike == maxIsPercentLike {
            return clampPercent(currentCapacity / maxCapacity * 100.0)
        }
        // Mixed units: trust the mAh pair when it is available and sane.
        if let rawCurrent = rawCurrentCapacity, let rawMax = rawMaxCapacity, rawMax > 0 {
            return clampPercent(rawCurrent / rawMax * 100.0)
        }
        if currentIsPercentLike, !maxIsPercentLike {
            return clampPercent(currentCapacity)
        }
        if maxCapacity > 0 {
            return clampPercent(currentCapacity / maxCapacity * 100.0)
        }
        return clampPercent(currentCapacity)
    }

    /// Battery health: present full-charge capacity over design capacity, 0...100.
    public static func deriveMaxCapacityPct(
        maxCapacity: Double,
        rawMaxCapacity: Double?,
        nominalCapacity: Double?,
        designCapacity: Double
    ) -> Double {
        guard designCapacity > 0 else {
            // No design capacity to compare against; a percent-shaped
            // MaxCapacity is the only health signal left.
            return maxCapacity > 0 && maxCapacity <= 100 ? clampPercent(maxCapacity) : 100
        }
        // `MaxCapacity` in mAh is the direct answer; when it is percent-shaped
        // (a flat 100) fall back to the raw/nominal mAh readings.
        for candidate in [maxCapacity > 100 ? maxCapacity : nil, rawMaxCapacity, nominalCapacity] {
            if let value = candidate, value > 0 {
                return clampPercent(value / designCapacity * 100.0)
            }
        }
        return maxCapacity > 0 && maxCapacity <= 100 ? clampPercent(maxCapacity) : 100
    }

    /// `Temperature` is decicelsius on some models and centi-degrees on others,
    /// and occasionally decikelvin. Pick whichever reading lands in a
    /// physically plausible band for a laptop battery.
    public static func normalizeTemperature(_ raw: Double?) -> Double? {
        guard let raw, raw != 0 else { return nil }
        let candidates = [raw / 100.0, raw / 10.0 - 273.15, raw / 10.0, raw]
        for candidate in candidates where (10.0...60.0).contains(candidate) {
            return candidate
        }
        for candidate in candidates where (-20.0...100.0).contains(candidate) {
            return candidate
        }
        return nil
    }

    // MARK: - Helpers

    private static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }

    /// Guards against a wrapped/garbage register read; no laptop pack moves
    /// more than a few tens of amps.
    private static func clampAmperage(_ value: Double) -> Double {
        guard value.isFinite, abs(value) <= 30_000 else { return 0 }
        return value
    }

    private static func number(_ properties: [String: Any], _ key: String) -> Double? {
        switch properties[key] {
        case let value as NSNumber:
            return value.doubleValue
        case let value as Int:
            return Double(value)
        case let value as Double:
            return value
        default:
            return nil
        }
    }

    private static func boolean(_ properties: [String: Any], _ key: String) -> Bool? {
        switch properties[key] {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        default:
            return nil
        }
    }
}
