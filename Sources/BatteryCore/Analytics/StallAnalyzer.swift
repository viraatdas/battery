import Foundation

/// What made the machine feel wedged during a stall.
///
/// Several can apply at once — memory pressure and swap thrash usually arrive
/// together — and episodes carry them in descending order of how far past its
/// threshold each one went.
public enum StallCause: String, Codable, Sendable, CaseIterable, Hashable {
    /// macOS itself reported memory pressure above normal.
    case memoryPressure
    /// Pages were being pushed to and pulled from disk. This is the one that
    /// makes a Mac stop responding to the keyboard.
    case swapThrash
    /// More runnable threads than cores, sustained.
    case cpuSaturation
    /// The CPU was being thermally throttled.
    case thermalThrottle
    /// Sustained heavy disk traffic. A machine can be pinned by I/O while using
    /// little CPU and no unusual memory, which every other signal here misses.
    case diskSaturation
    /// The sampler itself did not get scheduled.
    ///
    /// The strongest evidence there is, and the only one that comes from
    /// *missing* data: this daemon needs about four milliseconds of CPU. A
    /// machine that could not spare it for a minute was not slow, it was
    /// wedged. Distinguished from sleep by the monotonic clock, which advances
    /// with the wall clock through a hang and falls behind it through sleep.
    case samplerStarved

    public var label: String {
        switch self {
        case .memoryPressure: return "memory pressure"
        case .swapThrash: return "swap thrash"
        case .cpuSaturation: return "CPU saturation"
        case .thermalThrottle: return "thermal throttling"
        case .diskSaturation: return "disk saturation"
        case .samplerStarved: return "system unresponsive"
        }
    }
}

/// Cutoffs deciding when a sample counts as stalled. Exposed for tuning and
/// tests, in the same spirit as `InsightThresholds`.
public struct StallThresholds: Sendable, Hashable, Codable {
    /// Runnable threads per core, sustained, that counts as saturation.
    public var loadPerCoreSerious: Double = 1.5
    /// Load per core that counts as critical — the machine is not keeping up.
    public var loadPerCoreCritical: Double = 3.0
    /// Bytes of swap growth between two consecutive samples that counts as thrash.
    public var swapGrowthBytesPerMinute: Int64 = 64 * 1024 * 1024
    /// Page-ins per second that counts as thrash even without swap growth.
    public var pageInsPerSecond: Double = 2_000
    /// Share of physical memory in use that counts as a squeeze on its own,
    /// for the case where macOS has not yet raised its own pressure flag.
    public var memoryUsedFractionSerious: Double = 0.92
    /// Longest gap between two samples still treated as continuous. A wider
    /// gap means the Mac slept or the sampler was stopped, and differencing
    /// counters across it would invent an enormous rate.
    public var maxContinuousGapSeconds: TimeInterval = 180
    /// Ticks of calm tolerated inside one episode before it is split in two.
    /// Pressure oscillates around its threshold; without this, one stall
    /// reports as a dozen.
    public var bridgeableCalmTicks: Int = 2
    /// Episodes shorter than this are dropped as noise.
    ///
    /// Tuned to the 5-second pressure cadence: a stall lasting a quarter of a
    /// minute is one someone swore at, and should be recorded. Kept above a
    /// single sampling interval so an isolated spike — a build starting, a
    /// browser opening a hundred tabs — does not qualify.
    public var minimumEpisodeSeconds: TimeInterval = 15
    /// Combined disk throughput, in bytes per second, that counts as
    /// saturation. Deliberately high: modern SSDs sustain gigabytes per second
    /// happily, so this is the level at which the queue, not the device, is
    /// the problem.
    public var diskBytesPerSecond: Double = 400 * 1024 * 1024
    /// A gap between samples longer than this multiple of the sampler's own
    /// interval means it did not get scheduled.
    ///
    /// Generous, because ordinary scheduling jitter and timer coalescing on a
    /// laptop are real and neither is a stall.
    public var starvationGapFactor: Double = 6
    /// Absolute floor under the starvation gap, whatever the interval.
    public var minimumStarvationGapSeconds: TimeInterval = 30
    /// How closely the monotonic clock must track the wall clock across a gap
    /// for the machine to count as having been awake through it. Below this,
    /// the Mac slept, which is not a stall.
    public var awakeUptimeRatio: Double = 0.8

