import Foundation

/// Number, duration and date formatting for the UI.
///
/// Kept free of SwiftUI on purpose: every string the interface shows is produced
/// by one of these pure functions, so the views stay declarative and the
/// formatting rules are checkable in isolation.
enum Fmt {

    // MARK: - Battery

    /// `84%` — battery charge is never shown with decimals; it isn't that precise.
    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value.rounded())
    }

    /// `6.2%` — a share of a total, one decimal below 10.
    static func share(_ value: Double) -> String {
        abs(value) >= 10 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    /// `6.2W`, compact enough for the menu bar.
    static func wattsCompact(_ value: Double) -> String {
        String(format: "%.1fW", abs(value))
    }

    /// `6.2 W`, for body text.
    static func watts(_ value: Double) -> String {
        String(format: "%.1f W", abs(value))
    }

    /// `1.24 Wh` below one watt-hour, `12.4 Wh` above it.
    static func wattHours(_ value: Double) -> String {
        abs(value) < 1 ? String(format: "%.2f Wh", value) : String(format: "%.1f Wh", value)
    }

    /// `7.4%/hr`
    static func rate(_ value: Double) -> String {
        String(format: "%.1f%%/hr", value)
    }

    // MARK: - Durations

    /// `4h 10m`, `42m`, `3m`. Never `0h 42m`.
    static func hoursMinutes(_ hours: Double) -> String {
        let totalMinutes = Int((abs(hours) * 60).rounded())
        let wholeHours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if wholeHours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(wholeHours)h" }
        return "\(wholeHours)h \(minutes)m"
    }

    /// How stale a reading is: `just now`, `20s ago`, `4m ago`, `2h ago`.
    static func age(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        if value < 5 { return "just now" }
        if value < 90 { return "\(Int(value.rounded()))s ago" }
        if value < 5400 { return "\(Int((value / 60).rounded()))m ago" }
        if value < 172_800 { return "\(Int((value / 3600).rounded()))h ago" }
        return "\(Int((value / 86400).rounded()))d ago"
    }

    /// Clock time for a chart axis. On-the-hour ticks drop their `:00`, which is
    /// both tidier and narrow enough that the last label on an axis is not
    /// truncated.
    static func clock(_ date: Date) -> String {
        let minute = Calendar.current.component(.minute, from: date)
        let template = minute == 0 ? "j" : "j:mm"
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: template, options: 0, locale: .autoupdatingCurrent
        ) ?? (minute == 0 ? "HH" : "HH:mm")
        return formatter.string(from: date)
    }

    /// `1,024`, grouped without pulling in a locale-dependent formatter.
    static func integer(_ value: Int) -> String {
        let digits = String(abs(value))
        var grouped = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        return value < 0 ? "-\(grouped)" : grouped
    }

    // MARK: - Estimates

    /// Marks a number as apportioned rather than measured. Every per-app energy
    /// figure in this app goes through here, so nothing estimated is ever shown
    /// with the same authority as a meter reading.
    static func estimated(_ text: String) -> String { "~" + text }
}
