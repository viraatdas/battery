import Foundation

/// Splits a window's measured battery discharge across apps and categories.
///
/// macOS gives us a unitless energy-impact score per process, never joules. So
/// the split is proportional: an app holding 20% of the window's total energy
/// impact is credited with 20% of the watt-hours the battery actually lost. It
/// ranks well and the totals reconcile, but any single app's watt-hours is an
/// estimate, not a measurement.
public enum Attribution {

    /// Merges helper processes into their parent app and apportions the measured
    /// discharge across the result.
    ///
    /// - Parameters:
    ///   - totals: per-process totals, typically from `SQLiteStore.processTotals`.
    ///   - dischargeWh: watt-hours the battery actually lost over the window.
    ///   - percentDrained: battery percentage points actually lost over the window.
    public static func processUsage(
        totals: [ProcessTotals],
        dischargeWh: Double,
        percentDrained: Double
    ) -> [ProcessUsage] {
        struct Accumulator {
            var energyImpact: Double = 0
            var peakEnergyImpact: Double = 0
            var sampleCount: Int = 0
            var rawNames: Set<String> = []
            /// Energy impact per category, so the merged row takes the category
            /// its heaviest processes actually belong to.
            var energyByCategory: [ProcessCategory: Double] = [:]
        }

        var merged: [String: Accumulator] = [:]
        var order: [String] = []

        for row in totals {
            let canonical = AppNameNormalizer.canonicalName(for: row.name)
            guard !canonical.isEmpty else { continue }
            if merged[canonical] == nil { order.append(canonical) }
            var accumulator = merged[canonical] ?? Accumulator()
            accumulator.energyImpact += row.energyImpact
            accumulator.peakEnergyImpact = max(accumulator.peakEnergyImpact, row.peakEnergyImpact)
            accumulator.sampleCount += row.sampleCount
            accumulator.rawNames.insert(row.name)
            accumulator.energyByCategory[row.category, default: 0] += row.energyImpact
            merged[canonical] = accumulator
        }

        let totalEnergy = merged.values.reduce(0) { $0 + $1.energyImpact }

        let usage: [ProcessUsage] = order.compactMap { name in
            guard let accumulator = merged[name] else { return nil }
            let share = totalEnergy > 0 ? accumulator.energyImpact / totalEnergy : 0
            return ProcessUsage(
                name: name,
                category: dominantCategory(accumulator.energyByCategory, canonicalName: name),
                energyImpact: accumulator.energyImpact,
                sharePct: share * 100,
                estimatedWh: dischargeWh * share,
                estimatedPercentPoints: percentDrained * share,
                peakEnergyImpact: accumulator.peakEnergyImpact,
                sampleCount: accumulator.sampleCount,
                mergedProcessNames: accumulator.rawNames.sorted()
            )
        }

        return usage.sorted {
            if $0.energyImpact != $1.energyImpact { return $0.energyImpact > $1.energyImpact }
            return $0.name < $1.name
        }
    }

    /// Rolls merged per-app usage up by category, keeping each category's top
    /// three apps. Categories with no measured energy are omitted.
    public static func categoryUsage(
        processes: [ProcessUsage],
        topProcessesPerCategory: Int = 3
    ) -> [CategoryUsage] {
        var grouped: [ProcessCategory: [ProcessUsage]] = [:]
        for process in processes {
            grouped[process.category, default: []].append(process)
        }

        let rollups = grouped.map { category, members -> CategoryUsage in
            let ranked = members.sorted {
                if $0.energyImpact != $1.energyImpact { return $0.energyImpact > $1.energyImpact }
                return $0.name < $1.name
            }
            return CategoryUsage(
                category: category,
                energyImpact: ranked.reduce(0) { $0 + $1.energyImpact },
                sharePct: ranked.reduce(0) { $0 + $1.sharePct },
                estimatedWh: ranked.reduce(0) { $0 + $1.estimatedWh },
                estimatedPercentPoints: ranked.reduce(0) { $0 + $1.estimatedPercentPoints },
                topProcesses: Array(ranked.prefix(max(0, topProcessesPerCategory)))
            )
        }

        return rollups.sorted {
            if $0.energyImpact != $1.energyImpact { return $0.energyImpact > $1.energyImpact }
            return $0.category.rawValue < $1.category.rawValue
        }
    }

    /// The category a merged app belongs to: whichever category its heaviest
    /// processes sat in. Ties break alphabetically so the result is stable.
    ///
    /// When the winner is `.other` (helpers often carry no useful name), the
    /// canonical app name gets one more pass through the categorizer — merging
    /// `Google Chrome Helper` into `Google Chrome` can rescue a classification
    /// the helper name alone could not produce.
    static func dominantCategory(
        _ energyByCategory: [ProcessCategory: Double],
        canonicalName: String
    ) -> ProcessCategory {
        let winner = energyByCategory
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key.rawValue < $1.key.rawValue
            }
            .first?.key ?? .other

        guard winner == .other else { return winner }
        return Categorizer.categorize(name: canonicalName)
    }
}
