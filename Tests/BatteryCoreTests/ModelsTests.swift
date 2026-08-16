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

    // MARK: - preciseCharge

    private func sample(rawCurrentMah: Double?, rawMaxMah: Double?) -> BatterySample {
        BatterySample(
            timestampMs: 0,
            percent: 50,
            isCharging: false,
            externalPower: false,
            wattsDrawn: -5,
            voltageMv: 12_000,
            amperageMa: -400,
            cycleCount: 10,
            maxCapacityPct: 95,
            rawCurrentMah: rawCurrentMah,
            rawMaxMah: rawMaxMah
        )
    }

    func testPreciseChargeIsTheRawMahRatio() throws {
        let value = try XCTUnwrap(sample(rawCurrentMah: 4000, rawMaxMah: 8033).preciseCharge)
        XCTAssertEqual(value, 4000.0 / 8033.0 * 100, accuracy: 0.0001)
    }

    func testPreciseChargeIsNilWhenEitherRawValueIsMissing() {
        XCTAssertNil(sample(rawCurrentMah: nil, rawMaxMah: 8033).preciseCharge)
        XCTAssertNil(sample(rawCurrentMah: 4000, rawMaxMah: nil).preciseCharge)
        XCTAssertNil(sample(rawCurrentMah: nil, rawMaxMah: nil).preciseCharge)
    }

    func testPreciseChargeIsNilWhenRawMaxIsZeroOrRatioOutOfRange() {
        XCTAssertNil(sample(rawCurrentMah: 4000, rawMaxMah: 0).preciseCharge)
        // A current reading above max would be a nonsense ratio (>100%).
        XCTAssertNil(sample(rawCurrentMah: 9000, rawMaxMah: 8000).preciseCharge)
    }

    func testBatterySampleDefaultsLeaveRawCapacityNil() {
        let sample = BatterySample(
            timestampMs: 0,
            percent: 50,
            isCharging: false,
            externalPower: false,
            wattsDrawn: -5,
            voltageMv: 12_000,
            amperageMa: -400,
            cycleCount: 10,
            maxCapacityPct: 95
        )
        XCTAssertNil(sample.rawCurrentMah)
        XCTAssertNil(sample.rawMaxMah)
        XCTAssertNil(sample.preciseCharge)
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
