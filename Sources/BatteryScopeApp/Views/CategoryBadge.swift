import BatteryCore
import SwiftUI

/// The small category pill used beside an app name.
struct CategoryBadge: View {
    var category: ProcessCategory

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: CategoryStyle.symbol(category))
                .font(.system(size: 8, weight: .semibold))
            Text(CategoryStyle.label(category))
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(CategoryStyle.color(category))
        .background(CategoryStyle.color(category).opacity(0.14), in: Capsule(style: .continuous))
        .accessibilityHidden(true)
    }
}
