import XCTest
@testable import BrowserCore

final class BrowserShortcutTests: XCTestCase {
    func testVisiblePanelDismisses() {
        for enabled in [false, true] {
            XCTAssertEqual(BrowserShortcut.action(isVisible: true, searchSelection: enabled, hasAccess: true),
                           .dismiss)
        }
    }

    func testDisabledOpeningDoesNotReadSelection() {
        for access in [false, true] {
            XCTAssertEqual(BrowserShortcut.action(isVisible: false, searchSelection: false, hasAccess: access),
                           .open, "Selection search must be opt-in")
        }
    }

    func testEnabledOpeningWithoutAccessAsksForAccess() {
        XCTAssertEqual(BrowserShortcut.action(isVisible: false, searchSelection: true, hasAccess: false),
                       .needsAccess)
    }

    func testEnabledOpeningWithAccessReadsSelection() {
        XCTAssertEqual(BrowserShortcut.action(isVisible: false, searchSelection: true, hasAccess: true),
                       .openWithSelection)
    }

    func testUnavailableOrEmptySelectionGivesNoQuery() {
        // Unsupported source apps and empty selections both open manual search.
        for selection in ["", " \n\t"] {
            XCTAssertNil(BrowserShortcut.query(fromSelection: selection))
        }
        XCTAssertEqual(BrowserShortcut.query(fromSelection: "  café & https://example.com\n"),
                       "café & https://example.com")
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
