import Foundation

/// Category assigned to a process by the `Categorizer`.
public enum ProcessCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case browser
    case terminal
    case devtools
    case media
    case communication
    case system
    case background
    case other
}

/// A single point-in-time reading of the machine's battery state.
public struct BatterySample: Codable, Sendable, Hashable {
    /// Unix epoch milliseconds when the sample was taken.
    public var timestampMs: Int64
    /// Battery charge, 0...100.
    public var percent: Double
    public var isCharging: Bool
    /// True when running on external (AC) power.
    public var externalPower: Bool
    /// Power draw in watts; negative when discharging, positive when charging.
    public var wattsDrawn: Double
    public var voltageMv: Int
    public var amperageMa: Int
    public var cycleCount: Int
    /// Current maximum capacity relative to design capacity, 0...100.
    public var maxCapacityPct: Double
    public var temperatureC: Double?

    public init(
        timestampMs: Int64,
        percent: Double,
        isCharging: Bool,
        externalPower: Bool,
        wattsDrawn: Double,
        voltageMv: Int,
        amperageMa: Int,
        cycleCount: Int,
        maxCapacityPct: Double,
        temperatureC: Double? = nil
    ) {
        self.timestampMs = timestampMs
        self.percent = percent
        self.isCharging = isCharging
        self.externalPower = externalPower
        self.wattsDrawn = wattsDrawn
        self.voltageMv = voltageMv
        self.amperageMa = amperageMa
        self.cycleCount = cycleCount
        self.maxCapacityPct = maxCapacityPct
        self.temperatureC = temperatureC
    }
}

/// A single point-in-time reading of one process's energy usage.
public struct ProcessSample: Codable, Sendable, Hashable {
    /// Unix epoch milliseconds when the sample was taken.
    public var timestampMs: Int64
    public var pid: Int32
    public var name: String
    /// Best-effort path to the owning bundle or executable, when known.
    public var bundlePathHint: String?
    /// powermetrics-style relative energy impact score.
    public var energyImpact: Double
    /// CPU milliseconds consumed per second of wall time.
    public var cpuMsPerS: Double
    public var category: ProcessCategory

    public init(
        timestampMs: Int64,
        pid: Int32,
        name: String,
        bundlePathHint: String? = nil,
        energyImpact: Double,
        cpuMsPerS: Double,
        category: ProcessCategory
    ) {
        self.timestampMs = timestampMs
        self.pid = pid
        self.name = name
        self.bundlePathHint = bundlePathHint
        self.energyImpact = energyImpact
        self.cpuMsPerS = cpuMsPerS
        self.category = category
    }
}