    public init() {}
}

/// One session's contribution to one stall.
public struct StallContributor: Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    /// Most agent processes this session had alive during the stall.
    public var peakAgentCount: Int
    public var peakProcessCount: Int
    /// Largest resident memory the session held during the stall.
    public var peakResidentBytes: Int64?
    public var peakCPUCores: Double
    /// `peakResidentBytes` as a share of physical memory, 0...1.
    public var memoryShareOfMachine: Double?
    /// `peakCPUCores` as a share of logical cores, 0...1 (can exceed 1 briefly).
    public var cpuShareOfMachine: Double?

    public init(
        id: String,
        label: String,
        peakAgentCount: Int,
        peakProcessCount: Int,
        peakResidentBytes: Int64?,
        peakCPUCores: Double,
        memoryShareOfMachine: Double?,
        cpuShareOfMachine: Double?
    ) {
        self.id = id
        self.label = label
        self.peakAgentCount = peakAgentCount
        self.peakProcessCount = peakProcessCount
        self.peakResidentBytes = peakResidentBytes
        self.peakCPUCores = peakCPUCores
        self.memoryShareOfMachine = memoryShareOfMachine
        self.cpuShareOfMachine = cpuShareOfMachine
    }
}

/// A stretch of time the machine spent under enough resource pressure to feel
/// unresponsive, with whatever agent sessions were running through it.
public struct StallEpisode: Sendable, Hashable, Identifiable {
    public var id: String { "\(Int64(start.timeIntervalSince1970))-\(causes.first?.rawValue ?? "stall")" }

    public var start: Date
    public var end: Date
    /// `serious` or `critical`; a stall is never recorded below `serious`.
    public var severity: PressureLevel
    /// Everything that was over threshold, worst first.
    public var causes: [StallCause]
    public var peakLoadPerCore: Double?
    public var peakMemoryUsedFraction: Double?
    /// Swap growth across the episode, in bytes. Negative growth is clamped
    /// away: swap shrinking is recovery, not a symptom.
    public var swapGrowthBytes: Int64
    public var peakSwapUsedBytes: Int64
    public var peakPageInsPerSecond: Double?
    /// Peak combined disk throughput seen during the episode.
    public var peakDiskBytesPerSecond: Double?
    /// Longest stretch the sampler could not run at all. Nonzero means the
    /// machine was too busy to spare a few milliseconds — the hardest evidence
    /// of a genuine freeze this tool has.
    public var longestStarvedSeconds: TimeInterval
    /// Agent sessions alive during the episode, biggest contributor first.
    public var contributors: [StallContributor]
    /// Individual heavy processes during the episode, agent or not — the answer
    /// when the culprit is Spotlight rather than anything you launched.
    public var heavyProcesses: [HeavyProcess]
    public var sampleCount: Int

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// The session that best explains this stall, when agent sessions held
    /// enough of the machine to be worth naming. `nil` when the pressure came
    /// from somewhere else entirely — which is a real and useful answer.
    public var primaryContributor: StallContributor? { contributors.first }

    public init(
        start: Date,
        end: Date,
        severity: PressureLevel,
        causes: [StallCause],
        peakLoadPerCore: Double?,
        peakMemoryUsedFraction: Double?,
        swapGrowthBytes: Int64,
        peakSwapUsedBytes: Int64,
        peakPageInsPerSecond: Double?,
        contributors: [StallContributor],
        sampleCount: Int,
        peakDiskBytesPerSecond: Double? = nil,
        longestStarvedSeconds: TimeInterval = 0,
        heavyProcesses: [HeavyProcess] = []
    ) {
        self.start = start
        self.end = end
        self.severity = severity
        self.causes = causes
        self.peakLoadPerCore = peakLoadPerCore
        self.peakMemoryUsedFraction = peakMemoryUsedFraction
        self.swapGrowthBytes = swapGrowthBytes
        self.peakSwapUsedBytes = peakSwapUsedBytes
        self.peakPageInsPerSecond = peakPageInsPerSecond
        self.contributors = contributors
        self.sampleCount = sampleCount
        self.peakDiskBytesPerSecond = peakDiskBytesPerSecond
        self.longestStarvedSeconds = longestStarvedSeconds
        self.heavyProcesses = heavyProcesses
    }

