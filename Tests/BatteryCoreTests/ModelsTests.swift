import XCTest
@testable import BatteryCore

final class ModelsTests: XCTestCase {

    func testBatterySampleCodableRoundTrip() throws {
        let sample = BatterySample(
            timestampMs: 1_700_000_000_000,
            percent: 66.0,
            isCharging: true,
            externalPower: true,
            wattsDrawn: 30.1,
            voltageMv: 12_900,
            amperageMa: 2_300,
            cycleCount: 100,
            maxCapacityPct: 95.0,
            temperatureC: nil
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(BatterySample.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func testProcessSampleCodableRoundTrip() throws {
        let sample = ProcessSample(
            timestampMs: 1_700_000_000_000,
            pid: 42,
            name: "node",
            bundlePathHint: "/usr/local/bin/node",
            energyImpact: 12.5,
            cpuMsPerS: 88.0,
            category: .devtools
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ProcessSample.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func testProcessCategoryRawValuesAreStable() {
        // These raw values are persisted in the DB; changing them is a schema migration.
        XCTAssertEqual(ProcessCategory.browser.rawValue, "browser")
        XCTAssertEqual(ProcessCategory.terminal.rawValue, "terminal")
        XCTAssertEqual(ProcessCategory.devtools.rawValue, "devtools")
        XCTAssertEqual(ProcessCategory.media.rawValue, "media")
        XCTAssertEqual(ProcessCategory.communication.rawValue, "communication")
        XCTAssertEqual(ProcessCategory.system.rawValue, "system")
        XCTAssertEqual(ProcessCategory.background.rawValue, "background")
        XCTAssertEqual(ProcessCategory.other.rawValue, "other")
        XCTAssertEqual(ProcessCategory.allCases.count, 8)
    }
}
