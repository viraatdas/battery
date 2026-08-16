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
    ///
    /// --- `.system` vs `.background` --------------------------------------
    /// This line is the whole point of the "lots of background processes"
    /// question, so it needs to mean something rather than being wherever a
    /// name happened to land. `.system` is the OS doing something the user
    /// can see or directly triggered: window compositing (WindowServer), the
    /// Dock, Finder, Spotlight's search UI and its indexing workers
    /// (mds/mdworker/mdbulkimport/mdwrite/SearchIndexer — indexing your
    /// files is invisible CPU work, but it is work the OS is doing *for* a
    /// visible feature you use), Notification Center, Control Center, the
    /// login/lock screen, and features a person explicitly turned on (VPN,
    /// Sidecar, Universal Control, Quick Look, Siri). `.background` is
    /// everything else the OS (or a third-party app) runs invisibly to
    /// support those surfaces or other subsystems: sync/analytics/telemetry
    /// daemons, XPC helpers, extension hosts, settings-pane controllers,
    /// crash/update helpers, and the like — nobody asked for these to run
    /// right now, they just do. When a name is ambiguous, ask "would a user
    /// recognize this as something they did," not "is this an Apple binary."
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
        // Arc names its own helper processes generically ("Browser Helper",
        // "Browser Helper (Renderer)") — indistinguishable from any other
        // browser by name alone. Only the bundle path gives it away, so this
        // rule is checked against bundlePathHint too (see categorize below).
        .init(.contains("arc.app"), .browser),
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
        .init(.prefix("node_"), .devtools),
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
        .init(.prefix("claude-"), .devtools),
        .init(.exact("codex"), .devtools),
        .init(.prefix("codex-"), .devtools),
        .init(.exact("ollama"), .devtools),
        .init(.exact("npm"), .devtools),
        .init(.exact("pnpm"), .devtools),
        .init(.exact("yarn"), .devtools),
        .init(.exact("make"), .devtools),
        .init(.exact("cmake"), .devtools),
        .init(.exact("ld"), .devtools),
        .init(.exact("sourcekit-lsp"), .devtools),
        .init(.exact("sourcekitservice"), .devtools),
        // Xcode's CoreSimulator family all share a "Sim"/"CoreSimulator"
        // naming convention (Simulator, simctl, SimAudioProcessorService,
        // SimLaunchHost, SimMetalHost, SimRenderServer, ...). Verified
        // against the real process list that nothing else starts with
        // "sim" before taking this prefix.
        .init(.prefix("sim"), .devtools),
        .init(.contains("coresimulator"), .devtools),
        .init(.exact("coredeviceservice"), .devtools),
        // "fly" is Fly.io's `flyctl` binary — a specific, single-owner
        // product name, not a shared OS utility. "spindump" is a hang/perf
        // diagnostic tool with no other plausible owner. Deliberately NOT
        // doing the same for "log", "ps", "sleep", "sort", or "caffeinate":
        // those are generic Unix utilities any process can invoke (Spotify
        // or Zoom calling `caffeinate` to hold the display awake would then
        // misreport as devtools burning battery), so they're left to fall
        // through to `.other` rather than guessing an owner.
        .init(.exact("fly"), .devtools),
        .init(.exact("spindump"), .devtools),
        .init(.prefix("raycast"), .devtools),
        .init(.prefix("rudder"), .devtools),

        // Media & audio
        .init(.prefix("spotify"), .media),
        .init(.exact("music"), .media),
        .init(.exact("coreaudiod"), .media),
        .init(.contains("airplay"), .media),
        .init(.prefix("quicktime"), .media),
        .init(.exact("vlc"), .media),
        .init(.contains("core audio driver"), .media),

        // Communication
        .init(.prefix("slack"), .communication),
        .init(.prefix("zoom"), .communication),
        .init(.prefix("discord"), .communication),
        .init(.exact("messages"), .communication),
        .init(.exact("mail"), .communication),
        .init(.exact("facetime"), .communication),
        .init(.prefix("beeper"), .communication),
        // Granola (meeting notes) and Parsec (remote desktop) both center on
        // live conversation/screen-sharing, closer to Zoom than any other
        // bucket.
        .init(.prefix("granola"), .communication),
        .init(.prefix("parsec"), .communication),

        // Core OS services — visible surfaces; see the .system/.background
        // note above the table.
        .init(.exact("windowserver"), .system),
        .init(.exact("kernel_task"), .system),
        .init(.prefix("mds"), .system),
        .init(.prefix("mdworker"), .system),
        .init(.exact("mdbulkimport"), .system),
        .init(.exact("mdwrite"), .system),
        .init(.prefix("spotlightknowledged"), .system),
        .init(.exact("searchindexer"), .system),
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
        .init(.exact("dock"), .system),
        .init(.prefix("dockhelper"), .system),
        .init(.exact("finder"), .system),
        .init(.exact("spotlight"), .system),
        .init(.exact("controlcenter"), .system),
        .init(.exact("notificationcenter"), .system),
        .init(.exact("systemuiserver"), .system),
        .init(.exact("windowmanager"), .system),
        .init(.exact("posterboard"), .system),
        .init(.exact("wallpaperagent"), .system),
        .init(.exact("loginwindow"), .system),
        .init(.exact("springboard"), .system),
        .init(.exact("uikitsystem"), .system),
        .init(.exact("system settings"), .system),
        .init(.exact("keychain circle notification"), .system),
        .init(.exact("quicklookuiservice"), .system),
        .init(.exact("sidecarrelay"), .system),
        .init(.exact("universalcontrol"), .system),
        .init(.exact("vpn"), .system),
        .init(.exact("siri"), .system),

        // --- Generalized background rules ---------------------------------
        // Apple (and third-party) support processes overwhelmingly announce
        // their own shape through a suffix (Service/Provider/Subscriber/
        // Extension/...) or a well-known substring (crashpad, uarp, xpc).
        // Matching those beats hand-naming hundreds of individual daemons,
        // and it generalizes to daemons that aren't in any snapshot we've
        // looked at. This block is deliberately last among the rule-table
        // entries (but still before the structural suffix + daemon-shape
        // fallbacks below) so a known app's helper — Slack Helper, Beeper
        // Helper, Arc's "Browser Helper" via path hint — is still attributed
        // to its real category first.
        .init(.contains("crashpad"), .background),
        .init(.contains("native-host"), .background),
        .init(.contains("uarp"), .background),
        .init(.contains("speechrecognition"), .background),
        .init(.contains("threadcommissioner"), .background),
        .init(.contains("widgetrenderer"), .background),
        .init(.prefix("backgroundassets"), .background),
        .init(.prefix("assetcache"), .background),
        .init(.exact("mdnsresponder"), .background),
        .init(.exact("commcenter"), .background),
        .init(.exact("commerce"), .background),
        .init(.exact("coreautha"), .background),
        .init(.exact("findmymacd"), .background),
        .init(.exact("gsscred"), .background),
        .init(.exact("mtlassetupgraderd"), .background),
        .init(.exact("mwitch"), .background),
        .init(.exact("pbs"), .background),
        .init(.exact("socketfilterfw"), .background),
        .init(.exact("stextractionservice.privileged"), .background),
        .init(.exact("symptomsd-diag"), .background),
        .init(.exact("systemstats"), .background),
        .init(.exact("uvcassistant"), .background),
        .init(.exact("viewbridgeauxiliary"), .background),
        .init(.exact("wirelessradiomanagerd"), .background),
        .init(.exact("writeconfig"), .background),
        .init(.exact("login"), .background),
        .init(.exact("loginitems"), .background),
        .init(.exact("reportcrash"), .background),
    ]

    /// Suffixes that mark a process as an invisible support process even
    /// though it doesn't match any named rule above or the daemon-shape
    /// heuristic below (mixed-case names ending in "Service", "Extension",
    /// etc. don't look daemon-shaped by the lowercase-and-ends-in-"d" rule,
    /// but the suffix itself is just as reliable a signal). Checked after
    /// the rule table and the bundle-path fallback, so any specifically
    /// named app or Arc-style path resolution still wins first.
    static let backgroundSuffixes: [String] = [
        "extension", "widget", "poster", "provider", "subscriber", "service",
        "services", "registrar", "daemon", "controller", "management",
        "orchestrator", "enablement", "synthesizer", "bridge", "ingestor",
        "server", "manager", "proxy", "worker", "helper", "ausp", "settings",
        "driver",
    ]

    /// Classify a process by name (and optionally its bundle/executable path).
    ///
    /// Order matters: the named rule table is checked against the process
    /// name, then (still using the same rule table, so a generic name like
    /// Arc's "Browser Helper" can still resolve) against the bundle path
    /// hint, and only *then* do the generic structural fallbacks apply. That
    /// ordering is what lets a path hint override an otherwise-unresolvable
    /// name instead of the background-suffix/daemon-shape heuristics
    /// grabbing it first.
    public static func categorize(name: String, bundlePathHint: String? = nil) -> ProcessCategory {
        var loweredName = name.trimmingCharacters(in: .whitespaces).lowercased()
        // powermetrics reports some processes as "(name)" when it couldn't
        // resolve a full path (e.g. "(clang)", "(ld)"); match on the inner
        // name so these aren't stranded in .other.
        if loweredName.hasPrefix("("), loweredName.hasSuffix(")"), loweredName.count > 2 {
            loweredName = String(loweredName.dropFirst().dropLast())
        }

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

        for suffix in backgroundSuffixes where loweredName.hasSuffix(suffix) {
            return .background
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
        // names ending in "d" do not count (e.g. "Blackmagicd" is a real
        // app, not a daemon).
        let hasNoUppercase = !name.contains(where: { $0.isUppercase })
        if hasNoUppercase {
            // Some daemons ship "_system" / "_sim" twins of an already-
            // daemon-shaped name (securityd -> securityd_system,
            // configd -> configd_sim). Strip the variant suffix before
            // checking daemon shape so the twin is recognized too.
            var base = lowered
            for variant in ["_system", "_sim"] where base.hasSuffix(variant) {
                base = String(base.dropLast(variant.count))
            }
            if base.hasSuffix("d"), base.count > 2 { return true }
        }
        return false
    }
}
