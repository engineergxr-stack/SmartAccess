import XCTest
@testable import SmartAccessCore

final class HTTPParserTests: XCTestCase {

    func testContentLengthBody() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello"
        let data = raw.data(using: .utf8)!
        let parsed = try HTTPParser.parse(data)
        XCTAssertEqual(parsed.statusCode, 200)
        XCTAssertEqual(parsed.reasonPhrase, "OK")
        XCTAssertEqual(parsed.body, "hello".data(using: .utf8))
    }

    func testChunkedBody() throws {
        // "Hello, World!" 分两块
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7\r\nHello, \r\n6\r\nWorld!\r\n0\r\n\r\n"
        let data = raw.data(using: .utf8)!
        let parsed = try HTTPParser.parse(data)
        XCTAssertEqual(parsed.statusCode, 200)
        XCTAssertEqual(parsed.body, "Hello, World!".data(using: .utf8))
    }

    func testMalformedStatusLineThrows() {
        let raw = "GIBBERISH\r\n\r\n"
        XCTAssertThrowsError(try HTTPParser.parse(raw.data(using: .utf8)!))
    }

    func testIncompleteHeadersThrows() {
        let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n"
        XCTAssertThrowsError(try HTTPParser.parse(raw.data(using: .utf8)!)) { err in
            XCTAssertEqual(err as? HTTPParser.ParseError, .incompleteHeaders)
        }
    }

    func testBodyTooLargeWithContentLength() {
        let raw = "HTTP/1.1 200 OK\r\nContent-Length: 9999999999\r\n\r\n"
        XCTAssertThrowsError(try HTTPParser.parse(raw.data(using: .utf8)!, maxBodyBytes: 1024))
    }
}
