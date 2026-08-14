import BatteryCore
import Foundation

/// What the menu bar shows at a glance, derived from the newest sample.
///
/// Split out from the view so the rule — "on battery you get the draw, on power
/// you get the charge level" — is one small function rather than a pile of
/// conditionals inside a `Text`.
struct MenuBarSummary: Equatable {
    var symbol: String
    var text: String
    /// Spoken description for VoiceOver, since the visual form is terse.
    var accessibility: String

    static let placeholder = MenuBarSummary(
        symbol: "battery.100",
        text: "--",
        accessibility: "BatteryScope, no data yet"
    )

    init(symbol: String, text: String, accessibility: String) {
        self.symbol = symbol
        self.text = text
        self.accessibility = accessibility
    }

    init(sample: BatterySample?) {
        guard let sample else { self = .placeholder; return }

        if sample.isCharging || sample.externalPower {
            let level = Fmt.percent(sample.percent)
            self.init(
                symbol: sample.isCharging ? "battery.100.bolt" : "powerplug",
                text: level,
                accessibility: sample.isCharging
                    ? "Charging, \(level)"
                    : "On power, \(level)"
            )
            return
        }

        // Discharging: the draw is the number worth a permanent slot in the menu
        // bar, because it is the one that changes when you close a tab.
        let draw = abs(sample.wattsDrawn)
        if draw > 0.05 {
            self.init(
                symbol: MenuBarSummary.batterySymbol(for: sample.percent),
                text: Fmt.wattsCompact(draw),
                accessibility: "On battery, drawing \(Fmt.watts(draw)), \(Fmt.percent(sample.percent))"
            )
        } else {
            let level = Fmt.percent(sample.percent)
            self.init(
                symbol: MenuBarSummary.batterySymbol(for: sample.percent),
                text: level,
                accessibility: "On battery, \(level)"
            )
        }
    }

    static func batterySymbol(for percent: Double) -> String {
        switch percent {
        case ..<12.5: return "battery.0percent"
        case ..<37.5: return "battery.25percent"
        case ..<62.5: return "battery.50percent"
        case ..<87.5: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// The header line: charge, draw, and what that means for the rest of the day.
struct StatusSummary {
    var percent: Double
    var isCharging: Bool
    var externalPower: Bool
    /// Instantaneous draw from the newest sample, `nil` when not discharging.
    var watts: Double?
    /// Median-rate runtime estimate from the analytics layer.
    var hoursRemaining: Double?
    var sampleAge: TimeInterval?

    init(snapshot: Snapshot) {
        let health = snapshot.report.health
        let sample = snapshot.latest
        percent = sample?.percent ?? health?.percent ?? 0
        isCharging = sample?.isCharging ?? health?.isCharging ?? false
        externalPower = sample?.externalPower ?? health?.externalPower ?? false
        let draw = sample.map { abs($0.wattsDrawn) } ?? 0
        watts = (!isCharging && !externalPower && draw > 0.05) ? draw : nil
        hoursRemaining = health?.estimatedHoursRemaining
        sampleAge = snapshot.sampleAge
    }

    var stateText: String {
        if isCharging { return "Charging" }
        if externalPower { return "On power" }
        return "On battery"
    }

    var stateSymbol: String {
        if isCharging { return "bolt.fill" }
        if externalPower { return "powerplug.fill" }
        return MenuBarSummary.batterySymbol(for: percent)
    }

    /// `4h 10m left` when we have measured drain to base it on, otherwise an
    /// honest shrug rather than a made-up number.
    var remainingText: String {
        if isCharging { return "Charging" }
        if externalPower { return "Plugged in" }
        guard let hoursRemaining, hoursRemaining.isFinite, hoursRemaining > 0 else {
            return "Not enough drain measured"
        }
        return "\(Fmt.hoursMinutes(hoursRemaining)) left"
    }

    var freshnessText: String {
        guard let sampleAge else { return "No samples yet" }
        return "Last sample \(Fmt.age(sampleAge))"
    }

    /// The sampler stopped writing. Worth saying out loud, because every number
    /// on screen is only as current as the newest row.
    var isStale: Bool { (sampleAge ?? .infinity) > 300 }
}
