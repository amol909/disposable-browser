import AppKit
import WebKit
import XCTest
@testable import DisposableBrowser

final class BrowserPanelTests: XCTestCase {
    @MainActor
    private func headerViews(_ browser: BrowserPanel) -> [NSView] {
        browser.panel.toolbar?.items.compactMap(\.view) ?? []
    }

    @MainActor
    func testEmptyChromeIsCompactAccessibleAndDisabled() async {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        browser.show()
        XCTAssertEqual(browser.panel.titleVisibility, .hidden)
        XCTAssertEqual(browser.panel.toolbarStyle, .unifiedCompact)
        let buttons = headerViews(browser).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.map { $0.accessibilityLabel() }, ["Back", "Open in Browser"])
        XCTAssertEqual(buttons.map(\.toolTip), ["Back", "Open in Browser"])
        XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled && $0.title.isEmpty && $0.image != nil })
        let message = browser.panel.contentView!.subviews.compactMap { $0 as? NSTextField }.first!
        XCTAssertTrue(message.isHidden)
    }

    @MainActor
    func testHeaderFitsNormalAndMinimumWidthsWithoutTrafficLightOverlap() async {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        browser.show()
        let header = headerViews(browser)
        let search = header.compactMap { $0 as? NSSearchField }.first!
        let external = header.compactMap { $0 as? NSButton }.last!
        for width: CGFloat in [460, 360] {
            var frame = browser.panel.frame
            frame.size.width = width
            frame.size = browser.windowWillResize(browser.panel, to: frame.size)
            browser.panel.setFrame(frame, display: true)
            browser.panel.contentView?.superview?.layoutSubtreeIfNeeded()
            let root = browser.panel.contentView!
            XCTAssertEqual(root.frame.width, width, accuracy: 1)
            XCTAssertEqual(root.frame.height, browser.panel.frame.height, accuracy: 1)
            XCTAssertLessThan(root.safeAreaRect.maxY, root.bounds.maxY)
            XCTAssertEqual(browser.panel.alphaValue, 1)
            let lightsRight = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { browser.panel.standardWindowButton($0) }
                .map { $0.convert($0.bounds, to: nil).maxX }.max()!
            let searchFrame = search.convert(search.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(searchFrame.minX, lightsRight)
            XCTAssertGreaterThanOrEqual(searchFrame.width, 100)
            XCTAssertLessThanOrEqual(external.convert(external.bounds, to: nil).maxX, width)
            XCTAssertTrue(search.window === browser.panel)
            XCTAssertTrue(external.window === browser.panel)
            XCTAssertTrue((browser.panel.firstResponder as? NSTextView)?.delegate === search)
        }
    }

    @MainActor
    func testNoticesAndErrorsAreTransientAndCancellationDoesNotEraseNotice() async {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        let notice = "Enable Accessibility access from Settings to search selected text."
        browser.show(notice: notice)
        var frame = browser.panel.frame
        frame.size.width = 360
        frame.size = browser.windowWillResize(browser.panel, to: frame.size)
        browser.panel.setFrame(frame, display: true)
        browser.panel.contentView?.layoutSubtreeIfNeeded()
        let message = browser.panel.contentView!.subviews.compactMap { $0 as? NSTextField }.first!
        XCTAssertFalse(message.isHidden)
        XCTAssertEqual(message.stringValue, notice)
        XCTAssertEqual(browser.panel.frame.width, 360)
        XCTAssertGreaterThan(message.frame.height, 14, "Long notices must wrap rather than widen the panel")
        let web = WKWebView()
        browser.webView(web, didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertEqual(message.stringValue, notice)
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        browser.webView(web, didFailProvisionalNavigation: nil, withError: failure)
        XCTAssertEqual(message.stringValue, failure.localizedDescription)
        browser.webView(web, didFinish: nil)
        XCTAssertTrue(message.isHidden)
        XCTAssertTrue(message.stringValue.isEmpty)
        browser.panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(message.frame.height, 0)
    }

    @MainActor
    func testGlassWaitingStateIsReplacedByNavigationAndRestoredOnReopen() async {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        browser.show()
        let root = browser.panel.contentView!
        let material = root as! NSVisualEffectView
        XCTAssertEqual(material.material, .hudWindow)
        XCTAssertEqual(material.blendingMode, .behindWindow)
        XCTAssertEqual(material.state, .followsWindowActiveState)
        XCTAssertTrue(browser.panel.styleMask.contains(.fullSizeContentView))
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(root.frame.height, browser.panel.frame.height, accuracy: 1)
        let glass = root.subviews.first!
        let web = descendants(root).compactMap { $0 as? WKWebView }.first!
        let prompt = descendants(glass).compactMap { $0 as? NSTextField }.first!
        XCTAssertEqual(prompt.stringValue, "A quick look?")
        XCTAssertFalse(glass.isHidden)
        XCTAssertTrue(web.isHidden, "An opaque blank webview must not cover the empty-state glass")
        XCTAssertFalse(browser.panel.isOpaque)
        XCTAssertEqual(browser.panel.backgroundColor?.alphaComponent, 0)
        browser.show(notice: "No readable selection. Type your search instead.")
        XCTAssertFalse(glass.isHidden, "A manual-search notice must preserve the waiting state")
        XCTAssertTrue(web.isHidden)

        browser.webView(web, didStartProvisionalNavigation: nil)
        XCTAssertTrue(glass.isHidden)
        XCTAssertFalse(web.isHidden)
        XCTAssertTrue(browser.panel.isOpaque)
        root.layoutSubtreeIfNeeded()
        let pageFrame = web.convert(web.bounds, to: root)
        XCTAssertLessThanOrEqual(pageFrame.maxY, root.safeAreaRect.maxY)
        XCTAssertFalse(material.isHidden, "The header must retain its full-window material during navigation")
        browser.webView(web, didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        XCTAssertTrue(glass.isHidden, "Navigation errors must not cover the page with the prompt")

        browser.dismiss()
        browser.show()
        let reopenedWeb = descendants(root).compactMap { $0 as? WKWebView }.first!
        XCTAssertFalse(glass.isHidden)
        XCTAssertFalse(browser.panel.isOpaque)
        XCTAssertTrue(reopenedWeb.isHidden)
        XCTAssertFalse(reopenedWeb === web)
        XCTAssertNil(reopenedWeb.url)
        let search = headerViews(browser).compactMap { $0 as? NSSearchField }.first!
        XCTAssertTrue((browser.panel.firstResponder as? NSTextView)?.delegate === search)
    }
}
