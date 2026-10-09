import AppKit
import WebKit
import XCTest
import os
@testable import DisposableBrowser

final class BrowserPanelTests: XCTestCase {
    @MainActor
    private func searchField(_ browser: BrowserPanel) -> NSSearchField {
        browser.panel.toolbar!.items.compactMap { ($0 as? NSSearchToolbarItem)?.searchField }.first!
    }

    @MainActor
    private func iconItems(_ browser: BrowserPanel) -> [NSToolbarItem] {
        browser.panel.toolbar!.items.filter { !($0 is NSSearchToolbarItem) }
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor
    private func noticeLabel(_ browser: BrowserPanel) -> NSTextField {
        descendants(browser.panel.contentView!).compactMap { $0 as? NSTextField }
            .first { $0.stringValue != "A quick look?" }!
    }

    /// Waits until a panel frame animation finishes.
    @MainActor
    private func settle(_ panel: NSPanel) async throws {
        var last = NSRect.zero
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(80))
            if panel.frame == last { return }
            last = panel.frame
        }
    }

    @MainActor
    private func isShown(_ view: NSView) -> Bool {
        sequence(first: view, next: \.superview).allSatisfy { !$0.isHidden }
    }

    @MainActor
    func testEmptyChromeIsCompactAccessibleAndDisabled() async {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        browser.show()
        XCTAssertEqual(browser.panel.titleVisibility, .hidden)
        XCTAssertEqual(browser.panel.toolbarStyle, .unifiedCompact)
        let order = browser.panel.toolbar!.items.map { $0 is NSSearchToolbarItem ? "search" : $0.label }
        XCTAssertEqual(order, ["Back", "search", "Open in Browser"])
        let icons = iconItems(browser)
        XCTAssertEqual(icons.map { $0.image?.accessibilityDescription }, ["Back", "Open in Browser"])
        XCTAssertEqual(icons.map(\.toolTip), ["Back", "Open in Browser"])
        XCTAssertTrue(icons.allSatisfy { !$0.isEnabled && $0.isBordered && $0.image != nil })
        XCTAssertFalse(isShown(noticeLabel(browser)))
    }

    @MainActor
    func testHeaderFitsNormalAndMinimumWidthsWithoutTrafficLightOverlap() async {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        browser.show()
        let search = searchField(browser)
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
            XCTAssertLessThanOrEqual(searchFrame.maxX, width - 40, "Leave room for Open in Browser")
            XCTAssertTrue(search.window === browser.panel)
            XCTAssertEqual(browser.panel.toolbar!.visibleItems?.count, 3, "No item may move to overflow")
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
        let message = noticeLabel(browser)
        XCTAssertTrue(isShown(message))
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
        XCTAssertFalse(isShown(message))
        XCTAssertTrue(message.stringValue.isEmpty)
    }

    @MainActor
    func testCollapsedBarExpandsForNavigationAndCollapsesOnReopen() async throws {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        browser.show()
        let panel = browser.panel
        let root = panel.contentView!
        let material = root as! NSVisualEffectView
        XCTAssertEqual(material.material, .popover)
        XCTAssertEqual(material.blendingMode, .behindWindow)
        XCTAssertEqual(material.state, .followsWindowActiveState)
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        let toolbarHeight = panel.frame.height - panel.contentLayoutRect.height
        XCTAssertEqual(panel.frame.height, toolbarHeight, accuracy: 1, "Waiting shows only the toolbar")
        XCTAssertLessThan(panel.frame.height, 80)
        XCTAssertEqual(panel.minSize.height, panel.maxSize.height, "The bar resizes only horizontally")
        let web = descendants(root).compactMap { $0 as? WKWebView }.first!
        XCTAssertTrue(web.isHidden, "An opaque blank webview must not cover the bar material")
        XCTAssertGreaterThan(web.frame.height, 300, "The hidden page waits at its expanded size")
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor?.alphaComponent, 0)

        let top = panel.frame.maxY
        browser.show(notice: "No readable selection. Type your search instead.")
        try await settle(panel)
        XCTAssertGreaterThan(panel.frame.height, toolbarHeight + 20, "The bar grows to show a notice")
        XCTAssertTrue(web.isHidden, "A manual-search notice must preserve the waiting state")

        browser.webView(web, didStartProvisionalNavigation: nil)
        XCTAssertFalse(web.isHidden)
        XCTAssertTrue(panel.isOpaque)
        try await settle(panel)
        let expected = min(720, panel.screen!.visibleFrame.height - 24)
        XCTAssertEqual(panel.frame.height, expected, accuracy: 1, "Navigation expands to the page height")
        XCTAssertEqual(panel.frame.maxY, top, accuracy: 1, "The bar grows down from a fixed top edge")
        XCTAssertGreaterThanOrEqual(panel.minSize.height, 400)
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(web.frame, web.superview!.bounds, "After the animation, the page follows the window")
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
        let pageFrame = web.convert(web.bounds, to: root)
        let edge = root.subviews.compactMap { $0 as? NSVisualEffectView }.first { $0.blendingMode == .withinWindow }!
        if #available(macOS 26.0, *) {
            // The page scrolls under the glass toolbar; WebKit and the soft edge keep it legible.
            XCTAssertEqual(pageFrame.maxY, root.bounds.maxY, accuracy: 1)
            XCTAssertEqual(web.obscuredContentInsets.top, root.safeAreaInsets.top, accuracy: 1)
            XCTAssertFalse(edge.isHidden)
        } else {
            XCTAssertLessThanOrEqual(pageFrame.maxY, root.safeAreaRect.maxY)
            XCTAssertTrue(edge.isHidden)
        }
        browser.webView(web, didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        XCTAssertGreaterThan(panel.frame.height, 400, "Navigation errors keep the page open")

        browser.dismiss()
        browser.show()
        let reopenedWeb = descendants(root).compactMap { $0 as? WKWebView }.first!
        XCTAssertEqual(panel.frame.height, toolbarHeight, accuracy: 1)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertTrue(reopenedWeb.isHidden)
        XCTAssertFalse(reopenedWeb === web)
        XCTAssertNil(reopenedWeb.url)
        let search = searchField(browser)
        XCTAssertTrue((panel.firstResponder as? NSTextView)?.delegate === search)
        if #available(macOS 26.0, *) { XCTAssertTrue(edge.isHidden, "The bar needs no page edge") }
    }

    @MainActor
    func testSelectionReadShowsFocusedBarBeforeTheReadEnds() async throws {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        browser.show(readingSelection: { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return "selected words"
        })
        XCTAssertTrue(browser.panel.isVisible, "The bar must not wait for the selection read")
        XCTAssertTrue(browser.panel.isKeyWindow, "Escape must reach the panel during the read")
        let web = descendants(browser.panel.contentView!).compactMap { $0 as? WKWebView }.first!
        for _ in 0..<100 where web.isHidden {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(web.isHidden, "A selection search expands to the page")
        XCTAssertTrue(browser.panel.isKeyWindow)
        let query = URLComponents(url: try XCTUnwrap(web.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value
        XCTAssertEqual(query, "selected words")
    }

    @MainActor
    func testTypedCopyHidesPanelUntilItEnds() async throws {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        let panel = browser.panel
        let states = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        browser.show(readingSelection: { handoff in
            let wanted = handoff(true)
            let hidden = DispatchQueue.main.sync { MainActor.assumeIsolated { !panel.isVisible } }
            _ = handoff(false)
            let focused = DispatchQueue.main.sync { MainActor.assumeIsolated { panel.isKeyWindow } }
            states.withLock { $0 = [wanted, hidden, focused] }
            return nil
        })
        for _ in 0..<100 where states.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(states.withLock { $0 }, [true, true, true], "Hidden during the Copy, focused after it")
        XCTAssertTrue((panel.firstResponder as? NSTextView)?.delegate === searchField(browser))
    }

    @MainActor
    func testTextTypedDuringReadWinsOverSelection() async throws {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        let search = searchField(browser)
        browser.show(readingSelection: { _ in
            Thread.sleep(forTimeInterval: 0.1)
            return "selected words"
        })
        search.stringValue = "typed"
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(search.stringValue, "typed")
        let web = descendants(browser.panel.contentView!).compactMap { $0 as? WKWebView }.first!
        XCTAssertNil(web.url)
    }

    @MainActor
    func testSelectionShortcutSearchesWhilePageIsOpen() async throws {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        browser.show(query: "first")
        browser.show(readingSelection: { _ in "second" })
        let web = descendants(browser.panel.contentView!).compactMap { $0 as? WKWebView }.first!
        func query() -> String? {
            web.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "q" }?.value
        }
        for _ in 0..<100 where query() != "second" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(query(), "second", "An open panel searches a new selection")
    }

    @MainActor
    func testUnreadableSelectionShowsNoticeAndDismissalDiscardsRead() async throws {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        let notice = "No readable selection. Type your search instead."
        browser.show(readingSelection: { _ in nil }, otherwise: notice)
        let message = noticeLabel(browser)
        for _ in 0..<100 where message.stringValue.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(message.stringValue, notice)
        XCTAssertTrue((browser.panel.firstResponder as? NSTextView)?.delegate === searchField(browser))

        browser.dismiss()
        let stillWanted = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        browser.show(readingSelection: { handoff in
            Thread.sleep(forTimeInterval: 0.1)
            stillWanted.withLock { $0 = handoff(true) }
            return "late words"
        })
        browser.dismiss()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(browser.panel.isVisible, "A read that ends after dismissal must not reopen")
        XCTAssertTrue(searchField(browser).stringValue.isEmpty)
        XCTAssertEqual(stillWanted.withLock { $0 }, false, "No Copy may be typed after dismissal")
    }

    @MainActor
    func testAddressShowsHostWhileBrowsingAndFullURLWhileEditing() async throws {
        _ = NSApplication.shared
        let browser = BrowserPanel()
        defer { browser.dismiss() }
        browser.show()
        let search = searchField(browser)
        let web = descendants(browser.panel.contentView!).compactMap { $0 as? WKWebView }.first!
        browser.panel.makeFirstResponder(web)
        let page = URL(string: "https://www.example.com/docs?q=1")!
        web.loadHTMLString("<p>Hi</p>", baseURL: page)
        for _ in 0..<100 where search.stringValue != "example.com" {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(search.stringValue, "example.com")
        browser.panel.makeFirstResponder(search)
        XCTAssertEqual(search.stringValue, page.absoluteString)
        browser.panel.makeFirstResponder(web)
        XCTAssertEqual(search.stringValue, "example.com")
    }
}
