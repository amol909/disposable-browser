import Foundation

public enum BrowserShortcut: Equatable {
    case dismiss
    case open(query: String?)
    /// Selection search is on, but the app lacks Accessibility access to read it.
    case needsAccess

    /// Longest query taken from a selection; longer selections are cut at a word boundary.
    public static let maxQueryLength = 500

    /// Evaluate selection only for an opted-in opening, before the caller takes focus.
    public static func action(isVisible: Bool, searchSelection: Bool, hasAccess: Bool,
                              readSelection: () -> String?) -> Self {
        if isVisible { return .dismiss }
        guard searchSelection else { return .open(query: nil) }
        guard hasAccess else { return .needsAccess }
        return .open(query: readSelection().flatMap(query(fromSelection:)))
    }

    /// Turns selected text into one search line: whitespace runs (including line breaks)
    /// become single spaces, and very long selections are shortened. Returns nil if empty.
    public static func query(fromSelection text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return nil }
        let line = words.joined(separator: " ")
        guard line.count > maxQueryLength else { return line }
        let cut = line.prefix(maxQueryLength)
        // Prefer the last whole word; a single very long word is cut as is.
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) }
        return String(cut)
    }
}
