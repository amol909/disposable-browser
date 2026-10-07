import Foundation

public enum SearchEngine: String, CaseIterable {
    case google = "Google"
    case duckDuckGo = "DuckDuckGo"

    public func searchURL(for query: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = self == .google ? "www.google.com" : "duckduckgo.com"
        components.path = self == .google ? "/search" : "/"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // Search engines decode query strings as forms, where an unescaped + means space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    public func destination(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text),
           let scheme = url.scheme?.lowercased(),
           ["https", "http"].contains(scheme),
           let host = url.host, !host.isEmpty {
            return url
        }
        // Bare domains are convenient; other input (including custom schemes) is a search.
        if !text.contains(where: { $0.isWhitespace }), !text.contains("://"),
           let url = URL(string: "https://" + text),
           let host = url.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") {
            return url
        }
        return searchURL(for: text)
    }
}
