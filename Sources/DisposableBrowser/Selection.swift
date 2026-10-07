import AppKit
import ApplicationServices
import BrowserCore
import os

/// Reads the selected text of another app through the Accessibility API.
@MainActor
enum Selection {
    /// Longest wait for one Accessibility request, so a hung source app cannot freeze the panel.
    private static let timeout: Float = 0.5
    /// Apps already asked to build their accessibility tree in this session.
    private static var enabledApps: Set<pid_t> = []
    /// Records how each read went, never the selected text itself.
    static let log = Logger(subsystem: "com.amol909.disposable-browser", category: "selection")

    /// Outcome of one Accessibility read.
    private enum Reading {
        case text(String)
        /// The app reports its selection, and nothing is selected.
        case empty
        /// The app does not report a selection at all (for example, apps that draw their own text).
        case unreadable
    }

    /// Returns the source app's selection as a one-line search query, or nil if unreadable.
    static func read(from application: NSRunningApplication) -> String? {
        let source = application.bundleIdentifier ?? "pid \(application.processIdentifier)"
        guard AXIsProcessTrusted() else {
            log.notice("read \(source, privacy: .public): no Accessibility access")
            return nil
        }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, timeout)
        var reading = selectedText(in: app, source: source)
        // Electron and Chromium apps build their tree only when asked. The request is
        // asynchronous inside the app, so retry briefly, once per app.
        if case .unreadable = reading, enableAccessibility(of: app, pid: application.processIdentifier) {
            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 0.1)
                reading = selectedText(in: app, source: source)
                if case .unreadable = reading { continue }
                break
            }
        }
        switch reading {
        case .text(let text): return BrowserShortcut.query(fromSelection: text)
        case .empty: return nil
        case .unreadable:
            // Only when the app cannot report a selection, so an empty selection never sends ⌘C.
            guard UserDefaults.standard.bool(forKey: ClipboardSelection.settingKey) else { return nil }
            return ClipboardSelection.copy(from: application, source: source).flatMap(BrowserShortcut.query(fromSelection:))
        }
    }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Asks an app to expose its accessibility tree. Electron apps honor `AXManualAccessibility`;
    /// Chromium browsers also accept it. Native apps reject it, which is harmless.
    /// Returns true only the first time an app accepts, when a retry can help.
    private static func enableAccessibility(of app: AXUIElement, pid: pid_t) -> Bool {
        guard !enabledApps.contains(pid) else { return false }
        enabledApps.insert(pid)
        enabledApps = enabledApps.filter { NSRunningApplication(processIdentifier: $0) != nil }
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    private static func selectedText(in app: AXUIElement, source: String) -> Reading {
        guard let focused = element(app, kAXFocusedUIElementAttribute) else {
            log.notice("read \(source, privacy: .public): no focused element (\(lastError.rawValue))")
            return .unreadable
        }
        let role = string(focused, kAXRoleAttribute) ?? "?"
        // Native text views expose the selection as plain text.
        if let text = string(focused, kAXSelectedTextAttribute) {
            log.notice("read \(source, privacy: .public): \(role, privacy: .public) selected text, \(text.count) chars")
            return .text(text)
        }
        let selectedError = lastError
        var reportsSelection = selectedError == .success
        // Web content (Safari, Chromium, Electron) keeps a page selection as a text-marker
        // range, often on the web area above the focused element.
        var current: AXUIElement? = focused
        for _ in 0..<12 {
            guard let node = current else { break }
            if let text = markedText(node) {
                log.notice("read \(source, privacy: .public): text marker on \(string(node, kAXRoleAttribute) ?? "?", privacy: .public), \(text.count) chars")
                return .text(text)
            }
            if markerError == .success { reportsSelection = true }
            if string(node, kAXRoleAttribute) == "AXWebArea" { break }
            current = element(node, kAXParentAttribute)
        }
        log.notice("read \(source, privacy: .public): \(role, privacy: .public) \(reportsSelection ? "has an empty selection" : "reports no selection", privacy: .public) (selected text \(selectedError.rawValue), marker \(markerError.rawValue))")
        if reportsSelection { return .empty }
        // Some apps (for example GPUI terminals) report only a window as focused but keep
        // the selection on a text element inside it.
        return descendantSelection(of: focused, source: source)
    }

    /// Searches the focused element's subtree, breadth first and bounded, for a selection.
    private static func descendantSelection(of root: AXUIElement, source: String) -> Reading {
        var queue = [(node: root, depth: 0)]
        var visited = 0
        var roles: [String: Int] = [:]
        var reportsSelection = false
        while !queue.isEmpty && visited < 300 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            roles[string(node, kAXRoleAttribute) ?? "?", default: 0] += 1
            if node != root {
                if let text = string(node, kAXSelectedTextAttribute) {
                    log.notice("read \(source, privacy: .public): descendant selected text, \(text.count) chars")
                    return .text(text)
                }
                if lastError == .success { reportsSelection = true }
                if let text = markedText(node) {
                    log.notice("read \(source, privacy: .public): descendant text marker, \(text.count) chars")
                    return .text(text)
                }
            }
            guard depth < 10, let children = copy(node, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children {
                AXUIElementSetMessagingTimeout(child, timeout)
                queue.append((child, depth + 1))
            }
        }
        let summary = roles.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        log.notice("read \(source, privacy: .public): subtree \(visited) nodes [\(summary, privacy: .public)], \(reportsSelection ? "empty selection" : "no selection support", privacy: .public)")
        return reportsSelection ? .empty : .unreadable
    }

    /// Results of the most recent reads, for the diagnostic log.
    private static var lastError: AXError = .success
    private static var markerError: AXError = .success

    private static func copy(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        lastError = AXUIElementCopyAttributeValue(node, attribute as CFString, &value)
        return lastError == .success ? value : nil
    }

    private static func markedText(_ node: AXUIElement) -> String? {
        guard let range = copy(node, "AXSelectedTextMarkerRange") else {
            markerError = lastError
            return nil
        }
        var value: CFTypeRef?
        markerError = AXUIElementCopyParameterizedAttributeValue(node, "AXStringForTextMarkerRange" as CFString,
                                                                 range, &value)
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Reads a child element and gives it the same short timeout; elements do not inherit it.
    private static func element(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(node, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let child = value as! AXUIElement
        AXUIElementSetMessagingTimeout(child, timeout)
        return child
    }

    private static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        guard let text = copy(node, attribute) as? String, !text.isEmpty else { return nil }
        return text
    }
}
