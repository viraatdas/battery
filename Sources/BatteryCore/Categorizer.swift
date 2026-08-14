import Foundation

/// Classifies a process into a `ProcessCategory` from its name and optional bundle path.
///
/// Classification is pure and deterministic: an ordered rule table is matched
/// case-insensitively against the process name, then against the bundle path hint.
/// The first matching rule wins. If nothing matches, a daemon-shape heuristic
/// assigns `.background`, otherwise `.other`.
public enum Categorizer {

    /// How a rule's pattern is compared against the (lowercased) candidate string.
    enum Match: Sendable {
        case exact(String)
        case prefix(String)
        case contains(String)

        func matches(_ candidate: String) -> Bool {
            switch self {
            case .exact(let pattern):
                return candidate == pattern
            case .prefix(let pattern):
                return candidate.hasPrefix(pattern)
            case .contains(let pattern):
                return candidate.contains(pattern)
            }
        }
    }

    struct Rule: Sendable {
        var match: Match
        var category: ProcessCategory

        init(_ match: Match, _ category: ProcessCategory) {
            self.match = match
            self.category = category
        }
    }

    /// Ordered rule table; earlier rules win. All patterns are lowercase.
    /// Keep short generic words (`go`, `git`, `arc`) as `.exact` so they never
    /// swallow unrelated names (`google chrome`, `archive utility`, ...).
    static let rules: [Rule] = [
        // Browsers
        .init(.prefix("google chrome"), .browser),
        .init(.prefix("chromium"), .browser),
        .init(.exact("safari"), .browser),
        // "Safari Networking", "Safari Web Content", ... but NOT
        // SafariNotificationAgent-style daemons (no space).
        .init(.prefix("safari "), .browser),
        .init(.contains("com.apple.webkit"), .browser),
        .init(.exact("arc"), .browser),
        .init(.prefix("arc helper"), .browser),
        .init(.prefix("firefox"), .browser),
        .init(.prefix("brave"), .browser),
        .init(.exact("dia"), .browser),
        .init(.prefix("dia helper"), .browser),

        // Terminals & shells
        .init(.exact("terminal"), .terminal),
        .init(.prefix("iterm"), .terminal),
        .init(.prefix("ghostty"), .terminal),
        .init(.prefix("alacritty"), .terminal),
        .init(.exact("kitty"), .terminal),
        .init(.prefix("wezterm"), .terminal),
        .init(.exact("tmux"), .terminal),
        .init(.exact("zsh"), .terminal),
        .init(.exact("-zsh"), .terminal),
        .init(.exact("bash"), .terminal),
        .init(.exact("-bash"), .terminal),
        .init(.exact("fish"), .terminal),
        .init(.exact("sh"), .terminal),

        // Dev tools, runtimes, compilers
        .init(.exact("node"), .devtools),
        .init(.exact("bun"), .devtools),
        .init(.exact("deno"), .devtools),
        .init(.prefix("python"), .devtools),
        .init(.exact("ruby"), .devtools),
        .init(.exact("java"), .devtools),
        .init(.exact("javac"), .devtools),
        .init(.prefix("docker"), .devtools),
        .init(.prefix("com.docker."), .devtools),
        .init(.prefix("xcode"), .devtools),
        .init(.prefix("swift"), .devtools),
        .init(.prefix("clang"), .devtools),
        .init(.exact("cargo"), .devtools),
        .init(.exact("rustc"), .devtools),
        .init(.exact("go"), .devtools),
        .init(.exact("git"), .devtools),
        .init(.prefix("git-"), .devtools),
        .init(.exact("claude"), .devtools),
        .init(.exact("codex"), .devtools),
        .init(.exact("ollama"), .devtools),
        .init(.exact("npm"), .devtools),
        .init(.exact("pnpm"), .devtools),
        .init(.exact("yarn"), .devtools),
        .init(.exact("make"), .devtools),
        .init(.exact("cmake"), .devtools),
        .init(.exact("ld"), .devtools),
        .init(.exact("sourcekit-lsp"), .devtools),

        // Media & audio
        .init(.prefix("spotify"), .media),
        .init(.exact("music"), .media),
        .init(.exact("coreaudiod"), .media),
        .init(.contains("airplay"), .media),
        .init(.prefix("quicktime"), .media),
        .init(.exact("vlc"), .media),

        // Communication
        .init(.prefix("slack"), .communication),
        .init(.prefix("zoom"), .communication),
        .init(.prefix("discord"), .communication),
        .init(.exact("messages"), .communication),
        .init(.exact("mail"), .communication),
        .init(.exact("facetime"), .communication),

        // Core OS services
        .init(.exact("windowserver"), .system),
        .init(.exact("kernel_task"), .system),
        .init(.prefix("mds"), .system),
        .init(.prefix("mdworker"), .system),
        .init(.exact("bluetoothd"), .system),
        .init(.exact("corespotlightd"), .system),
        .init(.exact("backupd"), .system),
        .init(.exact("photoanalysisd"), .system),
        .init(.exact("cloudd"), .system),
        .init(.exact("bird"), .system),
        .init(.exact("syncdefaultsd"), .system),
        .init(.exact("securityd"), .system),
        .init(.exact("powerd"), .system),
        .init(.exact("configd"), .system),
    ]

    /// Classify a process by name (and optionally its bundle/executable path).
    public static func categorize(name: String, bundlePathHint: String? = nil) -> ProcessCategory {
        let loweredName = name.trimmingCharacters(in: .whitespaces).lowercased()

        for rule in rules where rule.match.matches(loweredName) {
            return rule.category
        }

        // Fall back to matching the path's last component, then the whole path,
        // so e.g. "/Applications/Google Chrome.app/..." still classifies.
        if let path = bundlePathHint?.lowercased(), !path.isEmpty {
            let lastComponent = (path as NSString).lastPathComponent
            for rule in rules where rule.match.matches(lastComponent) {
                return rule.category
            }
            for rule in rules where rule.match.matches(path) {
                return rule.category
            }
        }

        if looksLikeDaemon(name.trimmingCharacters(in: .whitespaces)) {
            return .background
        }
        return .other
    }

    /// Heuristic for launchd-ish / unknown-daemon-looking names.
    /// Takes the original (un-lowercased) name so casing can inform the check.
    static func looksLikeDaemon(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let lowered = name.lowercased()
        if lowered.contains("launchd") { return true }
        if lowered.contains("xpc") { return true }
        if lowered.hasSuffix("agent") { return true }
        if lowered.hasPrefix("com.") { return true }
        // A fully-lowercase name ending in "d" is the classic macOS daemon
        // shape (notifyd, distnoted, nsurlsessiond, ...). Mixed-case app
        // names ending in "d" do not count.
        let hasNoUppercase = !name.contains(where: { $0.isUppercase })
        if hasNoUppercase, lowered.hasSuffix("d"), lowered.count > 2 { return true }
        return false
    }
}
