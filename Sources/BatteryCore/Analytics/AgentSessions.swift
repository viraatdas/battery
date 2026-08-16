import Foundation

/// Groups coding-agent processes into *sessions* using process ancestry.
///
/// The problem this solves: a machine running several coding agents at once
/// shows up in every per-process view as a flat list of identical rows —
/// `claude`, `claude`, `claude`, `node`, `swift-frontend` — with nothing tying
/// them together and no hint that a single orchestrator spawned all of them.
/// That list cannot answer "is my agent tooling what is wedging this machine",
/// which is the only question worth asking when the machine is wedged.
///
/// Ancestry answers it. An agent process (`claude`, `codex`, …) is walked up
/// its parent chain; if an orchestrator (`rudder-native`, …) is found, that
/// orchestrator is the session root, and the session is the orchestrator plus
/// everything under it — the agents, their helper processes, and the compilers
/// and test runners *they* spawn, which is where much of the real cost lives.
/// An agent with no orchestrator ancestor roots its own session, so an agent
/// started by hand in a terminal is still counted.
///
/// Deliberately generic rather than keyed to one tool: the roster below is a
/// list of names, and an unrecognized orchestrator degrades to one session per
/// agent instead of producing nothing.
public enum AgentSessions {

    // MARK: - Roster

    /// Processes that *are* a coding agent. Matched case-insensitively against
    /// the executable name, exactly or as a prefix (`claude-code`, `codex-cli`).
    public static let agentNames: Set<String> = [
        "claude", "codex", "aider", "goose", "opencode", "amp", "cursor-agent",
        "gemini", "copilot", "crush", "droid",
    ]

    /// Processes that *run* coding agents, several at a time. When one of these
    /// is an ancestor, it becomes the session root and everything beneath it is
    /// attributed to that one session.
    public static let orchestratorNames: Set<String> = [
        "rudder", "rudder-native", "conductor", "crystal", "sculptor", "vibe-kanban",
    ]

    /// Display names for roots whose executable name is not what a person calls
    /// the tool. Anything absent is shown as-is.
    static let displayNames: [String: String] = [
        "rudder-native": "Rudder",
        "rudder": "Rudder",
        "claude": "Claude Code",
        "codex": "Codex",
        "cursor-agent": "Cursor Agent",
        "vibe-kanban": "Vibe Kanban",
    ]

    /// Longest parent chain walked before giving up. Real trees are a few links
    /// deep; the cap exists so a corrupted or recycled-pid chain cannot spin.
    static let maxAncestorDepth = 24

    public static func isAgent(name: String) -> Bool {
        matches(name: name, roster: agentNames)
    }

    public static func isOrchestrator(name: String) -> Bool {
        matches(name: name, roster: orchestratorNames)
    }

    private static func matches(name: String, roster: Set<String>) -> Bool {
        let normalized = normalizedName(name)
        if roster.contains(normalized) { return true }
        // Prefix form catches versioned/variant binaries (`claude-code`,
        // `codex-cli`) without matching unrelated names that merely start with
        // the same letters, because the separator is required.
        return roster.contains { normalized.hasPrefix($0 + "-") || normalized.hasPrefix($0 + "_") }
    }

