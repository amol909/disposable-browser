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
           let url = URL(string: "https://" + text), url.user == nil,
           let host = url.host, Self.isBareHost(host) {
            return url
        }
        return searchURL(for: text)
    }

    /// True for a dotted name with a letter top-level label (or punycode), or an IPv4 address.
    /// Numbers ("3.14"), versions ("v1.2"), and emails stay searches.
    private static func isBareHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, !labels.contains(where: \.isEmpty), let last = labels.last else { return false }
        if labels.count == 4, labels.allSatisfy({ $0.count <= 3 && $0.allSatisfy(\.isASCIIDigit) }) { return true }
        return last.hasPrefix("xn--") || (last.count > 1 && last.allSatisfy(\.isLetter))
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
