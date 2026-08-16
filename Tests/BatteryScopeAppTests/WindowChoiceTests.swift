import BatteryCore
import XCTest
@testable import BatteryScopeApp

final class WindowChoiceTests: XCTestCase {

    private let end = Fixtures.anchor

    func testLastHour() {
        let window = WindowChoice.lastHour.window(ending: end)
        XCTAssertEqual(window.start, end.addingTimeInterval(-3600))
        XCTAssertEqual(window.end, end)
    }

    func testLast6Hours() {
        let window = WindowChoice.last6Hours.window(ending: end)
        XCTAssertEqual(window.duration, 6 * 3600)
        XCTAssertEqual(window.end, end)
    }

    func testLast24Hours() {
        let window = WindowChoice.last24Hours.window(ending: end)
        XCTAssertEqual(window.duration, 24 * 3600)
    }

    func testLast7Days() {
        let window = WindowChoice.last7Days.window(ending: end)
        XCTAssertEqual(window.duration, 7 * 24 * 3600)
    }

    func testEveryChoiceEndsExactlyAtTheGivenInstant() {
        for choice in WindowChoice.allCases {
            XCTAssertEqual(choice.window(ending: end).end, end, "\(choice)")
        }
    }

    func testTitlesAreDistinct() {
        let titles = Set(WindowChoice.allCases.map(\.title))
        XCTAssertEqual(titles.count, WindowChoice.allCases.count)
    }
}
