import Foundation

/// The one list worth showing: what is eating the most power, in order.
///
/// Everything else this tool measures — memory, disk, load, thermal — exists to
/// explain a stall. This exists to answer the ordinary question, and it answers
/// it in the terms a person can act on: not "Ghostty, 40%", which is useless
/// with eight tabs open, but the tab, named after the folder it is sitting in.
public enum EnergyRanking {

    /// How a ranking was measured, which governs how much weight to put on it.
    public enum Basis: String, Sendable, Hashable {
        /// powermetrics energy impact, apportioned from the battery's measured
        /// discharge. The real answer, and root-only.
        case energy
        /// CPU time, which is the dominant term in what a laptop spends power
        /// on but is not the whole of it. What you get without root.
        case cpu

        public var label: String {
            switch self {
            case .energy: return "energy"
            case .cpu: return "CPU"
            }
        }
    }

    /// Below this, a row is not worth a line.
    ///
    /// An idle Mac still has a hundred processes ticking over at a thousandth
    /// of a core, and ranking those produces a confident list of `distnoted`,
    /// `suggestd`, and `IMDPersistenceAgent` that means nothing. The honest
    /// answer when nothing is running is that nothing is running.
    public static let minimumCores: Double = 0.02
    /// The same floor on the energy basis, where the unit is powermetrics'
    /// dimensionless impact score rather than cores.
    public static let minimumEnergyImpact: Double = 1.0

