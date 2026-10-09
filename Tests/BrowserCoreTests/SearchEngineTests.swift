import Foundation
import XCTest
@testable import BrowserCore

final class SearchEngineTests: XCTestCase {
    func testQueryRemainsOneParameter() throws {
        let query = "café & cats + dogs?# 🐈"
        for engine in SearchEngine.allCases {
            let components = try XCTUnwrap(URLComponents(url: engine.searchURL(for: query), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: query)])
            XCTAssertEqual(components.scheme, "https")
        }
        XCTAssertEqual(SearchEngine.google.searchURL(for: "hello").absoluteString, "https://www.google.com/search?q=hello")
        XCTAssertEqual(SearchEngine.duckDuckGo.searchURL(for: "hello").absoluteString, "https://duckduckgo.com/?q=hello")
    }

    func testLiteralPlusSurvivesFormDecoding() throws {
        for engine in SearchEngine.allCases {
            let components = try XCTUnwrap(URLComponents(url: engine.searchURL(for: "C++ & 50%"), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.percentEncodedQuery, "q=C%2B%2B%20%26%2050%25")
        }
    }

    func testAddressAndSearchBoundaries() {
        XCTAssertNil(SearchEngine.google.destination(for: " \n "))
        XCTAssertEqual(SearchEngine.google.destination(for: " example.com/docs?q=one ")?.absoluteString, "https://example.com/docs?q=one")
        XCTAssertEqual(SearchEngine.google.destination(for: "http://localhost:8000/a")?.absoluteString, "http://localhost:8000/a")
        XCTAssertEqual(SearchEngine.google.destination(for: "192.168.1.1")?.absoluteString, "https://192.168.1.1")
        XCTAssertEqual(SearchEngine.google.destination(for: "xn--bcher-kva.example")?.absoluteString, "https://xn--bcher-kva.example")
        for query in ["what is example.com", "javascript:alert(1)", "file:///tmp/test", "https://", "hello",
                      "3.14", "v1.2", "1.2.3", "user@example.com"] {
            XCTAssertEqual(SearchEngine.google.destination(for: query), SearchEngine.google.searchURL(for: query))
        }
    }
}
