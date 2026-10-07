import AppKit
import ApplicationServices
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if #available(macOS 26.0, *) {
                controls.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
            } else {
                controls.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            Text("Allow Disposable Browser in System Settings → Privacy & Security → Accessibility. Some apps do not expose selected text. Without access or a selection, opening falls back to manual search.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Closing discards the page, not cookies or logins. This is not private browsing.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 480)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeyboardShortcuts.Recorder("Show / dismiss browser:", name: .toggleBrowser)
            Toggle("Search selected text when opening", isOn: $searchSelectionOnOpen)
                .toggleStyle(.switch)
            KeyboardShortcuts.Recorder("Search selected text (optional):", name: .searchSelection)
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
            Button("Enable selected-text access…") { Selection.requestPermission() }
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
        let appItem = NSMenuItem(title: "Disposable Browser", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Disposable Browser")
        let quitItem = appMenu.addItem(withTitle: "Quit Disposable Browser", action: #selector(quit), keyEquivalent: "q")
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Disposable Browser")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Browser", action: #selector(openBrowser), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Disposable Browser", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        KeyboardShortcuts.onKeyUp(for: .toggleBrowser) { [weak self] in self?.toggleBrowser() }
        KeyboardShortcuts.onKeyUp(for: .searchSelection) { [weak self] in self?.searchSelection() }
        if KeyboardShortcuts.getShortcut(for: .toggleBrowser) == nil { openSettings() }
    }

    private func toggleBrowser() {
        let action = BrowserShortcut.action(
            isVisible: browser.panel.isVisible,
            searchSelection: UserDefaults.standard.bool(forKey: "searchSelectionOnOpen")
        ) {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            return Selection.read(from: app)
        }
        switch action {
        case .dismiss: browser.dismiss()
        case .open(let query): browser.show(query: query)
        }
    }

    private func searchSelection() {
        // Read from the source app before the panel takes keyboard focus.
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            browser.show(notice: "Select text in another app, then use the selection shortcut.")
            return
        }
        guard AXIsProcessTrusted() else {
            browser.show(notice: "Enable Accessibility access from Settings to search selected text.")
            return
        }
        guard let text = Selection.read(from: app) else {
            browser.show(notice: "No readable selection. Type your search instead.")
            return
        }
        browser.show(query: text)
    }

    @objc private func openBrowser() { browser.show() }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Disposable Browser Settings"
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
enum DisposableBrowser {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
