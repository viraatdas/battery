import XCTest
@testable import BatteryCore

final class CategorizerTests: XCTestCase {

    private func assertCategory(
        _ name: String,
        _ expected: ProcessCategory,
        path: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            Categorizer.categorize(name: name, bundlePathHint: path),
            expected,
            "for process \"\(name)\"",
            file: file,
            line: line
        )
    }

    func testBrowsers() {
        assertCategory("Google Chrome", .browser)
        assertCategory("Google Chrome Helper (Renderer)", .browser)
        assertCategory("Google Chrome Helper (GPU)", .browser)
        assertCategory("Safari", .browser)
        assertCategory("com.apple.WebKit.WebContent", .browser)
        assertCategory("com.apple.WebKit.GPU", .browser)
        assertCategory("Arc", .browser)
        assertCategory("Arc Helper (Renderer)", .browser)
        assertCategory("firefox", .browser)
        assertCategory("Brave Browser", .browser)
        assertCategory("Dia", .browser)
    }

    func testTerminals() {
        assertCategory("Terminal", .terminal)
        assertCategory("iTerm2", .terminal)
        assertCategory("Ghostty", .terminal)
        assertCategory("Alacritty", .terminal)
        assertCategory("kitty", .terminal)
        assertCategory("WezTerm", .terminal)
        assertCategory("tmux", .terminal)
        assertCategory("zsh", .terminal)
        assertCategory("-zsh", .terminal)
        assertCategory("bash", .terminal)
    }

    func testDevtools() {
        assertCategory("node", .devtools)
        assertCategory("bun", .devtools)
        assertCategory("deno", .devtools)
        assertCategory("python3.12", .devtools)
        assertCategory("ruby", .devtools)
        assertCategory("java", .devtools)
        assertCategory("docker", .devtools)
        assertCategory("dockerd", .devtools)
        assertCategory("com.docker.backend", .devtools)
        assertCategory("Xcode", .devtools)
        assertCategory("xcodebuild", .devtools)
        assertCategory("swift-frontend", .devtools)
        assertCategory("clang", .devtools)
        assertCategory("cargo", .devtools)
        assertCategory("rustc", .devtools)
        assertCategory("go", .devtools)
        assertCategory("git", .devtools)
        assertCategory("claude", .devtools)
        assertCategory("codex", .devtools)
        assertCategory("ollama", .devtools)
    }

    func testMedia() {
        assertCategory("Spotify", .media)
        assertCategory("Spotify Helper", .media)
        assertCategory("Music", .media)
        assertCategory("coreaudiod", .media)
        assertCategory("AirPlayXPCHelper", .media)
    }

    func testCommunication() {
        assertCategory("Slack", .communication)
        assertCategory("Slack Helper (Renderer)", .communication)
        assertCategory("zoom.us", .communication)
        assertCategory("Discord", .communication)
        assertCategory("Messages", .communication)
        assertCategory("Mail", .communication)
    }

    func testSystem() {
        assertCategory("WindowServer", .system)
        assertCategory("kernel_task", .system)
        assertCategory("mds", .system)
        assertCategory("mds_stores", .system)
        assertCategory("mdworker_shared", .system)
        assertCategory("bluetoothd", .system)
        assertCategory("corespotlightd", .system)
        assertCategory("backupd", .system)
        assertCategory("photoanalysisd", .system)
        assertCategory("cloudd", .system)
        assertCategory("bird", .system)
        assertCategory("syncdefaultsd", .system)
    }

    func testBackgroundDaemonHeuristic() {
        assertCategory("launchd", .background)
        assertCategory("notifyd", .background)
        assertCategory("distnoted", .background)
        assertCategory("nsurlsessiond", .background)
        assertCategory("com.apple.quicklook.ThumbnailsAgent", .background)
        assertCategory("SafariNotificationAgent", .background)
        assertCategory("SomeXPCService", .background)
    }

    func testOther() {
        assertCategory("Preview", .other)
        assertCategory("Notes", .other)
        assertCategory("Figma", .other)
        assertCategory("", .other)
        // Mixed-case names ending in "d" are not daemon-shaped.
        assertCategory("Blackmagicd", .other)
    }

    func testShortExactRulesDoNotSwallowLongerNames() {
        // "go" / "arc" / "git" must stay exact matches.
        assertCategory("Google Drive", .other)
        assertCategory("Archive Utility", .other)
        assertCategory("GitHub Desktop", .other)
    }

    func testBundlePathHintFallback() {
        assertCategory(
            "Renderer",
            .browser,
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper"
        )
        assertCategory("weird-name", .terminal, path: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
    }

    func testCaseInsensitivity() {
        assertCategory("GOOGLE CHROME", .browser)
        assertCategory("safari", .browser)
        assertCategory("SLACK", .communication)
    }
}
