import AppKit
import WebKit
import BrowserCore

final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class BrowserPanel: NSObject, WKNavigationDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSToolbarDelegate {
    let panel: PeekPanel
    private let address = NSSearchField()
    private let back = NSButton()
    private let external = NSButton()
    private let headerItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("browserHeader"))
    private var addressWidth: NSLayoutConstraint?
    private let message = NSTextField(labelWithString: "")
    private let content = NSView()
    private let emptyState: NSView
    private var messageHeight: NSLayoutConstraint!
    private var messageTop: NSLayoutConstraint!
    private var contentTop: NSLayoutConstraint!
    private var navigationObservers: [NSKeyValueObservation] = []
    private var webView: WKWebView?
    private var eventMonitor: Any?
    private var previousApp: NSRunningApplication?
    var engine: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .google
    }
    private var userAgent: String? {
        guard UserDefaults.standard.string(forKey: "browserViewMode") != "Desktop" else { return nil }
        return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
    }

    override init() {
        panel = PeekPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 720),
                          styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                          backing: .buffered, defer: false)
        let emptyContents = NSView()
        emptyState = emptyContents
        super.init()
        panel.title = "Disposable Browser"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.toolbarStyle = .unifiedCompact
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 400)
        panel.delegate = self

        for (button, symbol, label, action) in [
            (back, "chevron.left", "Back", #selector(goBack)),
            (external, "arrow.up.right.square", "Open in Browser", #selector(openExternal))
        ] {
            button.title = ""
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = action
            button.isEnabled = false
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        address.placeholderString = "Search or enter a website"
        address.setAccessibilityLabel("Search or enter a website")
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.delegate = self
        address.target = self
        address.action = #selector(submit)
        address.sendsSearchStringImmediately = false
        address.sendsWholeSearchString = true
        addressWidth = address.widthAnchor.constraint(equalToConstant: panel.frame.width - 216)
        addressWidth?.isActive = true
        headerItem.view = address
        headerItem.autovalidates = false
        let toolbar = NSToolbar(identifier: "browserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = false }
        if #unavailable(macOS 15.0) { toolbar.showsBaselineSeparator = false }
        panel.toolbar = toolbar
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 11)
        message.maximumNumberOfLines = 0
        message.lineBreakMode = .byWordWrapping
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.preferredMaxLayoutWidth = panel.frame.width - 24
        message.isHidden = true
        // One native, window-clipped material covers both titlebar and body.
        // Unlike a body-only glass sheet, this also filters text behind the toolbar.
        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        content.wantsLayer = true
        panel.contentView = root
        for view in [emptyState, message, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let prompt = NSTextField(labelWithString: "A quick look?")
        prompt.font = .systemFont(ofSize: 20, weight: .medium)
        prompt.textColor = .secondaryLabelColor
        prompt.translatesAutoresizingMaskIntoConstraints = false
        emptyContents.addSubview(prompt)
        messageHeight = message.heightAnchor.constraint(equalToConstant: 0)
        messageTop = message.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
        contentTop = content.topAnchor.constraint(equalTo: message.bottomAnchor)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: root.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            prompt.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            prompt.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            messageHeight, messageTop, contentTop,
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        setWaiting(true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w") {
                self.dismiss()
                return nil
            }
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "l" {
                self.panel.makeFirstResponder(self.address)
                self.address.selectText(nil)
                return nil
            }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(updateViewMode),
            name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [headerItem.itemIdentifier, NSToolbarItem.Identifier("back"), NSToolbarItem.Identifier("external")]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == headerItem.itemIdentifier { return headerItem }
        let button: NSButton
        switch identifier.rawValue {
        case "back": button = back
        case "external": button = external
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = button
        item.label = button.toolTip ?? ""
        item.autovalidates = false
        return item
    }

    func windowDidResize(_ notification: Notification) {
        // Reserve native traffic lights and both icons even at the 360pt minimum.
        addressWidth?.constant = panel.frame.width - 216
        message.preferredMaxLayoutWidth = panel.frame.width - 24
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Update before native resize layout so search does not briefly enter overflow.
        addressWidth?.constant = frameSize.width - 216
        message.preferredMaxLayoutWidth = frameSize.width - 24
        return frameSize
    }

    private func showMessage(_ text: String = "") {
        message.stringValue = text
        message.isHidden = text.isEmpty
        messageHeight.isActive = text.isEmpty
        messageTop.constant = text.isEmpty ? 0 : 8
        contentTop.constant = text.isEmpty ? 0 : 8
    }

    private func setWaiting(_ waiting: Bool) {
        emptyState.isHidden = !waiting
        webView?.isHidden = waiting
        content.layer?.backgroundColor = (waiting ? NSColor.clear : .textBackgroundColor).cgColor
        panel.isOpaque = !waiting
        panel.backgroundColor = waiting ? .clear : .windowBackgroundColor
    }

    private func updateNavigation() {
        back.isEnabled = webView?.canGoBack == true
        external.isEnabled = ["http", "https"].contains(webView?.url?.scheme?.lowercased() ?? "")
    }

    @objc private func updateViewMode() {
        // WebKit can report a cleared (nil) override as an empty string.
        guard let web = webView, (web.customUserAgent ?? "") != (userAgent ?? "") else { return }
        web.customUserAgent = userAgent
        // Keep the same webview/data store, URL, and cookies; ask the site to render again.
        if web.url != nil { web.reload() }
    }

    func show(query: String? = nil, notice: String? = nil) {
        if !panel.isVisible {
            let app = NSWorkspace.shared.frontmostApplication
            if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = app }
            position()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let web = WKWebView(frame: content.bounds, configuration: configuration)
            web.customUserAgent = userAgent
            web.autoresizingMask = [.width, .height]
            web.navigationDelegate = self
            content.addSubview(web)
            webView = web
            setWaiting(true)
            navigationObservers = [
                web.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.updateNavigation() }
                },
                web.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.updateNavigation() }
                }
            ]
            address.stringValue = ""
            showMessage(notice ?? "")
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(address)
        address.selectText(nil)
        if let query {
            address.stringValue = query
            // A selected string is always a query, even when it looks like a URL.
            load(engine.searchURL(for: query))
        } else if let notice { showMessage(notice) }
    }

    func dismiss() {
        panel.orderOut(nil)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        navigationObservers.removeAll()
        webView = nil
        setWaiting(true)
        updateNavigation()
        showMessage()
        address.stringValue = ""
        if let app = previousApp, !app.isTerminated { app.activate(options: []) }
        previousApp = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let width = min(panel.frame.width, visible.width - 24)
        let height = min(panel.frame.height, visible.height - 24)
        // Use the right edge of the current screen to leave its center unobstructed.
        panel.setFrame(NSRect(x: visible.maxX - width - 12, y: visible.midY - height / 2,
                              width: width, height: height), display: true)
    }

    @objc private func submit() {
        guard let url = engine.destination(for: address.stringValue) else { return }
        load(url)
    }

    private func load(_ url: URL) {
        setWaiting(false)
        showMessage("Loading…")
        webView?.load(URLRequest(url: url))
    }

    @objc private func goBack() { webView?.goBack() }

    @objc private func openExternal() {
        guard external.isEnabled, let url = webView?.url else { return }
        dismiss()
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        setWaiting(false)
        showMessage("Loading…")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        address.stringValue = webView.url?.absoluteString ?? address.stringValue
        showMessage()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showMessage(error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showMessage(error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            load(url)
        } else {
            decisionHandler(.allow)
        }
    }
}