    /// The single best sentence about what was responsible, or `nil` when
    /// nothing measured stands out. Prefers an agent session, because a session
    /// is a more actionable thing to name than one of its processes.
    public var culpritLabel: String? {
        if let session = contributors.first { return session.label }
        return heavyProcesses.first?.name
    }
}

/// One process that was heavy during a stall, whatever it belongs to.
///
/// Recorded separately from `StallContributor` because it is a different claim:
/// a contributor is a whole agent session, this is a single process that showed
/// up in the machine's top few on some resource. `mds_stores` will never be a
/// session, and it is a very common answer.
public struct HeavyProcess: Sendable, Hashable, Identifiable {
    public var id: String { "\(name)#\(pid)" }

    public var pid: Int32
    public var name: String
    public var category: ProcessCategory
    public var peakResidentBytes: Int64?
    public var peakCPUCores: Double
    public var peakDiskBytesPerS: Double?
    /// Share of physical memory held at its peak, 0...1.
    public var memoryShareOfMachine: Double?
    /// True when this process belongs to a coding-agent session, so a caller
    /// can avoid listing it twice alongside the session that already covers it.
    public var isAgentMember: Bool

    public init(
        pid: Int32,
        name: String,
        category: ProcessCategory,
        peakResidentBytes: Int64?,
        peakCPUCores: Double,
        peakDiskBytesPerS: Double?,
        memoryShareOfMachine: Double?,
        isAgentMember: Bool
    ) {
        self.pid = pid
        self.name = name
        self.category = category
        self.peakResidentBytes = peakResidentBytes
        self.peakCPUCores = peakCPUCores
        self.peakDiskBytesPerS = peakDiskBytesPerS
        self.memoryShareOfMachine = memoryShareOfMachine
        self.isAgentMember = isAgentMember
    }
}

/// Finds stall episodes in a window's pressure samples and attributes them to
/// the agent sessions that were running at the time.
///
/// Attribution here is correlational and says so: the analyzer reports what a
/// session was holding while the machine was under pressure, which is evidence,
/// not proof. It is still the evidence that was missing — before this, a Mac
/// that froze for two minutes left behind no record at all of what was resident
/// when it happened.
public enum StallAnalyzer {

    /// Per-sample verdict, kept separate from episode assembly so the rule is
    /// testable on its own.
    struct Verdict {
        var severity: PressureLevel
        var causes: [StallCause]
        var loadPerCore: Double?
        var memoryUsedFraction: Double?
        var pageInsPerSecond: Double?
        var swapGrowthBytes: Int64
        var diskBytesPerSecond: Double?
        /// Wall-clock seconds the sampler was unable to run through. Zero
        /// unless `.samplerStarved` fired.
        var starvedSeconds: TimeInterval

        var isStalled: Bool { severity >= .serious }
    }

    /// Combined disk throughput at the end of `pressure`, differenced against
    /// the sample before it.
    ///
    /// `nil` when there is no usable pair: one sample, a gap too wide to
    /// difference across, or a machine whose block-storage counters read zero.
    public static func diskBytesPerSecond(
        pressure: [PressureSample],
        thresholds: StallThresholds = StallThresholds()
    ) -> Double? {
        let sorted = pressure.sorted { $0.timestampMs < $1.timestampMs }
        guard sorted.count >= 2 else { return nil }
        let last = sorted[sorted.count - 1]
        let previous = sorted[sorted.count - 2]
        return verdict(for: last, previous: previous, thresholds: thresholds).diskBytesPerSecond
    }

