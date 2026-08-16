import XCTest
@testable import BatteryCore

/// The two insight rules that speak about stalls and agent sessions.
///
/// The point of these rules is that they say something specific and defensible;
/// the assertions are mostly on the wording, because vague wording is the
/// failure mode that matters here.
final class StallInsightTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let gigabyte: Int64 = 1024 * 1024 * 1024

    private var window: TimeWindow {
        TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))
    }

    private func context(
        stalls: [StallEpisode] = [],
        agentSessions: [AgentSession] = [],
        machine: MachineProfile? = MachineProfile(totalMemoryBytes: 24 * 1024 * 1024 * 1024, cpuCount: 14)
    ) -> InsightContext {
        let series = DrainAnalyzer.analyze(
            samples: Fixtures.steadyDrain(),
            window: window,
            bucket: Bucket.auto(for: window),
            options: Fixtures.options
        )
        return InsightContext(
            window: window,
            series: series,
            processes: [],
            categories: [],
            health: nil,
            timeZone: utc,
            thresholds: InsightThresholds(),
            agentSessions: agentSessions,
            stalls: stalls,
            machine: machine
        )
    }

    /// `id` defaults to the label, but real contributors carry the session id,
    /// which is built from the *root process name* rather than the display
    /// label — see `AgentSession.id`.
    private func contributor(
        label: String,
        agents: Int,
        residentGB: Double,
        memoryShare: Double?,
        cpuShare: Double? = 0.1,
        id: String? = nil
    ) -> StallContributor {
        StallContributor(
            id: id ?? "\(label)#100",
            label: label,
            peakAgentCount: agents,
            peakProcessCount: agents + 1,
            peakResidentBytes: Int64(residentGB * Double(gigabyte)),
            peakCPUCores: 4,
            memoryShareOfMachine: memoryShare,
            cpuShareOfMachine: cpuShare
        )
    }

    private func episode(
        startOffset: TimeInterval = 1800,
        duration: TimeInterval = 240,
        severity: PressureLevel = .critical,
        causes: [StallCause] = [.memoryPressure, .swapThrash],
        swapGrowthGB: Double = 0,
        contributors: [StallContributor] = [],
        heavyProcesses: [HeavyProcess] = [],
        longestStarvedSeconds: TimeInterval = 0
    ) -> StallEpisode {
        StallEpisode(
            start: Fixtures.at(startOffset),
            end: Fixtures.at(startOffset + duration),
            severity: severity,
            causes: causes,
            peakLoadPerCore: 3.2,
            peakMemoryUsedFraction: 0.97,
            swapGrowthBytes: Int64(swapGrowthGB * Double(gigabyte)),
            peakSwapUsedBytes: 4 * gigabyte,
            peakPageInsPerSecond: 5000,
            contributors: contributors,
            sampleCount: 9,
            longestStarvedSeconds: longestStarvedSeconds,
            heavyProcesses: heavyProcesses
        )
    }

    private func insight(_ id: String, in insights: [Insight]) -> Insight? {
        insights.first { $0.id == id }
    }

    private func session(
        label root: String,
        agents: Int,
        residentGB: Double,
        cores: Double = 6
    ) -> AgentSession {
        AgentSession(
            footprint: AgentSessions.Footprint(
                rootPid: 100,
                rootName: root,
                processCount: agents + 1,
                agentCount: agents,
                residentBytes: Int64(residentGB * Double(gigabyte)),
                cpuCores: cores,
                energyImpact: 100
            ),
            at: Fixtures.at(1800)
        )
    }

    // MARK: - Stall rule

    func testStallRuleNamesTheSessionThatWasHoldingMemory() throws {
        let insights = InsightEngine.insights(context(
            stalls: [episode(
                swapGrowthGB: 3,
                contributors: [contributor(label: "Rudder", agents: 6, residentGB: 11, memoryShare: 0.46)]
            )],
        ))
        let stall = try XCTUnwrap(insight("stall", in: insights))

        XCTAssertEqual(stall.severity, .critical)
        XCTAssertEqual(stall.title, "Your Mac stalled for 4m")
        XCTAssertTrue(stall.detail.contains("Rudder was running 6 agents"), stall.detail)
        XCTAssertTrue(stall.detail.contains("11.0 GB"), stall.detail)
        XCTAssertTrue(stall.detail.contains("46%"), stall.detail)
        XCTAssertTrue(stall.detail.contains("memory pressure"), stall.detail)
        XCTAssertTrue(stall.detail.contains("Swap grew 3.0 GB"), stall.detail)
    }

    func testStallRuleDoesNotBlameASmallSession() throws {
        // A session holding 4% of memory during someone else's stall is not the
        // cause of it, and must not be named as one.
        let insights = InsightEngine.insights(context(
            stalls: [episode(
                contributors: [contributor(
                    label: "Rudder",
                    agents: 1,
                    residentGB: 1,
                    memoryShare: 0.04,
                    cpuShare: 0.05
                )],
            )]
        ))
        let stall = try XCTUnwrap(insight("stall", in: insights))
        XCTAssertFalse(stall.detail.contains("Rudder"), stall.detail)
    }

    func testStallRuleSaysSoWhenNothingHeavyWasRecorded() throws {
        let insights = InsightEngine.insights(context(stalls: [episode()]))
        let stall = try XCTUnwrap(insight("stall", in: insights))
        XCTAssertTrue(stall.detail.contains("Nothing heavy was recorded"), stall.detail)
    }

    func testStallRuleNamesAHeavyProcessWhenNoAgentIsResponsible() throws {
        // The common case for a machine that hangs without any agent running:
        // Spotlight, Time Machine, a browser. Naming it is the entire point.
        let insights = InsightEngine.insights(context(stalls: [episode(
            heavyProcesses: [
                HeavyProcess(
                    pid: 900,
                    name: "mds_stores",
                    category: .system,
                    peakResidentBytes: 9 * gigabyte,
                    peakCPUCores: 6.2,
                    peakDiskBytesPerS: 300_000_000,
                    memoryShareOfMachine: 0.375,
                    isAgentMember: false
                ),
            ]
        )]))
        let stall = try XCTUnwrap(insight("stall", in: insights))
        XCTAssertTrue(stall.detail.contains("mds_stores"), stall.detail)
        XCTAssertTrue(stall.detail.contains("9.0 GB"), stall.detail)
        XCTAssertTrue(stall.detail.contains("6.2 cores"), stall.detail)
    }

    func testStallRuleReportsWhenTheSamplerItselfCouldNotRun() throws {
        let insights = InsightEngine.insights(context(
            stalls: [episode(longestStarvedSeconds: 120)]
        ))
        let stall = try XCTUnwrap(insight("stall", in: insights))
        XCTAssertTrue(stall.detail.contains("could not run for 2m"), stall.detail)
        XCTAssertTrue(stall.detail.contains("genuinely unresponsive"), stall.detail)
    }

    func testStallRulePrefersASessionOverALoneProcess() throws {
        let insights = InsightEngine.insights(context(stalls: [episode(
            contributors: [contributor(label: "Rudder", agents: 6, residentGB: 11, memoryShare: 0.46)],
            heavyProcesses: [
                HeavyProcess(
                    pid: 900,
                    name: "mds_stores",
                    category: .system,
                    peakResidentBytes: 2 * gigabyte,
                    peakCPUCores: 1,
                    peakDiskBytesPerS: nil,
                    memoryShareOfMachine: 0.08,
                    isAgentMember: false
                ),
            ]
        )]))
        let stall = try XCTUnwrap(insight("stall", in: insights))
        XCTAssertTrue(stall.detail.contains("Rudder"), stall.detail)
        XCTAssertFalse(stall.detail.contains("mds_stores"), stall.detail)
    }

    func testStallRuleSummarizesRepeatedStalls() throws {
        let insights = InsightEngine.insights(context(stalls: [
            episode(startOffset: 600, duration: 120),
            episode(startOffset: 1800, duration: 240),
            episode(startOffset: 3600, duration: 60),
        ]))
        let stall = try XCTUnwrap(insight("stall", in: insights))
        XCTAssertEqual(stall.title, "3 stalls, 7m total")
    }

    func testSeriousStallIsAWarningNotCritical() throws {
        let insights = InsightEngine.insights(context(
            stalls: [episode(severity: .serious, causes: [.cpuSaturation])]
        ))
        XCTAssertEqual(try XCTUnwrap(insight("stall", in: insights)).severity, .warning)
    }

    func testNoStallsMeansNoStallInsight() {
        XCTAssertNil(insight("stall", in: InsightEngine.insights(context())))
    }

    // MARK: - Agent footprint rule

    func testFootprintRuleWarnsBeforeTheMachineStalls() throws {
        let insights = InsightEngine.insights(context(
            agentSessions: [session(label: "rudder-native", agents: 7, residentGB: 15)]
        ))
        let footprint = try XCTUnwrap(insight("agent-footprint", in: insights))

        XCTAssertEqual(footprint.severity, .warning)
        XCTAssertTrue(footprint.title.contains("Rudder"), footprint.title)
        XCTAssertTrue(footprint.detail.contains("7 agents"), footprint.detail)
        XCTAssertTrue(footprint.detail.contains("15.0 GB"), footprint.detail)
        XCTAssertTrue(footprint.detail.contains("of 14"), footprint.detail)
    }

    func testFootprintRuleStaysQuietForModestSessions() {
        let insights = InsightEngine.insights(context(
            agentSessions: [session(label: "rudder-native", agents: 2, residentGB: 2)]
        ))
        XCTAssertNil(insight("agent-footprint", in: insights))
    }

    func testFootprintRuleDoesNotRepeatWhatTheStallRuleAlreadySaid() {
        let heavy = session(label: "rudder-native", agents: 7, residentGB: 15)
        let culprit = contributor(
            label: "Rudder",
            agents: 7,
            residentGB: 15,
            memoryShare: 0.62,
            id: heavy.id
        )
        // Same session id, so the stall insight has already named it.
        XCTAssertEqual(culprit.id, heavy.id)

        let insights = InsightEngine.insights(context(
            stalls: [episode(contributors: [culprit])],
            agentSessions: [heavy]
        ))
        XCTAssertNotNil(insight("stall", in: insights))
        XCTAssertNil(insight("agent-footprint", in: insights))
    }

    func testFootprintRuleNeedsToKnowTheMachine() {
        // Without a pressure sample there is no memory total, so a share cannot
        // be computed and the rule must say nothing rather than guess.
        let insights = InsightEngine.insights(context(
            agentSessions: [session(label: "rudder-native", agents: 7, residentGB: 15)],
            machine: nil
        ))
        XCTAssertNil(insight("agent-footprint", in: insights))
    }
}
