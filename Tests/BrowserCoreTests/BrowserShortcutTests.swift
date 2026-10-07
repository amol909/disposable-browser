import XCTest
@testable import BrowserCore

final class BrowserShortcutTests: XCTestCase {
    func testVisiblePanelDismissesWithoutReadingSelection() {
        for enabled in [false, true] {
            XCTAssertEqual(BrowserShortcut.action(isVisible: true, searchSelection: enabled) {
                XCTFail("Dismissal must not inspect the source app")
                return "selected text"
            }, .dismiss)
        }
    }

    func testDisabledOpeningDoesNotReadSelection() {
        XCTAssertEqual(BrowserShortcut.action(isVisible: false, searchSelection: false) {
            XCTFail("Selection search must be opt-in")
            return "selected text"
        }, .open(query: nil))
    }

    func testEnabledOpeningReadsSelectionOnce() {
        var reads = 0
        XCTAssertEqual(BrowserShortcut.action(isVisible: false, searchSelection: true) {
            reads += 1
            return "  café & https://example.com\n"
        }, .open(query: "café & https://example.com"))
        XCTAssertEqual(reads, 1)
    }

    func testUnavailableOrEmptySelectionOpensManualSearch() {
        // Permission denied and unsupported source apps both produce nil.
        for selection: String? in [nil, "", " \n\t"] {
            XCTAssertEqual(BrowserShortcut.action(isVisible: false, searchSelection: true) {
                selection
            }, .open(query: nil))
        }
    }
}