    /// Executable name reduced for matching: last path component, lowercased,
    /// with a trailing `.app`-style suffix and any argument tail removed.
    static func normalizedName(_ name: String) -> String {
        var value = name
        if let slash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: slash)...])
        }
        if let space = value.firstIndex(of: " ") {
            value = String(value[..<space])
        }
        return value.lowercased()
    }

    static func displayName(for rootName: String) -> String {
        displayNames[normalizedName(rootName)] ?? rootName
    }

    // MARK: - Per-tick grouping

    /// One session's footprint at one sample tick.
    public struct Footprint: Sendable, Hashable {
        public var rootPid: Int32
        public var rootName: String
        /// Processes attributed to this session at this tick, root included.
        public var processCount: Int
        /// How many of them are agent processes proper.
        public var agentCount: Int
        /// Summed resident memory, or `nil` when no member reported any — an
        /// unprivileged sampler cannot read other users' task info, and a zero
        /// there would read as "using no memory" rather than "not measured".
        public var residentBytes: Int64?
        /// Summed CPU cores' worth of work across members.
        public var cpuCores: Double
        public var energyImpact: Double

        public init(
            rootPid: Int32,
            rootName: String,
            processCount: Int,
            agentCount: Int,
            residentBytes: Int64?,
            cpuCores: Double,
            energyImpact: Double
        ) {
            self.rootPid = rootPid
            self.rootName = rootName
            self.processCount = processCount
            self.agentCount = agentCount
            self.residentBytes = residentBytes
            self.cpuCores = cpuCores
            self.energyImpact = energyImpact
        }
    }

    /// Every session's footprint at one instant.
    public struct Tick: Sendable, Hashable {
        public var timestampMs: Int64
        public var footprints: [Footprint]

        public init(timestampMs: Int64, footprints: [Footprint]) {
            self.timestampMs = timestampMs
            self.footprints = footprints
        }

        public var date: Date { Date(timeIntervalSince1970: Double(timestampMs) / 1000) }
        /// Combined resident memory across all sessions at this instant.
        public var totalResidentBytes: Int64 {
            footprints.compactMap(\.residentBytes).reduce(0, +)
        }
        public var totalCPUCores: Double { footprints.reduce(0) { $0 + $1.cpuCores } }
        public var totalAgentCount: Int { footprints.reduce(0) { $0 + $1.agentCount } }
    }

    /// Splits `samples` into ticks and groups each tick's processes into
    /// sessions. Samples need not be sorted.
    ///
    /// Ticks with no agent process at all are still emitted, with no
    /// footprints, so a caller can tell "no agents were running then" apart
    /// from "nothing was sampled then".
    public static func timeline(samples: [ProcessSample]) -> [Tick] {
        var byTimestamp: [Int64: [ProcessSample]] = [:]
        for sample in samples {
            byTimestamp[sample.timestampMs, default: []].append(sample)
        }
        return byTimestamp.keys.sorted().map { timestampMs in
            Tick(
                timestampMs: timestampMs,
                footprints: footprints(inTick: byTimestamp[timestampMs] ?? [])
            )
        }
    }

    /// Groups the processes of a single tick.
    ///
    /// Public because the sampler uses it too, to decide which processes are
    /// worth recording at all — so the daemon and the app can never disagree
    /// about what counts as a session.
    public static func footprints(inTick samples: [ProcessSample]) -> [Footprint] {
        guard !samples.isEmpty else { return [] }

        // Last writer wins on a duplicated pid within one tick; powermetrics
        // does not emit duplicates, but a merged sample set could.
        var byPid: [Int32: ProcessSample] = [:]
        for sample in samples where sample.pid >= 0 {
            byPid[sample.pid] = sample
        }

        // 1. Every agent process nominates a root: its outermost orchestrator
        //    ancestor, or itself when it has none.
        var rootPids: Set<Int32> = []
        for sample in byPid.values where isAgent(name: sample.name) {
            let chain = ancestorChain(of: sample, in: byPid)
            let orchestrator = chain.last { isOrchestrator(name: $0.name) }
            rootPids.insert(orchestrator?.pid ?? sample.pid)
        }
        guard !rootPids.isEmpty else { return [] }

        // 2. Every process — agent, helper, or compiler spawned three levels
        //    down — is attributed to the outermost root above it. Walking from
        //    the process rather than descending from the root means a member
        //    whose intermediate parent was not sampled still lands correctly as
        //    long as some ancestor was.
        var members: [Int32: [ProcessSample]] = [:]
        for sample in byPid.values {
            let chain = ancestorChain(of: sample, in: byPid)
            guard let root = chain.last(where: { rootPids.contains($0.pid) }) else { continue }
            members[root.pid, default: []].append(sample)
        }

        return members.compactMap { rootPid, processes -> Footprint? in
            guard let root = byPid[rootPid] else { return nil }
            let residents = processes.compactMap(\.residentBytes)
            return Footprint(
                rootPid: rootPid,
                rootName: root.name,
                processCount: processes.count,
                agentCount: processes.filter { isAgent(name: $0.name) }.count,
                residentBytes: residents.isEmpty ? nil : residents.reduce(0, +),
                cpuCores: processes.reduce(0) { $0 + $1.cpuCores },
                energyImpact: processes.reduce(0) { $0 + $1.energyImpact }
            )
        }
        .sorted { lhs, rhs in
            if lhs.cpuCores != rhs.cpuCores { return lhs.cpuCores > rhs.cpuCores }
            return lhs.rootPid < rhs.rootPid
        }
    }

    /// `sample` followed by its ancestors, nearest first, stopping at the first
    /// unsampled parent. A pid that reappears ends the walk: pid reuse (or a
    /// corrupt row) could otherwise form a cycle.
    static func ancestorChain(
        of sample: ProcessSample,
        in byPid: [Int32: ProcessSample]
    ) -> [ProcessSample] {
        var chain = [sample]
        var seen: Set<Int32> = [sample.pid]
        var current = sample
        while chain.count < maxAncestorDepth,
              let ppid = current.ppid,
              ppid > 0,
              !seen.contains(ppid),
              let parent = byPid[ppid] {
            chain.append(parent)
            seen.insert(ppid)
            current = parent
        }
        return chain
    }

    // MARK: - Rollup

    /// Rolls a timeline up into one row per session over the whole window.
    public static func sessions(timeline: [Tick]) -> [AgentSession] {
        struct Key: Hashable {
            var rootPid: Int32
            var rootName: String
        }

        var accumulator: [Key: AgentSession] = [:]
        for tick in timeline {
            for footprint in tick.footprints {
                let key = Key(rootPid: footprint.rootPid, rootName: footprint.rootName)
                let date = tick.date
                if var existing = accumulator[key] {
                    existing.absorb(footprint, at: date)
                    accumulator[key] = existing
                } else {
                    accumulator[key] = AgentSession(footprint: footprint, at: date)
                }
            }
        }

        return accumulator.values.sorted { lhs, rhs in
            if lhs.peakCPUCores != rhs.peakCPUCores { return lhs.peakCPUCores > rhs.peakCPUCores }
            return lhs.rootPid < rhs.rootPid
        }
    }

    /// Convenience: raw samples straight to session rows.
    public static func sessions(samples: [ProcessSample]) -> [AgentSession] {
        sessions(timeline: timeline(samples: samples))
    }
}

