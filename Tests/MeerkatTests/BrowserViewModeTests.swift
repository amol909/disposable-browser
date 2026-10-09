import AppKit
import WebKit
import XCTest
@testable import Meerkat

final class BrowserViewModeTests: XCTestCase {
    @MainActor
    private func withBrowser(mode: String?, _ verify: (BrowserPanel, WKWebView) -> Void) {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "browserViewMode")
        defaults.set(mode, forKey: "browserViewMode")
        let browser = BrowserPanel()
        defer {
            browser.dismiss()
            defaults.set(saved, forKey: "browserViewMode")
        }
        browser.show()
        func findWebView(_ view: NSView) -> WKWebView? {
            (view as? WKWebView) ?? view.subviews.lazy.compactMap { findWebView($0) }.first
        }
        let web = findWebView(browser.panel.contentView!)!
        verify(browser, web)
    }

    @MainActor
    func testMissingPreferenceStartsMobileAndLiveChangesUpdateOverride() async {
        withBrowser(mode: nil) { _, web in
            XCTAssertNil(web.url, "UA must be applied before any page loads")
            XCTAssertTrue(web.customUserAgent?.contains("iPhone") == true)
            XCTAssertTrue(web.customUserAgent?.contains("Mobile/") == true)
            UserDefaults.standard.set("Desktop", forKey: "browserViewMode")
            XCTAssertTrue((web.customUserAgent ?? "").isEmpty, "Desktop clears the override")
            UserDefaults.standard.set("Mobile", forKey: "browserViewMode")
            XCTAssertTrue(web.customUserAgent?.contains("iPhone") == true)
        }
    }

    @MainActor
    func testSavedDesktopChoiceAppliesBeforeInitialLoad() async {
        withBrowser(mode: "Desktop") { _, web in
            XCTAssertNil(web.url)
            XCTAssertTrue((web.customUserAgent ?? "").isEmpty)
        }
    }
}
