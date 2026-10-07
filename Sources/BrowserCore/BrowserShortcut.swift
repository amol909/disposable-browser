import Foundation

public enum BrowserShortcut: Equatable {
    case dismiss
    case open(query: String?)

    /// Evaluate selection only for an opted-in opening, before the caller takes focus.
    public static func action(isVisible: Bool, searchSelection: Bool,
                              readSelection: () -> String?) -> Self {
        if isVisible { return .dismiss }
        guard searchSelection, let selection = readSelection() else { return .open(query: nil) }
        let query = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        return .open(query: query.isEmpty ? nil : query)
    }
}
