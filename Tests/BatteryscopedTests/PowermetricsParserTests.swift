import BatteryCore
import XCTest

@testable import batteryscoped

final class PowermetricsParserTests: XCTestCase {

    private let timestamp: Int64 = 1_700_000_000_000

    private func parse(_ xml: String) throws -> [ProcessSample] {
        try PowermetricsParser.parse(PowermetricsFixtures.data(xml), timestampMs: timestamp)
    }

    // MARK: - Happy path

    func testWellFormedPlistParsesEveryTask() throws {
        let samples = try parse(PowermetricsFixtures.wellFormed)
        XCTAssertEqual(samples.count, 4)

        let chrome = try XCTUnwrap(samples.first)
        XCTAssertEqual(chrome.name, "Google Chrome")
        XCTAssertEqual(chrome.pid, 451)
        XCTAssertEqual(chrome.energyImpact, 132.5, accuracy: 0.0001)
        XCTAssertEqual(chrome.cpuMsPerS, 84.25, accuracy: 0.0001)
        XCTAssertEqual(chrome.bundlePathHint, "/Applications/Google Chrome.app")
        XCTAssertEqual(chrome.category, .browser)
        XCTAssertEqual(chrome.timestampMs, timestamp)
    }

    func testCategoriesComeFromTheCategorizer() throws {
        let samples = try parse(PowermetricsFixtures.wellFormed)
        let categories = Dictionary(
            uniqueKeysWithValues: samples.map { ($0.name, $0.category) }
        )
        XCTAssertEqual(categories["Google Chrome"], .browser)
        XCTAssertEqual(categories["Ghostty"], .terminal)
        XCTAssertEqual(categories["WindowServer"], .system)
        XCTAssertEqual(categories["notifyd"], .background)
    }

    func testAllSamplesShareTheInjectedTimestamp() throws {
        let samples = try parse(PowermetricsFixtures.wellFormed)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0.timestampMs == self.timestamp })
    }

    func testMissingBundlePathBecomesNil() throws {
        let samples = try parse(PowermetricsFixtures.wellFormed)
        let ghostty = try XCTUnwrap(samples.first { $0.name == "Ghostty" })
        XCTAssertNil(ghostty.bundlePathHint)
    }

    // MARK: - Key aliases

    func testAlternateKeySpellingsAreAccepted() throws {
        let samples = try parse(PowermetricsFixtures.alternateKeys)
        XCTAssertEqual(samples.count, 1)
        let spotify = try XCTUnwrap(samples.first)
        XCTAssertEqual(spotify.name, "Spotify")
        XCTAssertEqual(spotify.energyImpact, 55.5, accuracy: 0.0001)
        XCTAssertEqual(spotify.cpuMsPerS, 9.75, accuracy: 0.0001)
        XCTAssertEqual(spotify.category, .media)
    }

    func testCoalitionRootKeyIsAccepted() throws {
        let samples = try parse(PowermetricsFixtures.coalitions)
        XCTAssertEqual(samples.map(\.name), ["Safari"])
        XCTAssertEqual(samples.first?.category, .browser)
    }

    func testNumbersEncodedAsStringsAreParsed() throws {
        let samples = try parse(PowermetricsFixtures.stringyNumbers)
        let node = try XCTUnwrap(samples.first)
        XCTAssertEqual(node.name, "node")
        XCTAssertEqual(node.energyImpact, 77.25, accuracy: 0.0001)
        // Unparseable counter defaults to zero rather than dropping the task.
        XCTAssertEqual(node.cpuMsPerS, 0)
        // A pid outside Int32 falls back to the unknown sentinel.
        XCTAssertEqual(node.pid, -1)
    }

    // MARK: - Defensive behaviour

    func testMalformedEntriesAreSkippedNotFatal() throws {
        let samples = try parse(PowermetricsFixtures.malformedEntries)
        // Only the named tasks survive: Slack and mdworker_shared.
        XCTAssertEqual(samples.map(\.name).sorted(), ["Slack", "mdworker_shared"])
    }

    func testMissingCountersDefaultToZero() throws {
        let samples = try parse(PowermetricsFixtures.malformedEntries)
        let mdworker = try XCTUnwrap(samples.first { $0.name == "mdworker_shared" })
        XCTAssertEqual(mdworker.energyImpact, 0)
        XCTAssertEqual(mdworker.cpuMsPerS, 0)
        XCTAssertEqual(mdworker.pid, -1)
        XCTAssertEqual(mdworker.category, .system)
    }

    func testEmptyTaskArrayYieldsNoSamples() throws {
        XCTAssertTrue(try parse(PowermetricsFixtures.emptyTasks).isEmpty)
    }

    func testMissingTasksKeyYieldsNoSamples() throws {
        XCTAssertTrue(try parse(PowermetricsFixtures.noTasksKey).isEmpty)
    }

    func testArrayRootThrowsUnexpectedRoot() {
        XCTAssertThrowsError(try parse(PowermetricsFixtures.arrayRoot)) { error in
            guard case PowermetricsParser.ParseError.unexpectedRoot = error else {
                return XCTFail("expected .unexpectedRoot, got \(error)")
            }
        }
    }

    func testEmptyDataThrowsRatherThanCrashing() {
        XCTAssertThrowsError(try PowermetricsParser.parse(Data(), timestampMs: timestamp)) { error in
            guard case PowermetricsParser.ParseError.notAPropertyList = error else {
                return XCTFail("expected .notAPropertyList, got \(error)")
            }
        }
    }

    func testGarbageBytesThrowRatherThanCrashing() {
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0xFF, 0xFE])
        XCTAssertThrowsError(try PowermetricsParser.parse(garbage, timestampMs: timestamp))
    }

    func testTruncatedPlistThrowsRatherThanCrashing() {
        let truncated = String(PowermetricsFixtures.wellFormed.prefix(200))
        XCTAssertThrowsError(try parse(truncated))
    }

    func testHumanReadableTextIsNotAPropertyList() {
        let text = Data("powermetrics must be invoked as the superuser\n".utf8)
        XCTAssertThrowsError(try PowermetricsParser.parse(text, timestampMs: timestamp))
    }

    func testFreeFunctionMatchesNamespacedParse() throws {
        let data = PowermetricsFixtures.data(PowermetricsFixtures.wellFormed)
        let viaFunction = try parsePowermetricsPlist(data, timestampMs: timestamp)
        let viaEnum = try PowermetricsParser.parse(data, timestampMs: timestamp)
        XCTAssertEqual(viaFunction, viaEnum)
    }

    func testBinaryPlistIsAlsoAccepted() throws {
        // powermetrics emits XML, but PropertyListSerialization is format
        // agnostic and the parser must not assume otherwise.
        let source: [String: Any] = [
            "tasks": [["name": "Terminal", "pid": 9, "energy_impact": 1.5, "cputime_ms_per_s": 2.5]],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: source,
            format: .binary,
            options: 0
        )
        let samples = try PowermetricsParser.parse(data, timestampMs: timestamp)
        XCTAssertEqual(samples.map(\.name), ["Terminal"])
        XCTAssertEqual(samples.first?.category, .terminal)
    }
}
