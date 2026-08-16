import SwiftUI

/// Set by `SelfTest` while it renders the panel to a bitmap.
///
/// `.pickerStyle(.segmented)` is `NSSegmentedControl` under the hood, and that
/// control needs a real window to draw its segments into. Asked to draw inside
/// an `ImageRenderer`'s offscreen context, it paints a solid block with a "no
/// entry" glyph instead — which is unreadable in a PNG meant to be eyeballed.
/// Views with a segmented picker check this environment value and substitute a
/// static, non-interactive stand-in when it is set. The live app never sets
/// it, so nothing here changes what a real popover shows.
private struct IsOffscreenRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isOffscreenRender: Bool {
        get { self[IsOffscreenRenderKey.self] }
        set { self[IsOffscreenRenderKey.self] = newValue }
    }
}
