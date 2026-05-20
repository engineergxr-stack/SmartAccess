import XCTest
@testable import SmartAccessCore

/// 这一组测试就是为了保证：再怎么改 SAMetricsEvent，敏感字段都进不了日志。
/// 一旦有人不小心把 token / cookie / authorization 写进 event payload，这里要 fail。
final class RedactionFilterTests: XCTestCase {

    func testBannedFieldNamesRejected() {
        XCTAssertFalse(RedactionFilter.isFieldNameAllowed("Authorization"))
        XCTAssertFalse(RedactionFilter.isFieldNameAllowed("X-Auth-Token"))
        XCTAssertFalse(RedactionFilter.isFieldNameAllowed("cookie"))
        XCTAssertFalse(RedactionFilter.isFieldNameAllowed("CSRF-Token"))
        XCTAssertFalse(RedactionFilter.isFieldNameAllowed("api_key"))
        XCTAssertFalse(RedactionFilter.isFieldNameAllowed("user_password"))
        XCTAssertFalse(RedactionFilter.isFieldNameAllowed("session_id"))

        XCTAssertTrue(RedactionFilter.isFieldNameAllowed("endpoint_id"))
        XCTAssertTrue(RedactionFilter.isFieldNameAllowed("latency_ms"))
        XCTAssertTrue(RedactionFilter.isFieldNameAllowed("stage"))
    }

    func testURLSanitizedStripsQueryAndUserInfo() {
        let url = URL(string: "https://alice:secret@api.example.com:443/v1/orders?token=abc123&page=2#section")!
        let s = RedactionFilter.sanitize(url: url)
        XCTAssertFalse(s.contains("token"))
        XCTAssertFalse(s.contains("abc123"))
        XCTAssertFalse(s.contains("alice"))
        XCTAssertFalse(s.contains("secret"))
        XCTAssertFalse(s.contains("section"))
        XCTAssertTrue(s.contains("api.example.com"))
        XCTAssertTrue(s.contains("/v1/orders"))
    }

    func testCustomerProvidedFieldsAreFilteredAndTruncated() {
        let raw = [
            "endpoint_id": "api-sg",
            "Authorization": "Bearer xxx",      // 必须丢
            "x-api-key": "sk-abcd",              // 必须丢
            "trace_id": String(repeating: "a", count: 1024) // 必须截断
        ]
        let out = RedactionFilter.sanitize(fields: raw)
        XCTAssertNotNil(out["endpoint_id"])
        XCTAssertNil(out["Authorization"])
        XCTAssertNil(out["x-api-key"])
        XCTAssertNotNil(out["trace_id"])
        XCTAssertLessThanOrEqual(out["trace_id"]!.count, 260)
    }

    func testProbeResultEventOnlyExposesSafeFields() {
        let event: SAMetricsEvent = .probeResult(.init(
            pathId: "directDomain:api-sg",
            endpointId: "api-sg",
            kind: .directDomain,
            success: false,
            stage: .tls,
            latencyMs: 1234,
            errorCode: "tls.handshake_failed"
        ))
        let log = SADiagnosticLog.from(event)
        XCTAssertEqual(log.event, "probe.result")
        XCTAssertEqual(log.fields["path_id"], "directDomain:api-sg")
        XCTAssertEqual(log.fields["stage"], "tls")
        XCTAssertEqual(log.fields["error_code"], "tls.handshake_failed")
        // 任何含敏感关键字的 key 都不能出现
        for key in log.fields.keys {
            XCTAssertTrue(RedactionFilter.isFieldNameAllowed(key), "leaked key: \(key)")
        }
    }
}
