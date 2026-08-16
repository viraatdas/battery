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

    /// Words that name no real app on their own. Helper-stripping can
    /// collapse a name down to one of these — most notably Arc, which names
    /// its own renderer processes generically ("Browser Helper (Renderer)"),
    /// so naive " helper" stripping used to produce the meaningless app name
    /// "Browser". Never report one of these as the canonical name.
    static let genericBareWords: Set<String> = [
        "browser", "helper", "app", "application", "process", "service",
        "host", "agent", "extension", "worker", "container",
    ]

    /// The app name a raw process name should be reported under.
    ///
    /// `bundlePathHint`, when available, resolves cases the name alone
    /// cannot: Arc's helpers are literally named "Browser Helper" /
    /// "Browser Helper (Renderer)" with nothing in the name to say "Arc",
    /// so the `.app` bundle in the path is the only source of truth.
    ///
    /// Returns the trimmed input unchanged when nothing matches, so unknown
    /// processes still appear under their own name.
    public static func canonicalName(for rawName: String, bundlePathHint: String? = nil) -> String {
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
        name = name.trimmingCharacters(in: .whitespaces)

        // Helper-stripping over-merged this into a word that names no real
        // app (Arc's "Browser Helper (Renderer)" -> "Browser"). Prefer the
        // app name implied by the bundle path; failing that, keep the raw
        // name rather than report something meaningless.
        if genericBareWords.contains(name.lowercased()) {
            if let appName = appName(fromBundlePath: bundlePathHint) {
                return appName
            }
            return trimmed
        }

        return name
    }

    /// Extracts the display name of the `.app` bundle a path lives inside,
    /// e.g. "/Applications/Arc.app/Contents/.../Browser Helper" -> "Arc".
    static func appName(fromBundlePath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        for component in path.split(separator: "/") where component.hasSuffix(".app") {
            let name = component.dropLast(".app".count).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return nil
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
