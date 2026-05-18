import XCTest
@testable import SmartAccessCore

final class EndpointManagerTests: XCTestCase {

    func testBreakerOpensAfterFailures() async {
        let log = SALog(OSLoggerSink(minLevel: .warn))
        let mgr = EndpointManager(
            circuitBreakerConfig: CircuitBreakerConfig(failureThreshold: 2, openSeconds: 60),
            log: log
        )
        let ep = SAEndpoint(id: "a",
                            url: URL(string: "https://a.example.com")!,
                            kind: .http, role: .direct, priority: 1)
        await mgr.setEndpoints([ep])

        await mgr.recordProbe(endpointId: "a", success: false, latencyMs: nil, errorCode: "tcp.refused")
        var s = await mgr.state(of: "a")!
        XCTAssertFalse(s.isBreakerOpen)

        await mgr.recordProbe(endpointId: "a", success: false, latencyMs: nil, errorCode: "tcp.refused")
        s = await mgr.state(of: "a")!
        XCTAssertTrue(s.isBreakerOpen)

        await mgr.recordProbe(endpointId: "a", success: true, latencyMs: 100, errorCode: nil)
        s = await mgr.state(of: "a")!
        XCTAssertFalse(s.isBreakerOpen)
    }
}
