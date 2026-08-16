import XCTest
@testable import BatteryCore

final class AppNameNormalizerTests: XCTestCase {

    // MARK: - Over-merge regression coverage
    //
    // DECISIONS.md flagged this as a known follow-up: stripping any
    // " Helper*" suffix over-merges when the text before " Helper" isn't a
    // real app name on its own. Arc is the worst real-world case — it names
    // its renderer/GPU helpers literally "Browser Helper (Renderer)" /
    // "Browser Helper (GPU)", so naive stripping produced the meaningless
    // app name "Browser" for what is, on an Arc machine, the bulk of
    // browser energy use.

    func testBrowserHelperWithoutPathHintDoesNotProduceBareBrowser() {
        // No bundle path to resolve the real app from: over-merging into
        // "Browser" would be worse than reporting the raw, unmerged name.
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Browser Helper"), "Browser Helper")
        XCTAssertEqual(
            AppNameNormalizer.canonicalName(for: "Browser Helper (Renderer)"),
            "Browser Helper (Renderer)"
        )
        XCTAssertEqual(
            AppNameNormalizer.canonicalName(for: "Browser Helper (GPU)"),
            "Browser Helper (GPU)"
        )
    }

    func testBrowserHelperWithArcPathHintResolvesToArc() {
        let arcPath = "/Applications/Arc.app/Contents/Frameworks/Arc Framework.framework/Versions/A/XPCServices/ArcHelper.xpc/Contents/MacOS/Browser Helper"
        XCTAssertEqual(
            AppNameNormalizer.canonicalName(for: "Browser Helper", bundlePathHint: arcPath),
            "Arc"
        )
        XCTAssertEqual(
            AppNameNormalizer.canonicalName(for: "Browser Helper (Renderer)", bundlePathHint: arcPath),
            "Arc"
        )
        XCTAssertEqual(
            AppNameNormalizer.canonicalName(for: "Browser Helper (GPU)", bundlePathHint: arcPath),
            "Arc"
        )
    }

    /// When " Helper" stripping would collapse the name down to nothing but
    /// a generic bare word (i.e. the text before " Helper" isn't a real app
    /// name), the merge must not happen — the raw, unmerged name is more
    /// useful than a fabricated generic one. This is the general form of
    /// the Arc "Browser Helper" bug: it isn't Arc-specific, any app whose
    /// process happens to be named "<generic word> Helper..." hits it.
    func testHelperStrippingNeverCollapsesToAGenericBareWord() {
        for name in ["App Helper", "App Helper (Renderer)", "Service Helper (GPU)"] {
            let canonical = AppNameNormalizer.canonicalName(for: name)
            XCTAssertEqual(
                canonical,
                name,
                "canonicalName(for: \"\(name)\") merged into \"\(canonical)\" instead of keeping the raw name"
            )
            XCTAssertFalse(
                AppNameNormalizer.genericBareWords.contains(canonical.lowercased()),
                "canonicalName(for: \"\(name)\") returned the generic word \"\(canonical)\""
            )
        }
    }

    // MARK: - appName(fromBundlePath:)

    func testAppNameFromBundlePathExtractsDotAppComponent() {
        XCTAssertEqual(
            AppNameNormalizer.appName(fromBundlePath: "/Applications/Arc.app/Contents/MacOS/Browser Helper"),
            "Arc"
        )
        XCTAssertEqual(
            AppNameNormalizer.appName(
                fromBundlePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper"
            ),
            "Google Chrome"
        )
    }

    func testAppNameFromBundlePathReturnsNilWhenNoAppComponent() {
        XCTAssertNil(AppNameNormalizer.appName(fromBundlePath: "/usr/libexec/some_daemon"))
        XCTAssertNil(AppNameNormalizer.appName(fromBundlePath: nil))
        XCTAssertNil(AppNameNormalizer.appName(fromBundlePath: ""))
    }

    // MARK: - Existing merge behavior stays intact

    func testKnownHelperMergesAreUnaffectedByThePathHintChange() {
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Google Chrome Helper (Renderer)"), "Google Chrome")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Slack Helper (Renderer)"), "Slack")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Arc Helper"), "Arc")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "com.apple.WebKit.WebContent"), "Safari")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "ghostty"), "ghostty")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: ""), "")
    }

    /// A path hint that doesn't resolve to a recognizable app must not
    /// change behavior for names that already merge fine on their own.
    func testPathHintIsIgnoredWhenNameAlreadyResolvesCleanly() {
        XCTAssertEqual(
            AppNameNormalizer.canonicalName(
                for: "Slack Helper (Renderer)",
                bundlePathHint: "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)"
            ),
            "Slack"
        )
    }
}
