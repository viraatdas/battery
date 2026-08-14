import BatteryCore
import SwiftUI

/// The single source of truth for how a `ProcessCategory` looks and reads.
///
/// The stacked bar, the legend, the offender badges and the chart all pull from
/// here, so a category can never be one colour in one place and another colour
/// twenty points below it.
enum CategoryStyle {

    /// Display order: user-facing work first, machine overhead last. Also the
    /// order the stacked bar is drawn in, so the bar is stable across refreshes
    /// even as shares move around.
    static let order: [ProcessCategory] = [
        .browser, .devtools, .terminal, .media, .communication, .system, .background, .other,
    ]

    static func label(_ category: ProcessCategory) -> String {
        switch category {
        case .browser: return "Browser"
        case .terminal: return "Terminal"
        case .devtools: return "Dev tools"
        case .media: return "Media"
        case .communication: return "Communication"
        case .system: return "System"
        case .background: return "Background"
        case .other: return "Other"
        }
    }

    static func symbol(_ category: ProcessCategory) -> String {
        switch category {
        case .browser: return "globe"
        case .terminal: return "terminal"
        case .devtools: return "hammer"
        case .media: return "play.rectangle"
        case .communication: return "bubble.left.and.bubble.right"
        case .system: return "gearshape"
        case .background: return "clock.arrow.circlepath"
        case .other: return "square.dashed"
        }
    }

    /// System colours only, so both appearances stay legible and the palette
    /// matches the rest of macOS rather than inventing a brand.
    static func color(_ category: ProcessCategory) -> Color {
        switch category {
        case .browser: return .blue
        case .terminal: return .green
        case .devtools: return .indigo
        case .media: return .pink
        case .communication: return .teal
        case .system: return .gray
        case .background: return .orange
        case .other: return .secondary
        }
    }

    /// Sorts a breakdown into display order regardless of how it arrived.
    static func sorted(_ usage: [CategoryUsage]) -> [CategoryUsage] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return usage.sorted { (rank[$0.category] ?? .max) < (rank[$1.category] ?? .max) }
    }
}