    /// Builds the ranking over `samples`, which may be one tick or a window.
    ///
    /// Terminal processes collapse into their tab; everything else is grouped
    /// by application name. Rows with no measurable cost are dropped rather
    /// than listed at zero.
    /// - Parameter machineCores: the whole machine's measured CPU demand over
    ///   the same span, from the kernel's tick counters. This is the
    ///   *denominator*: without it a share is a share of whatever happened to
    ///   be tracked, which on a real machine was 0.6 cores out of 3 — so a row
    ///   reading "75%" meant 75% of a fifth of the truth. Pass `nil` only when
    ///   there is genuinely no pressure data.
    /// - Parameter processCores: the summed CPU of *every* process over the
    ///   same span. Sits between the listed rows and the machine total, and
    ///   splits the difference into two very different things: processes this
    ///   list left out, and CPU that belongs to no process at all.
    public static func rank(
        samples: [ProcessSample],
        machineCores: Double? = nil,
        processCores: Double? = nil,
        limit: Int = 8
    ) -> EnergyRanking.Result {
        guard !samples.isEmpty else { return Result(basis: .cpu, rows: []) }

        // Energy impact is only present when the root sampler wrote these rows.
        let hasEnergy = samples.contains { $0.energyImpact > 0 }
        let basis: Basis = hasEnergy ? .energy : .cpu

        // Tabs are resolved per tick, because a pid's tab membership is a fact
        // about that instant, then merged across ticks by label.
        var byTick: [Int64: [ProcessSample]] = [:]
        for sample in samples {
            byTick[sample.timestampMs, default: []].append(sample)
        }

        var accumulated: [String: Row] = [:]
        var tickCount = 0
        for (_, tick) in byTick {
            tickCount += 1
            let tabs = TerminalTabs.tabs(inTick: tick)
            let claimed = Set(tabs.flatMap(\.pids))

            for tab in tabs {
                let cost = hasEnergy ? tab.energyImpact : tab.cpuCores
                guard cost > 0 else { continue }
                merge(
                    into: &accumulated,
                    key: "tab#\(tab.rootPid)",
                    row: Row(
                        id: "tab#\(tab.rootPid)",
                        label: tab.label,
                        detail: tab.detail,
                        kind: .terminalTab,
                        category: .terminal,
                        cost: cost,
                        residentBytes: tab.residentBytes
                    )
                )
            }

            var byPid: [Int32: ProcessSample] = [:]
            for sample in tick where sample.pid >= 0 { byPid[sample.pid] = sample }

            for sample in tick where !claimed.contains(sample.pid) {
                // The terminal's own process is what draws the tabs listed
                // above it. Showing it as their peer invites exactly the
                // question this list exists to answer — which tab? — and
                // answers it with the name of the window they all share.
                if TerminalTabs.isTerminal(name: sample.name) { continue }
                let cost = hasEnergy ? sample.energyImpact : sample.cpuCores
                guard cost > 0 else { continue }
                let launched = launchedApp(for: sample, in: byPid)
                let name = AppNameNormalizer.canonicalName(
                    for: launched.name,
                    bundlePathHint: launched.bundlePathHint
                )
                merge(
                    into: &accumulated,
                    key: name,
                    row: Row(
                        id: name,
                        label: name,
                        detail: nil,
                        kind: .application,
                        category: launched.category,
                        cost: cost,
                        residentBytes: sample.residentBytes
                    )
                )
            }
        }

        // Averaged over ticks so a window and a single instant are on the same
        // scale, and so a process that ran for one tick of ten does not
        // outrank one that ran through all of them.
        let divisor = Double(max(tickCount, 1))
        let floor = hasEnergy ? minimumEnergyImpact : minimumCores
        let rows = accumulated.values
            .map { row -> Row in
                var averaged = row
                averaged.cost = row.cost / divisor
                return averaged
            }
            .filter { $0.cost >= floor }
            .sorted { $0.cost > $1.cost }

        let attributed = rows.reduce(0) { $0 + $1.cost }

        // The denominator is the machine, not the list. Only CPU has a
        // machine-wide total to measure against; powermetrics' energy impact is
        // a dimensionless score with no such ceiling, so an energy ranking
        // stays a share of what was attributed — but it is a *complete*
        // attribution, which is why that is honest there and was not here.
        let total: Double
        let unattributed: Double
        if basis == .cpu, let machineCores, machineCores > 0 {
            total = max(machineCores, attributed)
            unattributed = max(0, machineCores - attributed)
        } else {
            total = attributed
            unattributed = 0
        }

        var ranked = rows
            .prefix(limit)
            .map { row -> Row in
                var updated = row
                updated.sharePct = total > 0 ? row.cost / total * 100 : nil
                return updated
            }

        // What the list does not name, split by *why* it does not.
        //
        // The second category is not a gap in this list, and it is not all
        // kernel time either. `proc_pidinfo` and `proc_pid_rusage` are both
        // denied for processes this user does not own, so an unprivileged
        // sampler cannot read the CPU of any root-owned process — and on a
        // real machine the two heaviest were `syspolicyd` and `WindowServer`,
        // both root. `/bin/ps` manages it only by being setuid root.
        //
        // So the remainder is genuine kernel work *plus* every root process,
        // and without privilege the two cannot be separated. Saying so is the
        // honest option; calling it "System — kernel, drivers, interrupts"
        // was not, because most of it is ordinary software this tool simply
        // is not allowed to look at.
        let listed = ranked.reduce(0) { $0 + $1.cost }
        func appendRemainder(_ id: String, _ label: String, _ detail: String?, _ cost: Double) {
            guard total > 0, cost / total >= 0.01 else { return }
            ranked.append(Row(
                id: id, label: label, detail: detail, kind: .remainder,
                category: .other, cost: cost, residentBytes: nil,
                sharePct: cost / total * 100
            ))
        }

        if basis == .cpu, let machineCores, machineCores > 0, let processCores {
            let others = max(0, min(processCores, total) - listed)
            appendRemainder("other-processes", "Other processes", "not listed individually", others)
            appendRemainder(
                "system", "System & root processes", "needs root to break down",
                max(0, machineCores - max(processCores, listed))
            )
        } else {
            appendRemainder("everything-else", "Everything else", nil, max(0, total - listed))
        }

        return Result(
            basis: basis,
            rows: Array(ranked),
            machineCores: machineCores,
            processCores: processCores
        )
    }

