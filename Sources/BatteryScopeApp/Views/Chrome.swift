import SwiftUI

/// Shared layout constants. One place to change the rhythm of the whole panel.
enum Metrics {
    static let popoverWidth: CGFloat = 420
    static let popoverMaxHeight: CGFloat = 720
    /// Horizontal inset used by every section, so all content shares one margin.
    static let inset: CGFloat = 16
    /// Space between sections.
    static let sectionSpacing: CGFloat = 18
    /// Space between rows inside a section.
    static let rowSpacing: CGFloat = 8
}

/// A titled block of content: small uppercase heading, optional trailing accessory,
/// optional footnote underneath. Every section of the popover uses it, which is
/// what makes the panel read as one document instead of six widgets.
struct PanelSection<Content: View, Accessory: View>: View {
    var title: String
    var footnote: String?
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.4)
                Spacer(minLength: 8)
                accessory
            }
            content
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Metrics.inset)
    }
}

extension PanelSection where Accessory == EmptyView {
    init(title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, footnote: footnote, content: content, accessory: { EmptyView() })
    }
}

/// A horizontal rule that matches the popover's insets.
struct SectionDivider: View {
    var body: some View {
        Divider().padding(.horizontal, Metrics.inset)
    }
}

/// A thin proportional bar. Used for offender shares and the category stack, so
/// both read at the same weight.
struct ShareBar: View {
    var fraction: Double
    var color: Color
    var width: CGFloat
    var height: CGFloat = 6

    var body: some View {
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(.quaternary)
            Capsule(style: .continuous)
                .fill(color)
                .frame(width: max(clamped > 0 ? 3 : 0, width * clamped))
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// A short line of italic-free small print, for the "these are estimates" notes
/// that this app is obliged to show wherever it apportions rather than measures.
struct Footnote: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Nothing to show" copy in the same voice everywhere.
struct EmptyHint: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}

extension Text {
    /// Numbers must not reflow as they change; every figure in this app is
    /// tabular.
    func numeric() -> Text { self.monospacedDigit() }
}
