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
    public static func rank(
        samples: [ProcessSample],
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

            for sample in tick where !claimed.contains(sample.pid) {
                // The terminal's own process is what draws the tabs listed
                // above it. Showing it as their peer invites exactly the
                // question this list exists to answer — which tab? — and
                // answers it with the name of the window they all share.
                if TerminalTabs.isTerminal(name: sample.name) { continue }
                let cost = hasEnergy ? sample.energyImpact : sample.cpuCores
                guard cost > 0 else { continue }
                let name = AppNameNormalizer.canonicalName(
                    for: sample.name,
                    bundlePathHint: sample.bundlePathHint
                )
                merge(
                    into: &accumulated,
                    key: name,
                    row: Row(
                        id: name,
                        label: name,
                        detail: nil,
                        kind: .application,
                        category: sample.category,
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

        let total = rows.reduce(0) { $0 + $1.cost }
        let ranked = rows
            .prefix(limit)
            .map { row -> Row in
                var updated = row
                updated.sharePct = total > 0 ? row.cost / total * 100 : nil
                return updated
            }

        return Result(basis: basis, rows: Array(ranked))
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

        public init(basis: Basis, rows: [Row]) {
            self.basis = basis
            self.rows = rows
        }

        public var isEmpty: Bool { rows.isEmpty }
    }
}
