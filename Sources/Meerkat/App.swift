import AppKit
import ApplicationServices
import Combine
import SwiftUI
import KeyboardShortcuts
import BrowserCore

extension KeyboardShortcuts.Name {
    static let toggleBrowser = Self("toggleBrowser")
    static let searchSelection = Self("searchSelection")
}

struct SettingsView: View {
    @AppStorage("searchEngine") private var engine = SearchEngine.google.rawValue
    @AppStorage("searchSelectionOnOpen") private var searchSelectionOnOpen = false
    @AppStorage("browserViewMode") private var viewMode = "Mobile"
    @AppStorage(ClipboardSelection.settingKey) private var copyFallback = false
    @State private var hasAccess = AXIsProcessTrusted()
    /// macOS posts this when the Accessibility list changes. The trust value updates a moment
    /// later, so the check waits briefly.
    private let accessChanged = DistributedNotificationCenter.default()
        .publisher(for: Notification.Name("com.apple.accessibility.api"))
        .delay(for: .milliseconds(250), scheduler: RunLoop.main)
    /// Also checks when the person comes back from System Settings, in case the change was missed.
    private let appActivated = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if #available(macOS 26.0, *) {
                controls.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
            } else {
                controls.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            Text("Allow Meerkat in System Settings → Privacy & Security → Accessibility. If the status shows not allowed while the switch there is on, remove and re-add the app. Some apps do not expose selected text; without a selection, opening falls back to manual search.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Closing discards the page, not cookies or logins. This is not private browsing.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 480)
    }

    /// The app icon from the bundle (AppIcon.icns), the name, and the version.
    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Meerkat").font(.title2.weight(.semibold))
                Text("A quick look at the web, then back to work.")
                    .foregroundStyle(.secondary)
                // A build that is not an app bundle (swift run) has no version.
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeyboardShortcuts.Recorder("Show / dismiss browser:", name: .toggleBrowser)
            Toggle("Search selected text when opening", isOn: $searchSelectionOnOpen)
                .toggleStyle(.switch)
            KeyboardShortcuts.Recorder("Search selected text (optional):", name: .searchSelection)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Copy selection when it can't be read", isOn: $copyFallback)
                    .toggleStyle(.switch)
                Text("For apps that hide their text from Accessibility, such as some terminals. Uses a copy that app made in the last 15 seconds (copy-on-select); otherwise sends Copy, then restores your clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Search engine", selection: $engine) {
                ForEach(SearchEngine.allCases, id: \.rawValue) { engine in
                    Text(engine.rawValue).tag(engine.rawValue)
                }
            }
            Picker("Website view", selection: $viewMode) {
                Text("Mobile").tag("Mobile")
                Text("Desktop").tag("Desktop")
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                Label(hasAccess ? "Selected-text access allowed" : "Selected-text access not allowed",
                      systemImage: hasAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(hasAccess ? .green : .orange)
                if !hasAccess {
                    Button("Enable…") { Selection.requestPermission() }
                }
            }
            .onAppear { hasAccess = AXIsProcessTrusted() }
            .onReceive(accessChanged) { _ in hasAccess = AXIsProcessTrusted() }
            .onReceive(appActivated) { _ in hasAccess = AXIsProcessTrusted() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var browser: BrowserPanel!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "Meerkat", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Meerkat")
        let quitItem = appMenu.addItem(withTitle: "Quit Meerkat", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        browser = BrowserPanel()
        ClipboardSelection.startWatching()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MeerkatGlyph.menuBarImage()
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Browser", action: #selector(openBrowser), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Meerkat", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        // Key down opens without waiting for the person to release the keys.
        KeyboardShortcuts.onKeyDown(for: .toggleBrowser) { [weak self] in self?.toggleBrowser() }
        KeyboardShortcuts.onKeyDown(for: .searchSelection) { [weak self] in self?.searchSelection() }
        if KeyboardShortcuts.getShortcut(for: .toggleBrowser) == nil { openSettings() }
    }

    private static let accessNotice = "Enable Accessibility access from Settings to search selected text."

    private func toggleBrowser() {
        let action = BrowserShortcut.action(
            isVisible: browser.panel.isVisible,
            searchSelection: UserDefaults.standard.bool(forKey: "searchSelectionOnOpen"),
            hasAccess: AXIsProcessTrusted()
        )
        switch action {
        case .dismiss: browser.dismiss()
        case .open: browser.show()
        case .needsAccess: browser.show(notice: Self.accessNotice)
        case .openWithSelection:
            guard let app = sourceApp() else {
                Selection.log.notice("read skipped: Meerkat is the frontmost app")
                browser.show()
                return
            }
            browser.show(readingSelection: { Selection.read(from: app, handoff: $0) })
        }
    }

    private func searchSelection() {
        guard let app = sourceApp() else {
            browser.show(notice: "Select text in another app, then use the selection shortcut.")
            return
        }
        guard AXIsProcessTrusted() else {
            browser.show(notice: Self.accessNotice)
            return
        }
        browser.show(readingSelection: { Selection.read(from: app, handoff: $0) },
                     otherwise: "No readable selection. Type your search instead.")
    }

    /// The frontmost app, unless it is this app (the panel does not activate it).
    private func sourceApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    @objc private func openBrowser() { browser.show() }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Meerkat Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

@main
enum MeerkatApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
