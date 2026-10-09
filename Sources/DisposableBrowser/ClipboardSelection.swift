import AppKit
import CoreGraphics
import os

/// Opt-in fallback for apps that draw their own text and expose no selection to
/// Accessibility (for example GPUI terminals). It uses a fresh copy the app already made
/// (copy-on-select terminals), or else sends Copy, reads it, and restores the clipboard.
/// The watcher runs on the main thread; `copy` runs on `Selection.queue`.
enum ClipboardSelection {
    /// Gives keyboard focus to the source app (true) or back to the panel (false). A typed
    /// ⌘C goes to the window with keyboard focus, so the panel must not have it then.
    /// Returns false when the panel was dismissed and the read is no longer wanted.
    typealias FocusHandoff = @Sendable (_ toSource: Bool) -> Bool

    /// UserDefaults key for the Settings switch; off by default.
    static let settingKey = "copySelectionFallback"
    /// Longest wait for the source app to update the clipboard.
    private static let wait: TimeInterval = 0.3
    /// Time for a typed ⌘C to reach the source app while the panel is hidden.
    private static let keyDelivery: TimeInterval = 0.05
    /// How old a copy made in the source app can be and still count as its selection.
    private static let recentCopy: TimeInterval = 15
    /// The latest clipboard change seen: its count, the frontmost app then, and when.
    /// Only the change count is read, never the contents. Shared by the watcher and `copy`.
    private static let lastChange = OSAllocatedUnfairLock<(count: Int, pid: pid_t?, date: Date)?>(initialState: nil)
    @MainActor private static var watcher: Timer?

    /// Starts noting which app made each clipboard change, so a copy-on-select copy can be
    /// used at once. Polls the change count four times a second.
    @MainActor
    static func startWatching() {
        guard watcher == nil else { return }
        noteChange()
        watcher = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            noteChange()
        }
    }

    private static func noteChange() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChange.withLock({ $0?.count }) else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        lastChange.withLock { $0 = (count, pid, Date()) }
    }

    /// Returns the source app's selection from the clipboard, or nil if it copied nothing.
    static func copy(from application: NSRunningApplication, source: String,
                     handoff: FocusHandoff) -> String? {
        let pasteboard = NSPasteboard.general
        // Catch a change made since the last poll; the source app is still frontmost.
        noteChange()
        if let change = lastChange.withLock({ $0 }), change.pid == application.processIdentifier,
           Date().timeIntervalSince(change.date) < recentCopy,
           let text = pasteboard.string(forType: .string), !text.isEmpty {
            Selection.log.notice("copy \(source, privacy: .public): recent copy from this app, \(text.count) chars")
            return text
        }
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount
        let released = waitForModifierRelease()
        // Pressing the app's own Copy menu item works where synthetic keys are ignored.
        // The menu item works without keyboard focus; a typed ⌘C needs it.
        let method: String
        if pressCopyMenuItem(of: application.processIdentifier) {
            method = "menu"
            waitForChange(of: pasteboard, from: before)
        } else {
            guard handoff(true) else {
                Selection.log.notice("copy \(source, privacy: .public): skipped, panel dismissed")
                return nil
            }
            let sent = sendCopy()
            // The key goes to the window with focus when it is delivered, so the panel
            // can take focus back before the app finishes copying.
            Thread.sleep(forTimeInterval: keyDelivery)
            _ = handoff(false)
            guard sent else {
                Selection.log.notice("copy \(source, privacy: .public): could not send ⌘C")
                return nil
            }
            method = "⌘C key"
            waitForChange(of: pasteboard, from: before)
        }
        guard pasteboard.changeCount != before else {
            // Nothing selected, or the app has no Copy command: the clipboard is untouched.
            Selection.log.notice("copy \(source, privacy: .public): clipboard did not change (\(method, privacy: .public), modifiers released: \(released))")
            return nil
        }
        let text = pasteboard.string(forType: .string)
        restore(saved, to: pasteboard)
        // The restore is not a new copy by the source app.
        let restored = pasteboard.changeCount
        lastChange.withLock { $0 = (restored, nil, Date()) }
        Selection.log.notice("copy \(source, privacy: .public): \(text?.count ?? 0) chars (\(method, privacy: .public))")
        return text
    }

    /// Waits until the clipboard changes, or until the source app had time to copy.
    private static func waitForChange(of pasteboard: NSPasteboard, from count: Int) {
        let deadline = Date().addingTimeInterval(wait)
        while pasteboard.changeCount == count && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Finds the enabled menu item whose shortcut is plain ⌘C (Edit > Copy in any language)
    /// and presses it through Accessibility.
    private static func pressCopyMenuItem(of pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let value = attribute(app, kAXMenuBarAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let menuBar = value as! AXUIElement
        for barItem in children(menuBar) {
            for menu in children(barItem) {
                for item in children(menu) {
                    guard attribute(item, kAXMenuItemCmdCharAttribute) as? String == "C",
                          (attribute(item, kAXMenuItemCmdModifiersAttribute) as? Int) == 0,
                          attribute(item, kAXEnabledAttribute) as? Bool == true else { continue }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        let nodes = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for node in nodes { AXUIElementSetMessagingTimeout(node, 0.5) }
        return nodes
    }

    /// Types ⌘C into the source app; the caller first hands it keyboard focus.
    /// Some apps, such as GPUI apps, ignore keys posted straight to their process, so this
    /// uses the system keyboard path, as a real key press does.
    private static func sendCopy() -> Bool {
        let keyC: CGKeyCode = 8
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// The shortcut fires when its key is released, often while Control, Shift, or Option
    /// is still held. Those keys would turn ⌘C into another shortcut, so wait for them.
    /// Returns false if a modifier was still held when the wait ended.
    private static func waitForModifierRelease() -> Bool {
        let held: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]
        let deadline = Date().addingTimeInterval(0.5)
        while !CGEventSource.flagsState(.hidSystemState).intersection(held).isEmpty {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// Copies every item and type, so images, files, and rich text come back intact.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
