import XCTest
@testable import BatteryCore

/// Identifying terminal tabs from the process tree, and ranking by them.
///
/// The trees here are copied from a real machine: ghostty spawns one `login`
/// per tab, which execs a `zsh`, under which everything else runs.
final class TerminalTabTests: XCTestCase {

    private let baseMs: Int64 = 1_700_000_000_000

    private func sample(
        _ name: String,
        pid: Int32,
        ppid: Int32?,
        cores: Double = 0,
        energy: Double = 0,
        directory: String? = nil,
        residentMB: Int64 = 10
    ) -> ProcessSample {
        ProcessSample(
            timestampMs: baseMs,
            pid: pid,
            name: name,
            energyImpact: energy,
            cpuMsPerS: cores * 1000,
            category: Categorizer.categorize(name: name, bundlePathHint: nil),
            ppid: ppid,
            residentBytes: residentMB * 1024 * 1024,
            workingDirectory: directory
        )
    }

    /// ghostty → login → zsh → command, which is the real shape.
    private func tab(
        loginPid: Int32,
        shellPid: Int32,
        directory: String?,
        command: (name: String, pid: Int32, cores: Double)?
    ) -> [ProcessSample] {
        var samples = [
            sample("login", pid: loginPid, ppid: 1159),
            sample("zsh", pid: shellPid, ppid: loginPid, directory: directory),
        ]
        if let command {
            samples.append(sample(command.name, pid: command.pid, ppid: shellPid, cores: command.cores))
        }
        return samples
    }

    private var ghostty: ProcessSample {
        sample("ghostty", pid: 1159, ppid: 1, cores: 0.3)
    }

    // MARK: - Identification

