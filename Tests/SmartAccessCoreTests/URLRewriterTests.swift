import XCTest
@testable import SmartAccessCore

final class URLRewriterTests: XCTestCase {

    func testReplacesSchemeHostPortPreservesPathQuery() {
        let original = URL(string: "https://api-sg.example.com:443/v1/orders?limit=20")!
        let base     = URL(string: "https://gateway-hk.example.com")!

        let rewritten = SmartAccessURLRewriter.rewrite(original, withBase: base)
        XCTAssertEqual(rewritten.scheme, "https")
        XCTAssertEqual(rewritten.host, "gateway-hk.example.com")
        XCTAssertEqual(rewritten.path, "/v1/orders")
        XCTAssertEqual(rewritten.query, "limit=20")
    }

    func testKeepsFragment() {
        let original = URL(string: "https://api.example.com/v1#section")!
        let base = URL(string: "https://api2.example.com")!
        let r = SmartAccessURLRewriter.rewrite(original, withBase: base)
        XCTAssertEqual(r.fragment, "section")
    }
}
