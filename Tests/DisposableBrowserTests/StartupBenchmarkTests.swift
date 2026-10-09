import AppKit
import WebKit
import XCTest
@testable import DisposableBrowser

/// Measures how fast the panel opens and shows a first page.
/// Runs only with `DISPOSABLE_BROWSER_BENCHMARK=1`, in its own process for cold numbers:
/// `DISPOSABLE_BROWSER_BENCHMARK=1 swift test -c release --filter StartupBenchmarkTests`
final class StartupBenchmarkTests: XCTestCase {
    private func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @MainActor
    private func webView(in browser: BrowserPanel) -> WKWebView {
        func find(_ view: NSView) -> WKWebView? {
            (view as? WKWebView) ?? view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(browser.panel.contentView!)!
    }

    /// Opens the panel and loads a local page, as a search does. Returns the time until the
    /// panel is on screen with focus, and the time until the page has finished loading.
    @MainActor
    private func open(_ browser: BrowserPanel) async throws -> (shown: Double, loaded: Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        browser.show()
        let shown = milliseconds(since: start)
        XCTAssertTrue(browser.panel.isVisible)
        let web = webView(in: browser)
        web.loadHTMLString("<html><body><p>Benchmark</p></body></html>",
                           baseURL: URL(string: "https://benchmark.invalid/"))
        while true {
            let state = try? await web.evaluateJavaScript("document.readyState") as? String
            if state == "complete" && web.url != nil && !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        return (shown, milliseconds(since: start))
    }

    private func report(_ name: String, _ values: [Double]) {
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        print(String(format: "BENCHMARK %@: median %.1f ms, min %.1f ms, max %.1f ms (n=%d)",
                     name, median, sorted.first!, sorted.last!, sorted.count))
    }

    @MainActor
    func testStartup() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISPOSABLE_BROWSER_BENCHMARK"] == "1")
        _ = NSApplication.shared
        let start = DispatchTime.now().uptimeNanoseconds
        let browser = BrowserPanel()
        report("launch: create panel", [milliseconds(since: start)])
        // The app idles in the menu bar between launch and the first shortcut.
        try await Task.sleep(for: .seconds(1))
        let first = try await open(browser)
        report("first open: panel shown", [first.shown])
        report("first open: page loaded", [first.loaded])
        browser.dismiss()
        var shown: [Double] = []
        var loaded: [Double] = []
        for _ in 0..<10 {
            try await Task.sleep(for: .seconds(1))
            let next = try await open(browser)
            shown.append(next.shown)
            loaded.append(next.loaded)
            browser.dismiss()
        }
        report("reopen: panel shown", shown)
        report("reopen: page loaded", loaded)

        // A source app that takes 300 ms to report its selection, as a slow one can.
        var selectionShown: [Double] = []
        for _ in 0..<5 {
            try await Task.sleep(for: .seconds(1))
            let start = DispatchTime.now().uptimeNanoseconds
            browser.show(readingSelection: { _ in
                Thread.sleep(forTimeInterval: 0.3)
                return nil
            })
            XCTAssertTrue(browser.panel.isVisible)
            selectionShown.append(milliseconds(since: start))
            browser.dismiss()
        }
        report("open with 300 ms selection read: panel shown", selectionShown)
    }
}
