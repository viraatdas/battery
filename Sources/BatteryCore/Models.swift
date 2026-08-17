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
    /// Raw `AppleRawCurrentCapacity`, in mAh, when the platform reports it in
    /// that unit. `nil` on Macs where the raw keys are absent or are
    /// themselves percent-shaped — see `BatteryReader.sample(from:)`.
    public var rawCurrentMah: Double?
    /// Raw `AppleRawMaxCapacity`, in mAh. Paired with `rawCurrentMah`; either
    /// both are present or both are `nil`.
    public var rawMaxMah: Double?

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
        temperatureC: Double? = nil,
        rawCurrentMah: Double? = nil,
        rawMaxMah: Double? = nil
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
        self.rawCurrentMah = rawCurrentMah
        self.rawMaxMah = rawMaxMah
    }

    /// A higher-resolution charge level than `percent`, derived from the raw
    /// mAh pair instead of the integer `CurrentCapacity`/`MaxCapacity` keys
    /// macOS quantizes to a whole percent. `nil` whenever either raw value is
    /// missing, or the ratio is not a sane percentage — callers should fall
    /// back to `percent` for both math and display in that case.
    public var preciseCharge: Double? {
        guard let rawCurrentMah, let rawMaxMah, rawMaxMah > 0 else { return nil }
        let value = rawCurrentMah / rawMaxMah * 100.0
        guard value.isFinite, (0...100).contains(value) else { return nil }
        return value
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
    /// Parent process id, when the process table could be read at sample time.
    ///
    /// `nil` on rows written before schema v3, and on any process that had
    /// already exited between the powermetrics sample and the process-table
    /// read. Ancestry is what turns a flat list of `claude` processes into
    /// "one Rudder session running six agents", so its absence degrades the
    /// grouping to per-process rows rather than failing it.
    public var ppid: Int32?
    /// Bytes per second this process read from and wrote to disk, derived from
    /// its cumulative counters across two samples.
    ///
    /// `nil` when not measured — on the first tick, or for a process whose
    /// resource usage this process may not read. Disk stalls are a common cause
    /// of a Mac feeling frozen and are invisible in both energy and memory.
    public var diskReadBytesPerS: Double?
    public var diskWriteBytesPerS: Double?
    /// Working directory, recorded only for the shell that roots a terminal
    /// tab. It is what names the tab, and what the terminal puts in its title.
    public var workingDirectory: String?
    /// Resident set size in bytes — physical memory the process is holding.
    ///
    /// `nil` for the same reasons as `ppid`, plus one more: reading another
    /// user's task info requires privilege, so an unprivileged sampler sees
    /// this only for its own processes. Energy impact says nothing about
    /// memory, and memory is what actually wedges a machine, so this is
    /// recorded separately rather than derived.
    public var residentBytes: Int64?

    public init(
        timestampMs: Int64,
        pid: Int32,
        name: String,
        bundlePathHint: String? = nil,
        energyImpact: Double,
        cpuMsPerS: Double,
        category: ProcessCategory,
        ppid: Int32? = nil,
        residentBytes: Int64? = nil,
        diskReadBytesPerS: Double? = nil,
        diskWriteBytesPerS: Double? = nil,
        workingDirectory: String? = nil
    ) {
        self.timestampMs = timestampMs
        self.pid = pid
        self.name = name
        self.bundlePathHint = bundlePathHint
        self.energyImpact = energyImpact
        self.cpuMsPerS = cpuMsPerS
        self.category = category
        self.ppid = ppid
        self.residentBytes = residentBytes
        self.diskReadBytesPerS = diskReadBytesPerS
        self.diskWriteBytesPerS = diskWriteBytesPerS
        self.workingDirectory = workingDirectory
    }

    /// CPU cores' worth of work this sample represents: 1000 ms of CPU per
    /// second of wall time is one core fully busy.
    public var cpuCores: Double { cpuMsPerS / 1000 }

    /// Combined read and write throughput, when either was measured.
    public var diskBytesPerS: Double? {
        guard diskReadBytesPerS != nil || diskWriteBytesPerS != nil else { return nil }
        return (diskReadBytesPerS ?? 0) + (diskWriteBytesPerS ?? 0)
    }
}

