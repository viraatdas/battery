import Foundation

/// Number and time formatting for insight strings.
///
/// Everything here is locale-independent on purpose: `String(format:)` without a
/// locale always emits `.` as the decimal separator, and the one date formatter
/// is pinned to `en_US_POSIX`. Insight text is therefore a pure function of the
/// data plus the caller's time zone, which is what makes the rules testable.
enum InsightFormat {

    /// A percentage: one decimal below 10, whole numbers above.
    static func percent(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 10 { return String(format: "%.0f%%", value) }
        if magnitude >= 1 { return String(format: "%.1f%%", value) }
        return String(format: "%.1f%%", value)
    }

    /// A drain rate in percentage points per hour.
    static func rate(_ value: Double) -> String {
        String(format: "%.1f%%/hr", value)
    }

    static func watts(_ value: Double) -> String {
        String(format: "%.1f W", value)
    }

    static func wattHours(_ value: Double) -> String {
        abs(value) < 1 ? String(format: "%.2f Wh", value) : String(format: "%.1f Wh", value)
    }

    /// A duration in hours rendered as `4h 10m`, `42m`, or `3m`.
    static func hoursMinutes(_ hours: Double) -> String {
        let totalMinutes = Int((abs(hours) * 60).rounded())
        let wholeHours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if wholeHours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(wholeHours)h" }
        return "\(wholeHours)h \(minutes)m"
    }

    static func duration(seconds: Double) -> String {
        hoursMinutes(seconds / 3600)
    }

    /// Time of day like `2 PM` or `2:30 PM`, in the caller's time zone.
    static func timeOfDay(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let minute = calendar.component(.minute, from: date)
        formatter.dateFormat = minute == 0 ? "h a" : "h:mm a"
        return formatter.string(from: date)
    }

    /// `1,024` — grouped with commas, no locale surprises.
    static func integer(_ value: Int) -> String {
        let digits = String(abs(value))
        var grouped = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        return value < 0 ? "-\(grouped)" : grouped
    }

    /// Joins names as `a`, `a and b`, or `a, b and c`.
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            return "\(head) and \(items[items.count - 1])"
        }
    }

    /// A human label for a window length: `the last 3h`, `the last 45m`.
    static func windowLabel(_ window: TimeWindow) -> String {
        let hours = window.hours
        if hours >= 24 {
            let days = hours / 24
            let rounded = (days * 10).rounded() / 10
            let text = rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
            return "the last \(text)d"
        }
        return "the last \(hoursMinutes(hours))"
    }

    /// Memory sizes in the units people actually use for them: `4.8 GB`,
    /// `640 MB`. Binary units, matching Activity Monitor's arithmetic.
    static func bytes(_ value: Int64) -> String {
        let magnitude = Double(abs(value))
        let gigabyte = 1024.0 * 1024 * 1024
        let megabyte = 1024.0 * 1024
        if magnitude >= gigabyte {
            return String(format: "%.1f GB", Double(value) / gigabyte)
        }
        if magnitude >= megabyte {
            return String(format: "%.0f MB", Double(value) / megabyte)
        }
        return String(format: "%.0f KB", Double(value) / 1024)
    }

    /// A count of CPU cores' worth of work: `6.2 cores`, `1 core`.
    static func cores(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == 1 { return "1 core" }
        return String(format: "%.1f cores", rounded)
    }

    /// `3 agents` / `1 agent`.
    static func agents(_ count: Int) -> String {
        count == 1 ? "1 agent" : "\(count) agents"
    }

    /// A friendly name for a category, for use inside a sentence.
    static func categoryLabel(_ category: ProcessCategory) -> String {
        switch category {
        case .browser: return "browsers"
        case .terminal: return "terminal work"
        case .devtools: return "developer tools"
        case .media: return "media apps"
        case .communication: return "chat and calls"
        case .system: return "system services"
        case .background: return "background processes"
        case .other: return "other apps"
        }
    }
}