    /// Judges one sample, using `previous` for the counter deltas that only
    /// make sense as a rate (swap growth, page-ins).
    static func verdict(
        for sample: PressureSample,
        previous: PressureSample?,
        thresholds: StallThresholds
    ) -> Verdict {
        var causes: [StallCause] = []
        var severity = PressureLevel.nominal

        func raise(to level: PressureLevel, cause: StallCause) {
            if level.rank > severity.rank { severity = level }
            if !causes.contains(cause) { causes.append(cause) }
        }

        // macOS's own verdict is the most trustworthy memory signal, so it is
        // taken at face value rather than re-derived from page counts.
        if sample.memoryLevel >= .critical {
            raise(to: .critical, cause: .memoryPressure)
        } else if sample.memoryLevel >= .moderate {
            raise(to: .serious, cause: .memoryPressure)
        }

        let memoryUsedFraction = sample.memoryUsedFraction
        if let memoryUsedFraction, memoryUsedFraction >= thresholds.memoryUsedFractionSerious {
            raise(to: .serious, cause: .memoryPressure)
        }

        let loadPerCore = sample.loadPerCore
        if let loadPerCore {
            if loadPerCore >= thresholds.loadPerCoreCritical {
                raise(to: .critical, cause: .cpuSaturation)
            } else if loadPerCore >= thresholds.loadPerCoreSerious {
                raise(to: .serious, cause: .cpuSaturation)
            }
        }

        if sample.thermalLevel >= .critical {
            raise(to: .critical, cause: .thermalThrottle)
        } else if sample.thermalLevel >= .serious {
            raise(to: .serious, cause: .thermalThrottle)
        }

        // The sampler failing to run is itself the measurement. Checked before
        // the rate maths below, which deliberately refuse to difference across
        // a gap this wide.
        var starvedSeconds: TimeInterval = 0
        if let previous {
            let wallSeconds = Double(sample.timestampMs - previous.timestampMs) / 1000
            let expected = previous.intervalSeconds > 0
                ? previous.intervalSeconds
                : sample.intervalSeconds
            let allowed = max(
                expected * thresholds.starvationGapFactor,
                thresholds.minimumStarvationGapSeconds
            )
            // A hole left by a sampler that was not running is not a stall.
            // Restarts, reinstalls, and quitting the app all produce exactly
            // the gap shape a wedged machine does; the sampler run identity is
            // what separates them.
            let sameRun = sample.isSameSamplerRun(as: previous)
            if sameRun, expected > 0, wallSeconds > allowed {
                // Sleep leaves the same hole. The monotonic clock is what tells
                // them apart: through a hang it advances with the wall clock,
                // through sleep it falls well behind.
                let monotonicSeconds = sample.uptimeSeconds - previous.uptimeSeconds
                let wasAwake = sample.uptimeSeconds > 0
                    && previous.uptimeSeconds > 0
                    && monotonicSeconds >= wallSeconds * thresholds.awakeUptimeRatio
                if wasAwake {
                    starvedSeconds = wallSeconds
                    raise(to: .critical, cause: .samplerStarved)
                }
            }
        }

        // Rates need two samples and a believable gap between them. Across a
        // sleep gap the counters are meaningless, so they are simply not read.
        var pageInsPerSecond: Double?
        var swapGrowthBytes: Int64 = 0
        var diskBytesPerSecond: Double?
        if let previous {
            let seconds = Double(sample.timestampMs - previous.timestampMs) / 1000
            if seconds > 0, seconds <= thresholds.maxContinuousGapSeconds {
                let diskDelta = max(0, sample.diskReadBytes - previous.diskReadBytes)
                    + max(0, sample.diskWriteBytes - previous.diskWriteBytes)
                let diskRate = Double(diskDelta) / seconds
                if sample.diskReadBytes > 0 || sample.diskWriteBytes > 0 {
                    diskBytesPerSecond = diskRate
                    if diskRate >= thresholds.diskBytesPerSecond {
                        raise(to: .serious, cause: .diskSaturation)
                    }
                }
                let growth = sample.swapUsedBytes - previous.swapUsedBytes
                swapGrowthBytes = max(0, growth)
                let growthPerMinute = Double(swapGrowthBytes) * (60 / seconds)
                if growthPerMinute >= Double(thresholds.swapGrowthBytesPerMinute) {
                    raise(to: .serious, cause: .swapThrash)
                }
                let pageIns = Double(max(0, sample.pageIns - previous.pageIns)) / seconds
                pageInsPerSecond = pageIns
                if pageIns >= thresholds.pageInsPerSecond {
                    raise(to: .serious, cause: .swapThrash)
                }
            }
        }

        return Verdict(
            severity: severity,
            causes: causes,
            loadPerCore: loadPerCore,
            memoryUsedFraction: memoryUsedFraction,
            pageInsPerSecond: pageInsPerSecond,
            swapGrowthBytes: swapGrowthBytes,
            diskBytesPerSecond: diskBytesPerSecond,
            starvedSeconds: starvedSeconds
        )
    }