    /// Mean cores busy across `pressure`, machine-wide.
    ///
    /// Pairs each sample with its predecessor, since the tick counters only
    /// mean something as a difference, and skips pairs that span a sleep, a
    /// stall, or a sampler restart — the same gaps the timeline refuses.
    public static func machineCores(pressure: [PressureSample]) -> Double? {
        let sorted = pressure.sorted { $0.timestampMs < $1.timestampMs }
        guard sorted.count > 1 else { return nil }
        var total = 0.0
        var weight = 0.0
        for index in 1..<sorted.count {
            let previous = sorted[index - 1]
            let current = sorted[index]
            let seconds = Double(current.timestampMs - previous.timestampMs) / 1000
            guard seconds > 0, seconds <= 180, current.isSameSamplerRun(as: previous),
                  let cores = current.cpuCoresBusy(since: previous) else { continue }
            total += cores * seconds
            weight += seconds
        }
        return weight > 0 ? total / weight : nil
    }

    /// The process the *human* started, which is the one worth naming.
    ///
    /// Modern apps fan out into helpers with names that mean nothing on their
    /// own — "Browser Helper (Renderer)" tells you neither which app nor which
    /// page. Walking up to the process just below `launchd` recovers the
    /// answer, because that is where a user-launched app sits: the renderer's
    /// parent is Arc, and Arc's parent is launchd.
    ///
    /// Falls back to the process itself when the chain cannot be followed —
    /// a daemon launchd started directly is already its own root, and a
    /// process whose ancestors were not sampled has nothing better to offer.
    static func launchedApp(
        for sample: ProcessSample,
        in byPid: [Int32: ProcessSample]
    ) -> ProcessSample {
        var current = sample
        var seen: Set<Int32> = [sample.pid]
        var depth = 0
        while depth < 24,
              let ppid = current.ppid,
              ppid > 1,
              !seen.contains(ppid),
              let parent = byPid[ppid] {
            // A terminal is a launcher, not the launched thing: work started in
            // a tab belongs to the tab, which is handled before this is reached.
            if TerminalTabs.isTerminal(name: parent.name) { return current }
            seen.insert(ppid)
            current = parent
            depth += 1
        }
        return current
    }

    private static func merge(into accumulated: inout [String: Row], key: String, row: Row) {
        if var existing = accumulated[key] {
            existing.cost += row.cost
            if let resident = row.residentBytes {
                existing.residentBytes = max(existing.residentBytes ?? 0, resident)
            }
            // A tab's command changes as you run things in it; the latest is
            // the one worth showing.
            if row.detail != nil { existing.detail = row.detail }
            accumulated[key] = existing
        } else {
            accumulated[key] = row
        }
    }

    /// What a row represents.
    public enum Kind: String, Sendable, Hashable {
        case terminalTab
        case application
        /// The machine's CPU that no listed row accounts for.
        case remainder
    }

    /// One line of the list.
    public struct Row: Sendable, Hashable, Identifiable {
        public var id: String
        /// What to call it: a tab's folder, or an app's name.
        public var label: String
        /// For a tab, what is running in it.
        public var detail: String?
        public var kind: Kind
        public var category: ProcessCategory
        /// Energy impact or CPU cores, depending on the basis.
        public var cost: Double
        public var residentBytes: Int64?
        /// Share of everything measured, 0...100.
        public var sharePct: Double?

        public init(
            id: String,
            label: String,
            detail: String?,
            kind: Kind,
            category: ProcessCategory,
            cost: Double,
            residentBytes: Int64?,
            sharePct: Double? = nil
        ) {
            self.id = id
            self.label = label
            self.detail = detail
            self.kind = kind
            self.category = category
            self.cost = cost
            self.residentBytes = residentBytes
            self.sharePct = sharePct
        }
    }

    public struct Result: Sendable, Hashable {
        public var basis: Basis
        public var rows: [Row]
        /// The machine's measured CPU demand the shares are against, when there
        /// was one. `nil` means the shares are relative to the list itself.
        public var machineCores: Double?
        /// Summed CPU of every process over the same span, when measured.
        public var processCores: Double?

        public init(
            basis: Basis,
            rows: [Row],
            machineCores: Double? = nil,
            processCores: Double? = nil
        ) {
            self.basis = basis
            self.rows = rows
            self.machineCores = machineCores
            self.processCores = processCores
        }

        public var isEmpty: Bool { rows.isEmpty }
    }
}