/// How hard a system resource is squeezing, on a common four-step scale.
///
/// macOS reports memory pressure as 1/2/4 (normal/warn/critical) and thermal
/// pressure as `ProcessInfo.ThermalState`; both collapse onto this so the
/// analysis and the UI have one vocabulary for "how bad is it".
public enum PressureLevel: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
    case nominal
    case moderate
    case serious
    case critical

    /// Rank used for ordering and for threshold comparisons.
    public var rank: Int {
        switch self {
        case .nominal: return 0
        case .moderate: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A point-in-time reading of the machine-wide resource pressure that makes a
/// Mac feel wedged: memory, swap, CPU saturation, and heat.
///
/// Deliberately separate from `BatterySample`. Battery drain and interactive
/// stalls are different failure modes — a machine can be pinned at 100% CPU on
/// AC power, hanging badly, while drawing nothing from the battery at all — so
/// the stall signals are sampled and stored in their own right instead of being
/// inferred from watts.
public struct PressureSample: Codable, Sendable, Hashable {
    /// Unix epoch milliseconds when the sample was taken.
    public var timestampMs: Int64
    /// macOS's own memory pressure verdict (`kern.memorystatus_vm_pressure_level`).
    public var memoryLevel: PressureLevel
    /// Thermal pressure, from `ProcessInfo.thermalState`. `serious` and above
    /// mean the CPU is being throttled, which reads as a hang.
    public var thermalLevel: PressureLevel
    /// Physical memory installed.
    public var totalMemoryBytes: Int64
    /// Free plus purgeable — memory available without evicting anything.
    public var availableMemoryBytes: Int64
    /// Memory held by the compressor. Growth here is the first sign of a squeeze.
    public var compressedBytes: Int64
    /// Bytes currently swapped out to disk.
    public var swapUsedBytes: Int64
    /// Cumulative pageins since boot. Deltas between samples show thrash;
    /// the absolute value is meaningless on its own.
    public var pageIns: Int64
    /// 1-minute load average.
    public var loadAverage1m: Double
    /// Logical CPU count, so load can be read as a saturation ratio.
    public var cpuCount: Int
    /// Monotonic seconds since boot, read at the same instant as `timestampMs`.
    ///
    /// The pair is what separates a sleeping Mac from a wedged one. Both leave
    /// the same hole in the data — no samples for two minutes — but during
    /// sleep the monotonic clock advances far less than the wall clock, while a
    /// machine too busy to schedule the sampler advances both together.
    public var uptimeSeconds: Double
    /// Cumulative bytes read from and written to block storage since boot.
    /// Deltas between samples give the rate; the absolute value means nothing.
    public var diskReadBytes: Int64
    public var diskWriteBytes: Int64
    /// The cadence the sampler intended when it wrote this, in seconds. Stored
    /// rather than assumed so a gap can be judged against the interval actually
    /// in force, which is configurable and has changed across versions.
    public var intervalSeconds: Double
    /// Cumulative CPU ticks spent doing work, and idle, across all cores since
    /// boot.
    ///
    /// Differenced between two samples these give true machine-wide CPU
    /// utilisation, which is what "how hard was this Mac working" actually
    /// means. The load average stored alongside is a *queue length* — useful
    /// for spotting oversubscription, useless as a measure of work done, since
    /// it says nothing about whether those threads got any CPU.
    public var cpuTicksUsed: Int64
    public var cpuTicksIdle: Int64
    /// `uptimeSeconds` at the moment the sampler process started.
    ///
    /// Identifies the sampler *run* that produced this sample, which is what
    /// separates the two very different reasons for a hole in the data. If the
    /// run either side of a gap is the same, the sampler was alive the whole
    /// time and could not get scheduled — a genuine stall. If the run changed,
    /// the sampler was simply not running: quit, reinstalled, or restarted.
    /// Without this the second case reports as the first, which it did.
    public var samplerStartUptime: Double

    public init(
        timestampMs: Int64,
        memoryLevel: PressureLevel,
        thermalLevel: PressureLevel,
        totalMemoryBytes: Int64,
        availableMemoryBytes: Int64,
        compressedBytes: Int64,
        swapUsedBytes: Int64,
        pageIns: Int64,
        loadAverage1m: Double,
        cpuCount: Int,
        uptimeSeconds: Double = 0,
        diskReadBytes: Int64 = 0,
        diskWriteBytes: Int64 = 0,
        intervalSeconds: Double = 0,
        samplerStartUptime: Double = 0,
        cpuTicksUsed: Int64 = 0,
        cpuTicksIdle: Int64 = 0
    ) {
        self.timestampMs = timestampMs
        self.memoryLevel = memoryLevel
        self.thermalLevel = thermalLevel
        self.totalMemoryBytes = totalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pageIns = pageIns
        self.loadAverage1m = loadAverage1m
        self.cpuCount = cpuCount
        self.uptimeSeconds = uptimeSeconds
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.intervalSeconds = intervalSeconds
        self.samplerStartUptime = samplerStartUptime
        self.cpuTicksUsed = cpuTicksUsed
        self.cpuTicksIdle = cpuTicksIdle
    }

    /// Machine-wide CPU utilisation between `previous` and this sample, as a
    /// fraction of all cores, 0...1. `nil` when the tick counters are missing
    /// or did not advance — a counter that went backwards means a reboot.
    public func cpuUtilisation(since previous: PressureSample) -> Double? {
        let used = cpuTicksUsed - previous.cpuTicksUsed
        let idle = cpuTicksIdle - previous.cpuTicksIdle
        guard used >= 0, idle >= 0 else { return nil }
        let total = used + idle
        guard total > 0 else { return nil }
        return min(max(Double(used) / Double(total), 0), 1)
    }

    /// The same as a number of fully busy cores.
    public func cpuCoresBusy(since previous: PressureSample) -> Double? {
        guard cpuCount > 0, let utilisation = cpuUtilisation(since: previous) else { return nil }
        return utilisation * Double(cpuCount)
    }

    /// Whether `other` was written by the same sampler run as this sample.
    /// Unknown (both zero) counts as the same run, so pre-v6 data keeps its
    /// old, more permissive behaviour rather than silently losing stalls.
    public func isSameSamplerRun(as other: PressureSample) -> Bool {
        guard samplerStartUptime > 0, other.samplerStartUptime > 0 else { return true }
        return abs(samplerStartUptime - other.samplerStartUptime) < 1
    }

    /// Runnable work per core. Above 1.0 means more threads want CPU than the
    /// machine has, which is when typing starts to lag.
    public var loadPerCore: Double? {
        guard cpuCount > 0 else { return nil }
        return loadAverage1m / Double(cpuCount)
    }

    /// Share of physical memory not readily available, 0...1.
    public var memoryUsedFraction: Double? {
        guard totalMemoryBytes > 0 else { return nil }
        let used = Double(totalMemoryBytes - availableMemoryBytes)
        return min(max(used / Double(totalMemoryBytes), 0), 1)
    }
}
