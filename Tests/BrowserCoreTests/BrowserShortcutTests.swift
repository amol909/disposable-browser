import XCTest
@testable import BrowserCore

final class BrowserShortcutTests: XCTestCase {
    func testVisiblePanelDismissesWithoutReadingSelection() {
        for enabled in [false, true] {
            XCTAssertEqual(BrowserShortcut.action(isVisible: true, searchSelection: enabled, hasAccess: true) {
                XCTFail("Dismissal must not inspect the source app")
                return "selected text"
            }, .dismiss)
        }
    }

    func testDisabledOpeningDoesNotReadSelection() {
        for access in [false, true] {
            XCTAssertEqual(BrowserShortcut.action(isVisible: false, searchSelection: false, hasAccess: access) {
                XCTFail("Selection search must be opt-in")
                return "selected text"
            }, .open(query: nil))
        }
    }

    func testEnabledOpeningWithoutAccessAsksForAccessWithoutReading() {
        XCTAssertEqual(BrowserShortcut.action(isVisible: false, searchSelection: true, hasAccess: false) {
            XCTFail("Reading without access cannot succeed")
            return "selected text"
        }, .needsAccess)
    }

    func testEnabledOpeningReadsSelectionOnce() {
        var reads = 0
        XCTAssertEqual(BrowserShortcut.action(isVisible: false, searchSelection: true, hasAccess: true) {
            reads += 1
            return "  café & https://example.com\n"
        }, .open(query: "café & https://example.com"))
        XCTAssertEqual(reads, 1)
    }

    func testUnavailableOrEmptySelectionOpensManualSearch() {
        // Unsupported source apps and empty selections both produce no query.
        for selection: String? in [nil, "", " \n\t"] {
            XCTAssertEqual(BrowserShortcut.action(isVisible: false, searchSelection: true, hasAccess: true) {
                selection
            }, .open(query: nil))
        }
    }

    func testSelectionWhitespaceBecomesOneLine() {
        XCTAssertEqual(BrowserShortcut.query(fromSelection: "  GATT\n\n  attribute\tprotocol \r\n"),
                       "GATT attribute protocol")
        XCTAssertEqual(BrowserShortcut.query(fromSelection: "a\u{00A0}b\u{2028}c"), "a b c")
        XCTAssertNil(BrowserShortcut.query(fromSelection: "\n \t"))
    }

    func testLongSelectionIsCutAtAWordBoundary() throws {
        let words = Array(repeating: "word", count: 200).joined(separator: "\n")
        let query = try XCTUnwrap(BrowserShortcut.query(fromSelection: words))
        XCTAssertLessThanOrEqual(query.count, BrowserShortcut.maxQueryLength)
        XCTAssertTrue(query.hasSuffix("word"))
        XCTAssertFalse(query.contains("  "))
        let longWord = String(repeating: "x", count: 900)
        XCTAssertEqual(BrowserShortcut.query(fromSelection: longWord)?.count, BrowserShortcut.maxQueryLength)
    }
}