    func testTabIsNamedAfterItsWorkingDirectory() {
        let samples = [ghostty] + tab(
            loginPid: 1161,
            shellPid: 1162,
            directory: "/Users/viraat/code/battery",
            command: (name: "claude", pid: 1329, cores: 2)
        )

        let tabs = TerminalTabs.tabs(inTick: samples)

        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.label, "battery", "the folder is what the terminal titles the tab")
        XCTAssertEqual(tabs.first?.detail, "claude", "and what is running in it")
        XCTAssertEqual(tabs.first?.terminalName, "ghostty")
    }

    func testEachTabIsSeparate() {
        // The whole point: "Ghostty, 40%" is useless with several tabs open.
        let samples = [ghostty]
            + tab(loginPid: 1161, shellPid: 1162, directory: "/Users/viraat/code/battery",
                  command: (name: "claude", pid: 1329, cores: 3))
            + tab(loginPid: 1862, shellPid: 1863, directory: "/Users/viraat/code/rudder",
                  command: (name: "claude", pid: 2072, cores: 1))
            + tab(loginPid: 2510, shellPid: 2512, directory: "/Users/viraat/code/mwitch",
                  command: (name: "codex", pid: 2741, cores: 0.5))

        let tabs = TerminalTabs.tabs(inTick: samples)

        XCTAssertEqual(tabs.count, 3)
        XCTAssertEqual(tabs.map(\.label), ["battery", "rudder", "mwitch"], "busiest first")
        XCTAssertEqual(tabs.first?.cpuCores ?? 0, 3, accuracy: 0.001)
    }

    func testTheShellPlumbingIsNeverTheLabel() {
        // login/zsh are how a tab is built, not what it is.
        let samples = [ghostty] + tab(
            loginPid: 1161, shellPid: 1162, directory: "/Users/viraat/code/battery",
            command: (name: "claude", pid: 1329, cores: 2)
        )
        let tabs = TerminalTabs.tabs(inTick: samples)
        XCTAssertNotEqual(tabs.first?.label, "zsh")
        XCTAssertNotEqual(tabs.first?.label, "login")
        XCTAssertNotEqual(tabs.first?.detail, "zsh")
    }

    func testDeepDescendantsBelongToTheirTab() {
        // rudder → claude → swift-frontend, all inside one tab.
        var samples = [ghostty] + tab(
            loginPid: 1161, shellPid: 1162, directory: "/Users/viraat/code/battery",
            command: (name: "rudder-native", pid: 1194, cores: 0.2)
        )
        samples.append(sample("claude", pid: 1329, ppid: 1194, cores: 2))
        samples.append(sample("swift-frontend", pid: 5000, ppid: 1329, cores: 4))

        let tabs = TerminalTabs.tabs(inTick: samples)

        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.label, "battery")
        XCTAssertEqual(tabs.first?.cpuCores ?? 0, 6.2, accuracy: 0.001, "the whole tree is the tab's cost")
        XCTAssertEqual(tabs.first?.detail, "swift-frontend", "the busiest thing in it")
    }

    func testTabAtABarePromptStillCounts() {
        let samples = [ghostty] + tab(
            loginPid: 1161, shellPid: 1162,
            directory: "/Users/viraat/code/battery", command: nil
        )
        let tabs = TerminalTabs.tabs(inTick: samples)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.label, "battery")
        XCTAssertNil(tabs.first?.detail, "nothing is running in it")
    }

    func testProcessesOutsideAnyTerminalAreNotTabs() {
        let samples = [
            ghostty,
            sample("Safari", pid: 300, ppid: 1, cores: 2),
            sample("com.apple.WebKit.WebContent", pid: 301, ppid: 300, cores: 1),
        ]
        XCTAssertTrue(TerminalTabs.tabs(inTick: samples).isEmpty)
    }

    func testNoTerminalMeansNoTabs() {
        let samples = [sample("Safari", pid: 300, ppid: 1, cores: 2)]
        XCTAssertTrue(TerminalTabs.tabs(inTick: samples).isEmpty)
    }

    func testRecognizesOtherTerminals() {
        for terminal in ["iTerm2", "Alacritty", "kitty", "WezTerm"] {
            XCTAssertTrue(TerminalTabs.isTerminal(name: terminal), terminal)
        }
        XCTAssertFalse(TerminalTabs.isTerminal(name: "Safari"))
    }

    func testDirectoryFallsBackWhenTheShellDidNotReportOne() {
        // Reading a working directory can fail; the tab should still appear.
        let samples = [ghostty] + tab(
            loginPid: 1161, shellPid: 1162, directory: nil,
            command: (name: "claude", pid: 1329, cores: 2)
        )
        let tabs = TerminalTabs.tabs(inTick: samples)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.label, "claude", "falls back to the command")
    }

    // MARK: - Ranking

    func testRankingNamesTheTabRatherThanTheTerminal() {
        let samples = [ghostty]
            + tab(loginPid: 1161, shellPid: 1162, directory: "/Users/viraat/code/battery",
                  command: (name: "claude", pid: 1329, cores: 4))
            + [sample("Safari", pid: 300, ppid: 1, cores: 1)]

        let ranking = EnergyRanking.rank(samples: samples)

        XCTAssertEqual(ranking.basis, .cpu)
        XCTAssertEqual(ranking.rows.first?.label, "battery")
        XCTAssertEqual(ranking.rows.first?.kind, .terminalTab)
        XCTAssertFalse(
            ranking.rows.contains { $0.label.lowercased() == "ghostty" },
            "the terminal is what draws the tabs, not a peer of them"
        )
    }

    func testRankingPrefersEnergyWhenItExists() {
        let samples = [ghostty]
            + tab(loginPid: 1161, shellPid: 1162, directory: "/Users/viraat/code/battery",
                  command: (name: "claude", pid: 1329, cores: 4))
            + [sample("Safari", pid: 300, ppid: 1, cores: 0.1, energy: 500)]

        let ranking = EnergyRanking.rank(samples: samples)

        XCTAssertEqual(ranking.basis, .energy)
        XCTAssertEqual(ranking.rows.first?.label, "Safari", "ranked by energy, not CPU")
    }

    func testIdleMachineRanksNothingRatherThanNoise() {
        // Every process ticking over at a thousandth of a core. Ranking that
        // produces a confident list of daemons that means nothing.
        let samples = [
            sample("distnoted", pid: 400, ppid: 1, cores: 0.001),
            sample("suggestd", pid: 401, ppid: 1, cores: 0.002),
            sample("IMDPersistenceAgent", pid: 402, ppid: 1, cores: 0.001),
        ]
        XCTAssertTrue(EnergyRanking.rank(samples: samples).isEmpty)
    }

    // MARK: - Helper processes

    func testHelperProcessesAreNamedAfterTheAppTheHumanLaunched() {
        // Copied from a real machine: Arc's renderer is a grandchild whose own
        // name says neither which app nor which page.
        let samples = [
            sample("Arc", pid: 791, ppid: 1, cores: 0.2),
            sample("Browser Helper (Renderer)", pid: 211, ppid: 791, cores: 3),
            sample("Browser Helper", pid: 987, ppid: 791, cores: 1),
        ]

        let ranking = EnergyRanking.rank(samples: samples)

        XCTAssertEqual(ranking.rows.count, 1, "one app, not three anonymous helpers")
        XCTAssertEqual(ranking.rows.first?.label, "Arc")
        XCTAssertEqual(ranking.rows.first?.sharePct ?? 0, 100, accuracy: 0.5)
    }

    func testDaemonsStartedByLaunchdAreTheirOwnRoot() {
        let samples = [sample("mds_stores", pid: 400, ppid: 1, cores: 3)]
        let ranking = EnergyRanking.rank(samples: samples)
        XCTAssertEqual(ranking.rows.first?.label, "mds_stores")
    }

    func testABrokenChainFallsBackToTheProcessItself() {
        // The parent was not sampled, so there is nothing better to say.
        let samples = [sample("Browser Helper (Renderer)", pid: 211, ppid: 791, cores: 3)]
        let ranking = EnergyRanking.rank(samples: samples)
        XCTAssertEqual(ranking.rows.first?.label, "Browser Helper (Renderer)")
    }

    func testWorkStartedInATabIsNotClaimedByTheTerminalApp() {
        // The walk stops at a terminal: a tab's work belongs to the tab, and
        // must never roll up into "ghostty".
        let samples = [ghostty]
            + tab(loginPid: 1161, shellPid: 1162, directory: "/Users/viraat/code/battery",
                  command: (name: "claude", pid: 1329, cores: 4))

        let ranking = EnergyRanking.rank(samples: samples)
        XCTAssertEqual(ranking.rows.first?.kind, .terminalTab)
        XCTAssertEqual(ranking.rows.first?.label, "battery")
    }

    func testSharesAreRelativeToWhatIsListed() {
        let samples = [ghostty]
            + tab(loginPid: 1161, shellPid: 1162, directory: "/Users/viraat/code/battery",
                  command: (name: "claude", pid: 1329, cores: 3))
            + [sample("Safari", pid: 300, ppid: 1, cores: 1)]

        let ranking = EnergyRanking.rank(samples: samples)
        let total = ranking.rows.compactMap(\.sharePct).reduce(0, +)
        XCTAssertEqual(total, 100, accuracy: 0.5)
        XCTAssertEqual(ranking.rows.first?.sharePct ?? 0, 75, accuracy: 0.5)
    }
}
