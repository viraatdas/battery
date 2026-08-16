import BatteryCore
import XCTest
@testable import BatteryScopeApp

final class MenuBarSummaryTests: XCTestCase {

    func testNoSampleIsPlaceholder() {
        let summary = MenuBarSummary(sample: nil)
        XCTAssertEqual(summary, MenuBarSummary.placeholder)
        XCTAssertEqual(summary.text, "--")
    }

    func testCharging() {
        let sample = Fixtures.batterySample(percent: 61.4, isCharging: true, wattsDrawn: 20)
        let summary = MenuBarSummary(sample: sample)
        XCTAssertEqual(summary.symbol, "battery.100.bolt")
        XCTAssertEqual(summary.text, "61%")
        XCTAssertEqual(summary.accessibility, "Charging, 61%")
    }

    func testOnExternalPowerNotCharging() {
        // Plugged in but topped off: externalPower without isCharging.
        let sample = Fixtures.batterySample(percent: 100, isCharging: false, externalPower: true, wattsDrawn: 0)
        let summary = MenuBarSummary(sample: sample)
        XCTAssertEqual(summary.symbol, "powerplug")
        XCTAssertEqual(summary.text, "100%")
        XCTAssertEqual(summary.accessibility, "On power, 100%")
    }

    func testDischargingWithMeasurableDraw() {
        let sample = Fixtures.batterySample(percent: 44, wattsDrawn: -12.34)
        let summary = MenuBarSummary(sample: sample)
        XCTAssertEqual(summary.symbol, MenuBarSummary.batterySymbol(for: 44))
        XCTAssertEqual(summary.text, "12.3W")
        XCTAssertEqual(summary.accessibility, "On battery, drawing 12.3 W, 44%")
    }

    func testDischargingBelowDrawThresholdShowsLevelInstead() {
        // 0.05 W is the cutoff below which the draw is treated as noise.
        let sample = Fixtures.batterySample(percent: 77, wattsDrawn: -0.04)
        let summary = MenuBarSummary(sample: sample)
        XCTAssertEqual(summary.text, "77%")
        XCTAssertEqual(summary.accessibility, "On battery, 77%")
    }

    func testDischargingDrawIsAbsoluteValueRegardlessOfSign() {
        // The sampler always records discharge as negative watts.
        let sample = Fixtures.batterySample(percent: 50, wattsDrawn: -8)
        XCTAssertEqual(MenuBarSummary(sample: sample).text, "8.0W")
    }

    // MARK: - batterySymbol thresholds

    func testBatterySymbolThresholds() {
        XCTAssertEqual(MenuBarSummary.batterySymbol(for: 0), "battery.0percent")
        XCTAssertEqual(MenuBarSummary.batterySymbol(for: 12.4), "battery.0percent")
        XCTAssertEqual(MenuBarSummary.batterySymbol(for: 12.5), "battery.25percent")
        XCTAssertEqual(MenuBarSummary.batterySymbol(for: 37.4), "battery.25percent")
        XCTAssertEqual(MenuBarSummary.batterySymbol(for: 37.5), "battery.50percent")
        XCTAssertEqual(MenuBarSummary.batterySymbol(for: 62.4), "battery.50percent")
        XCTAssertEqual(MenuBarSummary.batterySymbol(for: 62.5), "battery.75percent")
        XCTAssertEqual(MenuBarSummary.batterySymbol(for: 87.4), "battery.75percent")
        XCTAssertEqual(MenuBarSummary.batterySymbol(for: 87.5), "battery.100percent")
        XCTAssertEqual(MenuBarSummary.batterySymbol(for: 100), "battery.100percent")
    }
}