    /// Finds every stall episode in `pressure`, attributing each to the agent
    /// sessions running through it.
    ///
    /// - Parameters:
    ///   - pressure: pressure samples, any order; sorted internally.
    ///   - tracked: the tracked-process samples over the same window — agent
    ///     session members and the machine's heaviest processes. Pass an empty
    ///     array to get episodes with no attribution.
    public static func episodes(
        pressure: [PressureSample],
        tracked: [ProcessSample] = [],
        thresholds: StallThresholds = StallThresholds()
    ) -> [StallEpisode] {
        let agents = AgentSessions.timeline(samples: tracked)
        let samples = pressure.sorted { $0.timestampMs < $1.timestampMs }
        guard !samples.isEmpty else { return [] }

        // One pass: judge each sample, then cut the judged sequence into runs
        // of stalled samples, bridging short calm stretches.
        var judged: [(sample: PressureSample, verdict: Verdict)] = []
        judged.reserveCapacity(samples.count)
        for (index, sample) in samples.enumerated() {
            let previous = index > 0 ? samples[index - 1] : nil
            judged.append((sample, verdict(for: sample, previous: previous, thresholds: thresholds)))
        }

        var episodes: [StallEpisode] = []
        var run: [(sample: PressureSample, verdict: Verdict)] = []
        var calmSinceStall = 0

        func closeRun() {
            defer {
                run = []
                calmSinceStall = 0
            }
            // Trailing calm samples were only kept in case the stall resumed;
            // they are not part of the episode itself.
            let trimmed = run.reversed().drop { !$0.verdict.isStalled }.reversed().map { $0 }
            guard !trimmed.isEmpty else { return }
            if let episode = assemble(
                trimmed, agents: agents, tracked: tracked, thresholds: thresholds
            ) {
                episodes.append(episode)
            }
        }

        for entry in judged {
            if entry.verdict.isStalled {
                run.append(entry)
                calmSinceStall = 0
            } else if !run.isEmpty {
                calmSinceStall += 1
                if calmSinceStall > thresholds.bridgeableCalmTicks {
                    closeRun()
                } else {
                    run.append(entry)
                }
            }
        }
        closeRun()

        return episodes
    }

    /// Turns a run of samples into one episode, or `nil` when it is too short
    /// to be worth reporting.
    private static func assemble(
        _ run: [(sample: PressureSample, verdict: Verdict)],
        agents: [AgentSessions.Tick],
        tracked: [ProcessSample],
        thresholds: StallThresholds
    ) -> StallEpisode? {
        guard let first = run.first, let last = run.last else { return nil }
        // A starved sample is observed at one instant but describes the stretch
        // *before* it — the machine went dark when the previous sample was
        // taken and came back at this one. Backdating the start to the
        // beginning of that hole is both truer and the only way the episode has
        // any duration at all: on its own it is a single point in time.
        let starvedSeconds = first.verdict.starvedSeconds
        let start = Date(
            timeIntervalSince1970: Double(first.sample.timestampMs) / 1000 - starvedSeconds
        )
        let end = Date(timeIntervalSince1970: Double(last.sample.timestampMs) / 1000)

        // Episodes are stretches, not instants: a lone sample spans no time and
        // is dropped, as is any run too short to be something a person noticed.
        // Pressure spikes for one tick constantly on a healthy machine — a
        // build starting, a browser opening a hundred tabs — and reporting
        // those as stalls would bury the real ones.
        guard end.timeIntervalSince(start) >= thresholds.minimumEpisodeSeconds else { return nil }

        let stalled = run.filter { $0.verdict.isStalled }
        let severity = stalled.contains { $0.verdict.severity >= .critical } ? PressureLevel.critical : .serious

        // Order causes by how often they fired across the episode, so the
        // headline names the dominant one rather than whichever came first.
        var causeCounts: [StallCause: Int] = [:]
        for entry in stalled {
            for cause in entry.verdict.causes { causeCounts[cause, default: 0] += 1 }
        }
        let causes = causeCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.rawValue < rhs.key.rawValue
            }
            .map(\.key)

