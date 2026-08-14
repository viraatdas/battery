import Foundation

/// Folds helper/renderer/XPC processes into the app a person would recognise.
///
/// Chrome alone shows up as a dozen `Google Chrome Helper (Renderer)` rows, and
/// Safari's real work happens in `com.apple.WebKit.WebContent`. Reporting those
/// separately buries the answer to "what is using my battery", so every helper
/// is attributed to its parent app.
public enum AppNameNormalizer {

    /// Exact lowercase names that belong to a known parent app.
    static let exactAliases: [String: String] = [
        "safari web content": "Safari",
        "safari web content (cached)": "Safari",
        "safari networking": "Safari",
        "safari graphics and media": "Safari",
        "safariplatformsupport": "Safari",
        "com.apple.safari.searchhelper": "Safari",
        "webkit.networking": "Safari",
        "webkit web content": "Safari",
        "firefox content process": "Firefox",
        "firefoxcp": "Firefox",
        "plugin-container": "Firefox",
    ]

    /// Lowercase prefixes that identify a parent app regardless of the suffix.
    static let prefixAliases: [(prefix: String, parent: String)] = [
        ("com.apple.webkit", "Safari"),
        ("com.google.chrome.helper", "Google Chrome"),
        ("com.brave.browser.helper", "Brave Browser"),
    ]

    /// Parenthetical role tags helper processes carry, e.g. `Foo (Renderer)`.
    static let roleSuffixes: Set<String> = [
        "renderer", "gpu", "gpu process", "gpu-process", "plugin", "network",
        "networking", "utility", "cached data", "web content", "extension",
        "alerts", "helper",
    ]

    /// The app name a raw process name should be reported under.
    ///
    /// Returns the trimmed input unchanged when nothing matches, so unknown
    /// processes still appear under their own name.
    public static func canonicalName(for rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lowered = trimmed.lowercased()

        if let alias = exactAliases[lowered] { return alias }
        for entry in prefixAliases where lowered.hasPrefix(entry.prefix) {
            return entry.parent
        }

        var name = trimmed

        // "Google Chrome Helper (Renderer)" / "Slack Helper" -> parent app.
        if let helperRange = name.lowercased().range(of: " helper") {
            let base = String(name[name.startIndex..<helperRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !base.isEmpty { name = base }
        }

        name = strippingRoleParenthetical(name)
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Drops a trailing `(Renderer)`-style role tag, keeping real parentheses
    /// that are part of an app's own name.
    static func strippingRoleParenthetical(_ name: String) -> String {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        let inner = name[name.index(after: open)..<name.index(before: name.endIndex)]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard roleSuffixes.contains(inner) else { return name }
        let base = String(name[name.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? name : base
    }
}
