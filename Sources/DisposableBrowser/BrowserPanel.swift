import AppKit
import WebKit
import BrowserCore

/// Search field that reports when it is about to gain keyboard focus.
final class AddressField: NSSearchField {
    var willFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        willFocus?()
        return super.becomeFirstResponder()
    }
}

final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class BrowserPanel: NSObject, WKNavigationDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSToolbarDelegate {
    let panel: PeekPanel
    private let address = AddressField()
    private let back = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("back"))
    private let external = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("external"))
    private let headerItem = NSSearchToolbarItem(itemIdentifier: NSToolbarItem.Identifier("browserHeader"))
    private var addressWidth: NSLayoutConstraint!
    /// Window-clipped frosted material behind the waiting state and the page.
    private let root = NSVisualEffectView()
    /// Soft blur behind the macOS 26 glass toolbar, standing in for a scroll edge effect.
    private let toolbarEdge = NSVisualEffectView()
    private let message = NSTextField(labelWithString: "")
    private let banner: NSView
    private let progress = NSView()
    private var progressWidth: NSLayoutConstraint!
    private let content = NSView()
    /// While waiting for a search, the panel is only its toolbar (and any notice).
    private var isCollapsed = true
    /// Expanded height, kept across lookups and updated when the person resizes the page.
    private var expandedHeight: CGFloat = 720
    private var navigationObservers: [NSKeyValueObservation] = []
    /// The page, or while hidden, the prepared webview for the next lookup.
    private var webView: WKWebView?
    /// Counts selection reads, so only the latest read for a visible panel is used.
    private var selectionRead = 0
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
        banner = Self.makeBanner(around: message)
        super.init()
        panel.title = "Disposable Browser"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.toolbarStyle = .unifiedCompact
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        // Native image items let macOS 26 draw Liquid Glass buttons (bordered buttons before 26).
        for (item, symbol, label, action) in [
            (back, "chevron.backward", "Back", #selector(goBack)),
            (external, "safari", "Open in Browser", #selector(openExternal))
        ] {
            item.image = Self.toolbarIcon(symbol, label: label)
            item.label = label
            item.toolTip = label
            item.isBordered = true
            item.target = self
            item.action = action
            item.autovalidates = false
            item.isEnabled = false
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
        address.willFocus = { [weak self] in self?.showAddress(editing: true) }
        address.focusRingType = .none
        headerItem.searchField = address
        headerItem.resignsFirstResponderWithCancel = false
        headerItem.preferredWidthForSearchField = Self.addressWidth(for: panel.frame.width)
        // The preferred width alone does not shrink the field, which pushes the icons into overflow.
        addressWidth = address.widthAnchor.constraint(equalToConstant: Self.addressWidth(for: panel.frame.width))
        addressWidth.isActive = true
        headerItem.autovalidates = false
        let toolbar = NSToolbar(identifier: "browserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = false }
        if #unavailable(macOS 15.0) { toolbar.showsBaselineSeparator = false }
        panel.toolbar = toolbar
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.alignment = .center
        message.maximumNumberOfLines = 0
        message.lineBreakMode = .byWordWrapping
        // Wraps at preferredMaxLayoutWidth; stays below window-size priority so it never widens the panel.
        message.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(490), for: .horizontal)
        message.preferredMaxLayoutWidth = Self.messageWidth(for: panel.frame.width)
        banner.isHidden = true
        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progress.alphaValue = 0
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        panel.contentView = root
        toolbarEdge.material = .headerView
        toolbarEdge.blendingMode = .withinWindow
        toolbarEdge.state = .followsWindowActiveState
        toolbarEdge.maskImage = NSImage(size: NSSize(width: 1, height: 64), flipped: false) { rect in
            // Opaque under the toolbar, fading out toward the page like the soft system edge.
            NSGradient(colors: [.clear, .black], atLocations: [0, 0.4], colorSpace: .deviceRGB)?.draw(in: rect, angle: 90)
            return true
        }
        content.wantsLayer = true
        for view in [content, toolbarEdge, progress, banner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        // On macOS 26 the page scrolls under the glass toolbar; earlier toolbars stay opaque.
        let pageTop: NSLayoutYAxisAnchor
        if #available(macOS 26.0, *) { pageTop = root.topAnchor } else { pageTop = root.safeAreaLayoutGuide.topAnchor }
        progressWidth = progress.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: pageTop),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toolbarEdge.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarEdge.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 16),
            toolbarEdge.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarEdge.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            progress.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
            progressWidth,
            banner.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            banner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12)
        ])
        setWaiting(true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            // Escape first cancels unfinished input-method text, such as Japanese composition.
            let composing = (self.panel.firstResponder as? NSTextView)?.hasMarkedText() == true
            if (event.keyCode == 53 && !composing) || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w") {
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
        // The notification arrives on the thread that changed a default; the webview is main-only.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: UserDefaults.standard, queue: nil) { [weak self] _ in
            guard Thread.isMainThread else {
                DispatchQueue.main.async { self?.updateViewMode() }
                return
            }
            MainActor.assumeIsolated { self?.updateViewMode() }
        }
        DispatchQueue.main.async { [weak self] in self?.warmUp() }
    }

    /// Does the first-use work of opening once after launch, so the first opening is as fast
    /// as later ones: the first layout, the search field's text editor, and the first webview.
    private func warmUp() {
        guard !panel.isVisible else { return }
        panel.layoutIfNeeded()
        _ = panel.fieldEditor(true, for: address)
        prepareWebView()
    }

    /// Wraps the notice label in a floating glass (macOS 26+) or material capsule.
    private static func makeBanner(around label: NSTextField) -> NSView {
        let padded = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: padded.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -7),
            label.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -14)
        ])
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 14
            glass.contentView = padded
            background = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 14
            material.layer?.masksToBounds = true
            material.addSubview(padded)
            background = material
        }
        // Size the background from the label; glass does not size itself from its content view.
        padded.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            padded.topAnchor.constraint(equalTo: background.topAnchor),
            padded.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            padded.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            padded.trailingAnchor.constraint(equalTo: background.trailingAnchor)
        ])
        return background
    }

    /// Draws a symbol smaller inside a fixed template canvas. The toolbar applies its own
    /// symbol size, which otherwise fills most of the glass circle.
    private static func toolbarIcon(_ symbol: String, label: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration) else { return nil }
        let canvas = NSSize(width: 20, height: 20)
        let icon = NSImage(size: canvas, flipped: false) { rect in
            let origin = NSPoint(x: (rect.width - glyph.size.width) / 2, y: (rect.height - glyph.size.height) / 2)
            glyph.draw(in: NSRect(origin: origin, size: glyph.size))
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = label
        return icon
    }

    /// Address width that reserves native traffic lights and both icons, even at the 360pt minimum.
    private static func addressWidth(for panelWidth: CGFloat) -> CGFloat { panelWidth - 190 }

    /// Link schemes handed to their system app when clicked. Other custom schemes stay blocked.
    private static let externalSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio"]

    /// Notice text width inside the banner and its window margins.
    private static func messageWidth(for panelWidth: CGFloat) -> CGFloat { panelWidth - 52 }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [back.itemIdentifier, headerItem.itemIdentifier, external.itemIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        [back, headerItem, external].first { $0.itemIdentifier == identifier }
    }

    func windowDidResize(_ notification: Notification) {
        resizeChrome(to: panel.frame.size)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Update before native resize layout so search does not briefly enter overflow.
        resizeChrome(to: frameSize)
        return frameSize
    }

    private func resizeChrome(to size: NSSize) {
        headerItem.preferredWidthForSearchField = Self.addressWidth(for: size.width)
        addressWidth.constant = Self.addressWidth(for: size.width)
        message.preferredMaxLayoutWidth = Self.messageWidth(for: size.width)
        updateProgress()
        updateInsets()
    }

    /// Tells the page which top area the toolbar covers, so WebKit keeps fixed headers visible.
    private func updateInsets() {
        guard #available(macOS 26.0, *), let web = webView else { return }
        let top = root.safeAreaInsets.top
        if web.obscuredContentInsets.top != top {
            web.obscuredContentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        }
    }

    private func updateProgress() {
        let loading = webView?.isLoading == true && !isCollapsed
        let fraction = loading ? max(0.1, webView?.estimatedProgress ?? 0) : 1
        progressWidth.constant = root.bounds.width * fraction
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            progress.animator().alphaValue = loading ? 1 : 0
        }
    }

    /// Shows the full URL while editing and only the host while browsing, as Safari does.
    private func showAddress(editing: Bool) {
        guard let url = webView?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        guard !editing, let host = url.host(), !host.isEmpty else {
            address.stringValue = url.absoluteString
            return
        }
        address.stringValue = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        showAddress(editing: false)
    }

    private func showMessage(_ text: String = "") {
        message.stringValue = text
        banner.isHidden = text.isEmpty
        // A collapsed bar grows or shrinks to fit the notice.
        if isCollapsed && panel.isVisible { resizePanel(height: collapsedHeight(), animated: true) }
    }

    /// Height of the titlebar and toolbar row.
    private var toolbarHeight: CGFloat { panel.frame.height - panel.contentLayoutRect.height }

    private func collapsedHeight() -> CGFloat {
        guard !banner.isHidden else { return toolbarHeight }
        root.layoutSubtreeIfNeeded()
        return toolbarHeight + banner.fittingSize.height + 20
    }

    /// Resizes the panel with its top edge fixed, so the bar grows down into the page.
    private func resizePanel(height: CGFloat, animated: Bool) {
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        if let visible = panel.screen?.visibleFrame, frame.minY < visible.minY + 12 {
            frame.origin.y = min(visible.minY + 12, visible.maxY - height)
        }
        // Collapsed, only the width can change; expanded, keep a usable page height.
        panel.minSize = NSSize(width: 360, height: isCollapsed ? height : 400)
        panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                               height: isCollapsed ? height : CGFloat.greatestFiniteMagnitude)
        guard animated, panel.isVisible, frame != panel.frame,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        let web = isCollapsed ? nil : webView
        if let web { pinPage(web, toPanelHeight: frame.height) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.1, 0.1, 1)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let web, web === self.webView else { return }
                web.autoresizingMask = [.width, .height]
                web.frame = self.content.bounds
            }
        })
    }

    /// Gives the page its final size and pins it to the top, so it lays out once
    /// instead of on every animation frame, and not at the collapsed bar's size.
    private func pinPage(_ web: WKWebView, toPanelHeight height: CGFloat) {
        root.layoutSubtreeIfNeeded()
        let pageHeight = height - (root.bounds.height - content.frame.height)
        web.autoresizingMask = [.width, .minYMargin]
        web.frame = NSRect(x: 0, y: content.bounds.height - pageHeight,
                           width: content.bounds.width, height: pageHeight)
    }

    private var expandedPanelHeight: CGFloat {
        min(expandedHeight, (panel.screen?.visibleFrame.height ?? expandedHeight) - 24)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if isCollapsed {
            // A narrower bar can wrap the notice onto more lines.
            resizePanel(height: collapsedHeight(), animated: false)
        } else {
            expandedHeight = panel.frame.height
        }
    }

    private func setWaiting(_ waiting: Bool, animated: Bool = true) {
        let changed = waiting != isCollapsed
        isCollapsed = waiting
        if #available(macOS 26.0, *) { toolbarEdge.isHidden = waiting } else { toolbarEdge.isHidden = true }
        webView?.isHidden = waiting
        content.layer?.backgroundColor = (waiting ? NSColor.clear : .textBackgroundColor).cgColor
        panel.isOpaque = !waiting
        panel.backgroundColor = waiting ? .clear : .windowBackgroundColor
        guard changed else { return }
        if waiting {
            resizePanel(height: collapsedHeight(), animated: animated)
        } else if animated {
            // Start after the caller's load request, so its main-thread work does not
            // stall the first animation frames.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isCollapsed else { return }
                self.resizePanel(height: self.expandedPanelHeight, animated: true)
            }
        } else {
            resizePanel(height: expandedPanelHeight, animated: false)
        }
    }

    private func updateNavigation() {
        back.isEnabled = webView?.canGoBack == true
        external.isEnabled = ["http", "https"].contains(webView?.url?.scheme?.lowercased() ?? "")
    }

    private func updateViewMode() {
        // WebKit can report a cleared (nil) override as an empty string.
        guard let web = webView, (web.customUserAgent ?? "") != (userAgent ?? "") else { return }
        web.customUserAgent = userAgent
        // Keep the same webview/data store, URL, and cookies; ask the site to render again.
        if web.url != nil { web.reload() }
    }

    /// Creates the hidden webview for the next lookup and starts its web content process,
    /// so opening and the first page load do not wait for WebKit. Runs no navigation, so
    /// the page has no URL and no back history.
    @discardableResult
    private func prepareWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let web = WKWebView(frame: content.bounds, configuration: configuration)
        web.customUserAgent = userAgent
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.isHidden = isCollapsed
        content.addSubview(web)
        webView = web
        navigationObservers = [
            web.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateNavigation() }
            },
            web.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.updateNavigation()
                    if self?.address.currentEditor() == nil { self?.showAddress(editing: false) }
                }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateProgress() }
            },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateProgress() }
            }
        ]
        web.evaluateJavaScript("0")
        return web
    }

    /// Prepares the next webview after the current event, so launch and dismissal stay fast.
    private func prepareWebViewSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            self.prepareWebView()
        }
    }

    /// Places the collapsed bar, sized for `notice`, for a new lookup. Does nothing if visible.
    private func present(notice: String? = nil) {
        guard !panel.isVisible else { return }
        let app = NSWorkspace.shared.frontmostApplication
        if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = app }
        let web = prepareWebView()
        setWaiting(true)
        address.stringValue = ""
        showMessage(notice ?? "")
        position()
        pinPage(web, toPanelHeight: expandedPanelHeight)
    }

    func show(query: String? = nil, notice: String? = nil) {
        selectionRead += 1
        present(notice: notice)
        panel.makeKeyAndOrderFront(nil)
        root.layoutSubtreeIfNeeded()
        updateInsets()
        panel.makeFirstResponder(address)
        address.selectText(nil)
        if let query {
            address.stringValue = query
            // A selected string is always a query, even when it looks like a URL.
            load(engine.searchURL(for: query))
            if let webView { panel.makeFirstResponder(webView) }
        } else if let notice { showMessage(notice) }
    }

    /// Shows the focused bar at once and searches the selection when `read` returns it, or
    /// shows `notice` when it returns nil. `read` runs on a background queue, so a slow source
    /// app cannot delay the panel, and Escape always reaches the panel. `read` gets a handoff
    /// that hides the panel while the source app needs keyboard focus for a typed Copy.
    func show(readingSelection read: @escaping @Sendable (@escaping ClipboardSelection.FocusHandoff) -> String?,
              otherwise notice: String? = nil) {
        show()
        let request = selectionRead
        // An open panel already shows its page address; only a change means the person typed.
        let shownText = address.stringValue
        let handoff: ClipboardSelection.FocusHandoff = { [weak self] toSource in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { self?.handOffFocus(toSource: toSource, request: request) ?? false }
            }
        }
        Selection.queue.async { [weak self] in
            let text = read(handoff)
            DispatchQueue.main.async {
                // A dismissal or a newer opening replaces this read.
                guard let self, self.selectionRead == request, self.panel.isVisible else { return }
                // Text the person typed during the read wins over the selection.
                guard self.address.stringValue == shownText, text != nil || notice != nil else { return }
                self.show(query: text, notice: text == nil ? notice : nil)
            }
        }
    }

    /// Hides the panel so the source app gets keyboard focus back, or shows it focused again.
    /// Returns false if a dismissal or a newer opening replaced the read.
    private func handOffFocus(toSource: Bool, request: Int) -> Bool {
        guard selectionRead == request else { return false }
        if toSource {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(address)
        }
        return true
    }

    func dismiss() {
        selectionRead += 1
        panel.orderOut(nil)
        discardWebView()
        showMessage()
        setWaiting(true, animated: false)
        updateNavigation()
        address.stringValue = ""
        // Return to the source app only if no other app came to the front meanwhile.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let app = previousApp, !app.isTerminated,
           front == nil || front == ProcessInfo.processInfo.processIdentifier {
            app.activate(options: [])
        }
        previousApp = nil
        prepareWebViewSoon()
    }

    private func discardWebView() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        navigationObservers.removeAll()
        webView = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        // A crashed open page would stay blank; load it again.
        if panel.isVisible {
            webView.reload()
            return
        }
        // The system can end the process of an idle prepared webview; prepare a new one.
        discardWebView()
        prepareWebViewSoon()
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
        let height = min(expandedHeight, visible.height - 24)
        let collapsed = collapsedHeight()
        // Use the right edge of the current screen to leave its center unobstructed.
        // The bar sits where the expanded page's top edge will be.
        panel.setFrame(NSRect(x: visible.maxX - width - 12, y: visible.midY + height / 2 - collapsed,
                              width: width, height: collapsed), display: true)
        resizePanel(height: collapsed, animated: false)
    }

    @objc private func submit() {
        guard let url = engine.destination(for: address.stringValue) else { return }
        load(url)
        // Hand keys to the page, as Safari does; ending the edit shows the short address.
        if let webView { panel.makeFirstResponder(webView) }
    }

    private func load(_ url: URL) {
        setWaiting(false)
        showMessage()
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
        showMessage()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if address.currentEditor() == nil { showAddress(editing: false) }
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
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        guard let url = navigationAction.request.url, ["http", "https", "about"].contains(scheme) else {
            decisionHandler(.cancel)
            // A clicked mail or phone link goes to its app; pages cannot open other apps on their own.
            if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated,
               Self.externalSchemes.contains(scheme) {
                NSWorkspace.shared.open(url)
            }
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