        let totalMemory = run.map(\.sample.totalMemoryBytes).max() ?? 0
        let cpuCount = run.map(\.sample.cpuCount).max() ?? 0

        return StallEpisode(
            start: start,
            end: end,
            severity: severity,
            causes: causes,
            peakLoadPerCore: run.compactMap(\.verdict.loadPerCore).max(),
            peakMemoryUsedFraction: run.compactMap(\.verdict.memoryUsedFraction).max(),
            swapGrowthBytes: run.reduce(0) { $0 + $1.verdict.swapGrowthBytes },
            peakSwapUsedBytes: run.map(\.sample.swapUsedBytes).max() ?? 0,
            peakPageInsPerSecond: run.compactMap(\.verdict.pageInsPerSecond).max(),
            contributors: contributors(
                start: start,
                end: end,
                agents: agents,
                totalMemoryBytes: totalMemory,
                cpuCount: cpuCount
            ),
            sampleCount: run.count,
            peakDiskBytesPerSecond: run.compactMap(\.verdict.diskBytesPerSecond).max(),
            longestStarvedSeconds: run.map(\.verdict.starvedSeconds).max() ?? 0,
            heavyProcesses: heavyProcesses(
                start: start,
                end: end,
                tracked: tracked,
                totalMemoryBytes: totalMemory
            )
        )
    }

    /// The heaviest individual processes seen during `[start, end]`, ranked by
    /// how much of the machine each was holding.
    ///
    /// Peaks per process, across whatever samples fall in the window. Unlike
    /// `contributors`, this makes no attempt to group anything: the point is to
    /// name `mds_stores` or `backupd` when that is the honest answer.
    static func heavyProcesses(
        start: Date,
        end: Date,
        tracked: [ProcessSample],
        totalMemoryBytes: Int64,
        limit: Int = 5
    ) -> [HeavyProcess] {
        let startMs = Int64(start.timeIntervalSince1970 * 1000) - attributionMarginMs
        let endMs = Int64(end.timeIntervalSince1970 * 1000) + attributionMarginMs
        let inWindow = tracked.filter { $0.timestampMs >= startMs && $0.timestampMs <= endMs }
        guard !inWindow.isEmpty else { return [] }

        // Which processes belong to an agent session, so the caller can avoid
        // listing a session's members twice.
        var agentMembers: Set<Int32> = []
        for tick in AgentSessions.timeline(samples: inWindow) where !tick.footprints.isEmpty {
            let pids = inWindow
                .filter { $0.timestampMs == tick.timestampMs }
                .map(\.pid)
            let roots = Set(tick.footprints.map(\.rootPid))
            let byPid = Dictionary(
                inWindow.filter { $0.timestampMs == tick.timestampMs }.map { ($0.pid, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for pid in pids {
                guard let sample = byPid[pid] else { continue }
                let chain = AgentSessions.ancestorChain(of: sample, in: byPid)
                if chain.contains(where: { roots.contains($0.pid) }) {
                    agentMembers.insert(pid)
                }
            }
        }

        struct Key: Hashable {
            var pid: Int32
            var name: String
        }
        var peaks: [Key: HeavyProcess] = [:]
        for sample in inWindow {
            let key = Key(pid: sample.pid, name: sample.name)
            var entry = peaks[key] ?? HeavyProcess(
                pid: sample.pid,
                name: sample.name,
                category: sample.category,
                peakResidentBytes: nil,
                peakCPUCores: 0,
                peakDiskBytesPerS: nil,
                memoryShareOfMachine: nil,
                isAgentMember: agentMembers.contains(sample.pid)
            )
            if let resident = sample.residentBytes {
                entry.peakResidentBytes = max(entry.peakResidentBytes ?? 0, resident)
            }
            entry.peakCPUCores = max(entry.peakCPUCores, sample.cpuCores)
            if let disk = sample.diskBytesPerS {
                entry.peakDiskBytesPerS = max(entry.peakDiskBytesPerS ?? 0, disk)
            }
            peaks[key] = entry
        }

        return peaks.values
            .map { process -> HeavyProcess in
                var updated = process
                if totalMemoryBytes > 0, let peak = process.peakResidentBytes {
                    updated.memoryShareOfMachine = Double(peak) / Double(totalMemoryBytes)
                }
                return updated
            }
            .sorted { lhs, rhs in
                // Memory first: it is the best predictor of a hang. CPU, then
                // disk, break the tie.
                let lhsMemory = lhs.peakResidentBytes ?? -1
                let rhsMemory = rhs.peakResidentBytes ?? -1
                if lhsMemory != rhsMemory { return lhsMemory > rhsMemory }
                if lhs.peakCPUCores != rhs.peakCPUCores { return lhs.peakCPUCores > rhs.peakCPUCores }
                if (lhs.peakDiskBytesPerS ?? 0) != (rhs.peakDiskBytesPerS ?? 0) {
                    return (lhs.peakDiskBytesPerS ?? 0) > (rhs.peakDiskBytesPerS ?? 0)
                }
                return lhs.id < rhs.id
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Pressure and process samples are written by separate readers on
    /// different cadences, so their timestamps never match exactly. The
    /// attribution window is widened by a generous margin rather than requiring
    /// an exact match, which would attribute nothing at all.
    static let attributionMarginMs: Int64 = 60_000

    /// Agent sessions overlapping `[start, end]`, ranked by how much of the
    /// machine they were holding.
    static func contributors(
        start: Date,
        end: Date,
        agents: [AgentSessions.Tick],
        totalMemoryBytes: Int64,
        cpuCount: Int
    ) -> [StallContributor] {
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let endMs = Int64(end.timeIntervalSince1970 * 1000)
        let overlapping = agents.filter {
            $0.timestampMs >= startMs - attributionMarginMs
                && $0.timestampMs <= endMs + attributionMarginMs
        }
        guard !overlapping.isEmpty else { return [] }

        let sessions = AgentSessions.sessions(timeline: overlapping)
        return sessions.map { session in
            StallContributor(
                id: session.id,
                label: session.label,
                peakAgentCount: session.peakAgentCount,
                peakProcessCount: session.peakProcessCount,
                peakResidentBytes: session.peakResidentBytes,
                peakCPUCores: session.peakCPUCores,
                memoryShareOfMachine: {
                    guard totalMemoryBytes > 0, let peak = session.peakResidentBytes else { return nil }
                    return Double(peak) / Double(totalMemoryBytes)
                }(),
                cpuShareOfMachine: cpuCount > 0 ? session.peakCPUCores / Double(cpuCount) : nil
            )
        }
        .sorted { lhs, rhs in
            // Memory is the better predictor of a hang, so it ranks first when
            // both sessions reported it; CPU breaks the tie otherwise.
            let lhsMemory = lhs.peakResidentBytes ?? -1
            let rhsMemory = rhs.peakResidentBytes ?? -1
            if lhsMemory != rhsMemory { return lhsMemory > rhsMemory }
            if lhs.peakCPUCores != rhs.peakCPUCores { return lhs.peakCPUCores > rhs.peakCPUCores }
            return lhs.id < rhs.id
        }
    }
}
