import XCTest
@testable import BatteryCore

/// Grouping coding-agent processes into sessions by ancestry.
///
/// The scenarios are modelled on a real tree: `rudder-native` spawning several
/// `claude` processes, each of which spawns builds of its own, alongside an
/// unrelated `claude` started by hand in a terminal.
final class AgentSessionTests: XCTestCase {

    private let baseMs: Int64 = 1_700_000_000_000

    private func sample(
        _ name: String,
        pid: Int32,
        ppid: Int32?,
        residentMB: Int64? = nil,
        cpuMsPerS: Double = 0,
        energyImpact: Double = 0,
        tick: Int64 = 0
    ) -> ProcessSample {
        ProcessSample(
            timestampMs: baseMs + tick * 30_000,
            pid: pid,
            name: name,
            energyImpact: energyImpact,
            cpuMsPerS: cpuMsPerS,
            category: Categorizer.categorize(name: name, bundlePathHint: nil),
            ppid: ppid,
            residentBytes: residentMB.map { $0 * 1024 * 1024 }
        )
    }

    // MARK: - Roster

    func testRecognizesAgentsAndOrchestrators() {
        XCTAssertTrue(AgentSessions.isAgent(name: "claude"))
        XCTAssertTrue(AgentSessions.isAgent(name: "codex"))
        XCTAssertTrue(AgentSessions.isAgent(name: "claude-code"))
        XCTAssertTrue(AgentSessions.isOrchestrator(name: "rudder-native"))
        XCTAssertFalse(AgentSessions.isAgent(name: "node"))
        XCTAssertFalse(AgentSessions.isAgent(name: "swift-frontend"))
        // A name merely starting with the same letters is not a match: the
        // prefix rule requires a separator.
        XCTAssertFalse(AgentSessions.isAgent(name: "claudius"))
        XCTAssertFalse(AgentSessions.isOrchestrator(name: "rudderless"))
    }

    func testNormalizesPathsAndCase() {
        XCTAssertTrue(AgentSessions.isOrchestrator(name: "/opt/homebrew/lib/node_modules/rudder/rudder-native"))
        XCTAssertTrue(AgentSessions.isAgent(name: "Claude"))
    }

    func testDisplayNameMapsKnownRoots() {
        XCTAssertEqual(AgentSessions.displayName(for: "rudder-native"), "Rudder")
        XCTAssertEqual(AgentSessions.displayName(for: "claude"), "Claude Code")
        // Anything unrecognized shows as itself rather than being dropped.
        XCTAssertEqual(AgentSessions.displayName(for: "some-runner"), "some-runner")
    }

    // MARK: - Grouping

    func testOrchestratorCollapsesItsAgentsIntoOneSession() {
        let samples = [
            sample("rudder-native", pid: 100, ppid: 1, residentMB: 15, cpuMsPerS: 50),
            sample("claude", pid: 101, ppid: 100, residentMB: 600, cpuMsPerS: 1000),
            sample("claude", pid: 102, ppid: 100, residentMB: 700, cpuMsPerS: 500),
            sample("claude", pid: 103, ppid: 100, residentMB: 500, cpuMsPerS: 250),
        ]

        let sessions = AgentSessions.sessions(samples: samples)

        XCTAssertEqual(sessions.count, 1)
        let session = try? XCTUnwrap(sessions.first)
        XCTAssertEqual(session?.label, "Rudder")
        XCTAssertEqual(session?.peakAgentCount, 3)
        XCTAssertEqual(session?.peakProcessCount, 4, "the orchestrator itself is a member too")
        XCTAssertEqual(session?.peakResidentBytes, 1815 * 1024 * 1024)
        XCTAssertEqual(session?.peakCPUCores ?? 0, 1.8, accuracy: 0.001)
    }

