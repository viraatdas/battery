import XCTest
@testable import BatteryScopeApp

final class FormattingTests: XCTestCase {

    // MARK: - percent

    func testPercent() {
        XCTAssertEqual(Fmt.percent(0), "0%")
        XCTAssertEqual(Fmt.percent(84.4), "84%")
        XCTAssertEqual(Fmt.percent(84.5), "85%")
        XCTAssertEqual(Fmt.percent(-5), "-5%")
        XCTAssertEqual(Fmt.percent(1_000_000), "1000000%")
        XCTAssertEqual(Fmt.percent(.nan), "nan%")
    }

    // MARK: - share

    func testShare() {
        // Below 10, one decimal place; at or above, none.
        XCTAssertEqual(Fmt.share(0), "0.0%")
        XCTAssertEqual(Fmt.share(6.24), "6.2%")
        XCTAssertEqual(Fmt.share(10), "10%")
        XCTAssertEqual(Fmt.share(-12), "-12%")
        XCTAssertEqual(Fmt.share(.nan), "nan%")
    }

    // MARK: - wattsCompact / watts

    func testWattsCompact() {
        XCTAssertEqual(Fmt.wattsCompact(0), "0.0W")
        XCTAssertEqual(Fmt.wattsCompact(-6.28), "6.3W")
        XCTAssertEqual(Fmt.wattsCompact(1_000_000), "1000000.0W")
    }

    func testWatts() {
        XCTAssertEqual(Fmt.watts(0), "0.0 W")
        XCTAssertEqual(Fmt.watts(-6.28), "6.3 W")
        XCTAssertEqual(Fmt.watts(.nan), "nan W")
    }

    // MARK: - wattHours

    func testWattHours() {
        // Two decimals below one watt-hour, one above it.
        XCTAssertEqual(Fmt.wattHours(0), "0.00 Wh")
        XCTAssertEqual(Fmt.wattHours(0.5), "0.50 Wh")
        XCTAssertEqual(Fmt.wattHours(1), "1.0 Wh")
        XCTAssertEqual(Fmt.wattHours(12.44), "12.4 Wh")
        XCTAssertEqual(Fmt.wattHours(-0.5), "-0.50 Wh")
    }

    // MARK: - rate

    func testRate() {
        XCTAssertEqual(Fmt.rate(0), "0.0%/hr")
        XCTAssertEqual(Fmt.rate(7.36), "7.4%/hr")
        XCTAssertEqual(Fmt.rate(-2), "-2.0%/hr")
        XCTAssertEqual(Fmt.rate(.nan), "nan%/hr")
    }

    // MARK: - hoursMinutes

    func testHoursMinutesFormatsWithoutRedundantZero() {
        XCTAssertEqual(Fmt.hoursMinutes(0), "0m")
        XCTAssertEqual(Fmt.hoursMinutes(0.05), "3m")
        XCTAssertEqual(Fmt.hoursMinutes(2), "2h")
        XCTAssertEqual(Fmt.hoursMinutes(4 + 10.0 / 60), "4h 10m")
    }

    func testHoursMinutesTreatsSignAsMagnitude() {
        // "Never 0h 42m" — the sign carries no separate rendering; negative
        // durations show the same as their positive magnitude.
        XCTAssertEqual(Fmt.hoursMinutes(-2), "2h")
    }

    func testHoursMinutesNonFiniteInputsDoNotCrash() {
        XCTAssertEqual(Fmt.hoursMinutes(.nan), "—")
        XCTAssertEqual(Fmt.hoursMinutes(.infinity), "—")
        XCTAssertEqual(Fmt.hoursMinutes(-.infinity), "—")
    }

    func testHoursMinutesHugeFiniteInputDoesNotCrash() {
        // Regression: `Int(Double)` traps when the value overflows `Int`'s
        // range, and this used to reach that conversion unguarded. Merely
        // returning (rather than trapping) is the assertion; the exact text
        // of an astronomical duration is not a contract worth pinning.
        XCTAssertFalse(Fmt.hoursMinutes(.greatestFiniteMagnitude).isEmpty)
    }

    // MARK: - age

    func testAgeBuckets() {
        XCTAssertEqual(Fmt.age(0), "just now")
        XCTAssertEqual(Fmt.age(4.9), "just now")
        XCTAssertEqual(Fmt.age(5), "5s ago")
        XCTAssertEqual(Fmt.age(89), "89s ago")
        XCTAssertEqual(Fmt.age(90), "2m ago")
        XCTAssertEqual(Fmt.age(5399), "90m ago")
        XCTAssertEqual(Fmt.age(5400), "2h ago")
        XCTAssertEqual(Fmt.age(172_799), "48h ago")
        XCTAssertEqual(Fmt.age(172_800), "2d ago")
    }

    func testAgeClampsNegativeToZero() {
        XCTAssertEqual(Fmt.age(-500), "just now")
    }

    func testAgeNonFiniteInputsDoNotCrash() {
        XCTAssertEqual(Fmt.age(.nan), "—")
        XCTAssertEqual(Fmt.age(.infinity), "—")
    }

    func testAgeHugeFiniteInputDoesNotCrash() {
        XCTAssertEqual(Fmt.age(.greatestFiniteMagnitude), "9007199254740992d ago")
    }

    // MARK: - integer

    func testInteger() {
        XCTAssertEqual(Fmt.integer(0), "0")
        XCTAssertEqual(Fmt.integer(999), "999")
        XCTAssertEqual(Fmt.integer(1_000), "1,000")
        XCTAssertEqual(Fmt.integer(1_234_567), "1,234,567")
        XCTAssertEqual(Fmt.integer(-1_234), "-1,234")
    }

    // MARK: - estimated

    func testEstimated() {
        XCTAssertEqual(Fmt.estimated("1.2 Wh"), "~1.2 Wh")
        XCTAssertEqual(Fmt.estimated(""), "~")
    }
}
