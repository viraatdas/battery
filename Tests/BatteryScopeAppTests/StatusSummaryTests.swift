import BatteryCore
import XCTest
@testable import BatteryScopeApp

final class StatusSummaryTests: XCTestCase {

    // MARK: - remainingText

    func testRemainingTextWhileCharging() {
        let sample = Fixtures.batterySample(isCharging: true)
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: sample))
        XCTAssertEqual(status.remainingText, "Charging")
    }

    func testRemainingTextOnExternalPower() {
        let sample = Fixtures.batterySample(externalPower: true, wattsDrawn: 0)
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: sample))
        XCTAssertEqual(status.remainingText, "Plugged in")
    }

    func testRemainingTextWithNoMeasuredDrain() {
        let sample = Fixtures.batterySample()
        // No `hoursRemaining` on the health record: nothing to estimate from.
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: sample))
        XCTAssertEqual(status.remainingText, "Not enough drain measured")
    }

    func testRemainingTextWithMeasuredDrain() {
        let sample = Fixtures.batterySample()
        let window = Fixtures.window()
        let health = Fixtures.health(estimatedHoursRemaining: 4 + 10.0 / 60, window: window)
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: sample, health: health))
        XCTAssertEqual(status.remainingText, "4h 10m left")
    }

    func testRemainingTextTreatsNonPositiveEstimateAsUnmeasured() {
        let sample = Fixtures.batterySample()
        let window = Fixtures.window()
        let health = Fixtures.health(estimatedHoursRemaining: 0, window: window)
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: sample, health: health))
        XCTAssertEqual(status.remainingText, "Not enough drain measured")
    }

    // MARK: - stateText

    func testStateTextCharging() {
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: Fixtures.batterySample(isCharging: true)))
        XCTAssertEqual(status.stateText, "Charging")
    }

    func testStateTextOnPower() {
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: Fixtures.batterySample(externalPower: true)))
        XCTAssertEqual(status.stateText, "On power")
    }

    func testStateTextOnBattery() {
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: Fixtures.batterySample()))
        XCTAssertEqual(status.stateText, "On battery")
    }

    // MARK: - isStale

    func testIsStaleAtExactly300SecondsIsNotStale() {
        let generatedAt = Fixtures.anchor
        let sample = Fixtures.batterySample(at: generatedAt.addingTimeInterval(-300))
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: sample, generatedAt: generatedAt))
        XCTAssertEqual(status.sampleAge, 300)
        XCTAssertFalse(status.isStale)
    }

    func testIsStaleJustPast300SecondsIsStale() {
        let generatedAt = Fixtures.anchor
        let sample = Fixtures.batterySample(at: generatedAt.addingTimeInterval(-300.001))
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: sample, generatedAt: generatedAt))
        XCTAssertTrue(status.isStale)
    }

    func testIsStaleWithNoSampleAtAll() {
        // No `latest` and no `health` either: nothing to be fresh about, so
        // this counts as stale rather than silently reading as current.
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: nil))
        XCTAssertNil(status.sampleAge)
        XCTAssertTrue(status.isStale)
        XCTAssertEqual(status.freshnessText, "No samples yet")
    }

    // MARK: - latest nil, health present

    func testFallsBackToHealthWhenLatestIsNil() {
        let window = Fixtures.window()
        let health = Fixtures.health(
            percent: 33,
            isCharging: true,
            externalPower: true,
            estimatedHoursRemaining: 5,
            window: window
        )
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: nil, health: health))
        XCTAssertEqual(status.percent, 33)
        XCTAssertTrue(status.isCharging)
        XCTAssertTrue(status.externalPower)
        // The `latest`-derived instantaneous draw is never shown when there
        // is no `latest` sample to draw it from, even though health carries
        // its own runtime estimate.
        XCTAssertNil(status.watts)
        XCTAssertEqual(status.hoursRemaining, 5)
        // sampleAge is strictly a function of `latest`, not `health`.
        XCTAssertNil(status.sampleAge)
    }

    func testDefaultsToZeroPercentWhenNeitherLatestNorHealthExist() {
        let status = StatusSummary(snapshot: Fixtures.snapshot(latest: nil, health: nil))
        XCTAssertEqual(status.percent, 0)
        XCTAssertFalse(status.isCharging)
        XCTAssertFalse(status.externalPower)
    }
}