/// One agent session's behaviour across a window.
///
/// Peaks matter more than averages here, and are reported alongside them: a
/// machine stalls at the moment eight agents are all resident at once, and an
/// average over an hour hides that moment completely.
public struct AgentSession: Sendable, Hashable, Identifiable {
    /// Stable within a window: pid plus name. Pids are recycled by the kernel
    /// eventually, so across a long window two genuinely different sessions
    /// could collide — rare enough to accept, and the window is the unit of
    /// analysis anyway.
    public var id: String { "\(rootName)#\(rootPid)" }

    public var rootPid: Int32
    public var rootName: String
    /// What to call this session in the interface, e.g. `Rudder`.
    public var label: String { AgentSessions.displayName(for: rootName) }

    /// Most agent processes seen alive at one instant.
    public var peakAgentCount: Int
    /// Most member processes seen at one instant, agents and their children.
    public var peakProcessCount: Int
    /// Largest combined resident memory seen at one instant.
    public var peakResidentBytes: Int64?
    /// Mean combined resident memory across ticks where it was measurable.
    public var meanResidentBytes: Int64?
    /// Largest combined CPU-core demand seen at one instant.
    public var peakCPUCores: Double
    /// Mean combined CPU-core demand across the session's ticks.
    public var meanCPUCores: Double
    /// Summed energy impact, the same currency the battery attribution uses.
    public var energyImpact: Double
    public var firstSeen: Date
    public var lastSeen: Date
    /// Ticks this session appeared in.
    public var tickCount: Int

    /// Running sums, kept so `absorb` can maintain the means without a second pass.
    private var residentSum: Int64 = 0
    private var residentTicks: Int = 0
    private var cpuSum: Double = 0

    init(footprint: AgentSessions.Footprint, at date: Date) {
        rootPid = footprint.rootPid
        rootName = footprint.rootName
        peakAgentCount = footprint.agentCount
        peakProcessCount = footprint.processCount
        peakResidentBytes = footprint.residentBytes
        meanResidentBytes = footprint.residentBytes
        peakCPUCores = footprint.cpuCores
        meanCPUCores = footprint.cpuCores
        energyImpact = footprint.energyImpact
        firstSeen = date
        lastSeen = date
        tickCount = 1
        if let residentBytes = footprint.residentBytes {
            residentSum = residentBytes
            residentTicks = 1
        }
        cpuSum = footprint.cpuCores
    }

    mutating func absorb(_ footprint: AgentSessions.Footprint, at date: Date) {
        peakAgentCount = max(peakAgentCount, footprint.agentCount)
        peakProcessCount = max(peakProcessCount, footprint.processCount)
        if let residentBytes = footprint.residentBytes {
            peakResidentBytes = max(peakResidentBytes ?? 0, residentBytes)
            residentSum += residentBytes
            residentTicks += 1
            meanResidentBytes = residentSum / Int64(residentTicks)
        }
        peakCPUCores = max(peakCPUCores, footprint.cpuCores)
        energyImpact += footprint.energyImpact
        firstSeen = min(firstSeen, date)
        lastSeen = max(lastSeen, date)
        tickCount += 1
        cpuSum += footprint.cpuCores
        meanCPUCores = cpuSum / Double(tickCount)
    }

    /// Wall-clock span the session was observed over.
    public var duration: TimeInterval { lastSeen.timeIntervalSince(firstSeen) }
}