    func testDescendantsOfAgentsAreAttributedToTheSession() {
        // A compiler three levels down is a real part of what the session costs.
        let samples = [
            sample("rudder-native", pid: 100, ppid: 1, residentMB: 15),
            sample("claude", pid: 101, ppid: 100, residentMB: 600),
            sample("swift-frontend", pid: 201, ppid: 101, residentMB: 900, cpuMsPerS: 3000),
            sample("node", pid: 202, ppid: 201, residentMB: 100),
        ]

        let sessions = AgentSessions.sessions(samples: samples)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.peakProcessCount, 4)
        XCTAssertEqual(sessions.first?.peakAgentCount, 1, "only claude is an agent proper")
        XCTAssertEqual(sessions.first?.peakResidentBytes, 1615 * 1024 * 1024)
    }

    func testStandaloneAgentGetsItsOwnSession() {
        let samples = [
            sample("rudder-native", pid: 100, ppid: 1, residentMB: 15),
            sample("claude", pid: 101, ppid: 100, residentMB: 600),
            // Started by hand in a terminal, not under the orchestrator.
            sample("ghostty", pid: 300, ppid: 1, residentMB: 200),
            sample("claude", pid: 301, ppid: 300, residentMB: 800),
        ]

        let sessions = AgentSessions.sessions(samples: samples)

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.label)), ["Rudder", "Claude Code"])
        let standalone = sessions.first { $0.label == "Claude Code" }
        XCTAssertEqual(standalone?.peakResidentBytes, 800 * 1024 * 1024)
        XCTAssertEqual(
            standalone?.peakProcessCount, 1,
            "the terminal that launched it is not part of the session"
        )
    }

    func testNoAgentsMeansNoSessions() {
        let samples = [
            sample("ghostty", pid: 300, ppid: 1, residentMB: 200),
            sample("swift-frontend", pid: 301, ppid: 300, residentMB: 900),
        ]
        XCTAssertTrue(AgentSessions.sessions(samples: samples).isEmpty)
    }

    // MARK: - Degradation

    func testMissingAncestryStillYieldsPerAgentSessions() {
        // A pre-v3 database has no ppid at all. Each agent should still be seen.
        let samples = [
            sample("claude", pid: 101, ppid: nil, residentMB: 600),
            sample("claude", pid: 102, ppid: nil, residentMB: 700),
        ]

        let sessions = AgentSessions.sessions(samples: samples)

        XCTAssertEqual(sessions.count, 2, "without ancestry, each agent is its own session")
        XCTAssertEqual(sessions.map(\.peakAgentCount), [1, 1])
    }

    func testMissingResidentMemoryIsNilRatherThanZero() {
        let samples = [sample("claude", pid: 101, ppid: nil, residentMB: nil, cpuMsPerS: 500)]
        let session = AgentSessions.sessions(samples: samples).first
        XCTAssertNil(session?.peakResidentBytes, "unmeasured must not read as zero")
        XCTAssertEqual(session?.peakCPUCores ?? 0, 0.5, accuracy: 0.001)
    }

    func testCyclicParentChainTerminates() {
        // Two processes claiming each other as parent — impossible in a healthy
        // kernel, reachable through pid reuse across a stale row.
        let samples = [
            sample("claude", pid: 101, ppid: 102),
            sample("rudder-native", pid: 102, ppid: 101),
        ]
        // The assertion that matters is that this returns at all.
        XCTAssertEqual(AgentSessions.sessions(samples: samples).count, 1)
    }

    // MARK: - Rollup across ticks

    func testPeakAndMeanAcrossTicks() {
        var samples: [ProcessSample] = []
        // Tick 0: one agent. Tick 1: three. Tick 2: back to one.
        samples += [
            sample("rudder-native", pid: 100, ppid: 1, residentMB: 10, tick: 0),
            sample("claude", pid: 101, ppid: 100, residentMB: 590, tick: 0),
        ]
        samples += [
            sample("rudder-native", pid: 100, ppid: 1, residentMB: 10, tick: 1),
            sample("claude", pid: 101, ppid: 100, residentMB: 600, tick: 1),
            sample("claude", pid: 102, ppid: 100, residentMB: 700, tick: 1),
            sample("claude", pid: 103, ppid: 100, residentMB: 690, tick: 1),
        ]
        samples += [
            sample("rudder-native", pid: 100, ppid: 1, residentMB: 10, tick: 2),
            sample("claude", pid: 101, ppid: 100, residentMB: 590, tick: 2),
        ]

        let session = try? XCTUnwrap(AgentSessions.sessions(samples: samples).first)

        XCTAssertEqual(session?.peakAgentCount, 3, "the peak is the moment that matters")
        XCTAssertEqual(session?.peakResidentBytes, 2000 * 1024 * 1024)
        XCTAssertEqual(
            session?.meanResidentBytes,
            (600 + 2000 + 600) * 1024 * 1024 / 3,
            "mean is over ticks, so the quiet ticks pull it well below the peak"
        )
        XCTAssertEqual(session?.tickCount, 3)
        XCTAssertEqual(session?.duration, 60)
    }

    func testTimelineEmitsOneEntryPerTickInOrder() {
        let samples = [
            sample("claude", pid: 101, ppid: nil, tick: 2),
            sample("claude", pid: 101, ppid: nil, tick: 0),
            sample("claude", pid: 101, ppid: nil, tick: 1),
        ]
        let timeline = AgentSessions.timeline(samples: samples)
        XCTAssertEqual(timeline.map(\.timestampMs), [baseMs, baseMs + 30_000, baseMs + 60_000])
    }
}
