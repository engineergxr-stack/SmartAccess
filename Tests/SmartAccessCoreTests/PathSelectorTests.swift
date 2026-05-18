import XCTest
@testable import SmartAccessCore

final class PathSelectorTests: XCTestCase {

    func testPrefersDirectOverBackupOverRelay() {
        let direct = ConnectivityPath(id: "p1", kind: .directDomain,
                                      baseURL: URL(string: "https://api-sg.example.com")!,
                                      endpointId: "api-sg", priority: 1)
        let backup = ConnectivityPath(id: "p2", kind: .backupDomain,
                                      baseURL: URL(string: "https://api-hk.example.com")!,
                                      endpointId: "api-hk", priority: 2)
        let relay  = ConnectivityPath(id: "p3", kind: .relay,
                                      baseURL: URL(string: "https://gateway-hk.example.com")!,
                                      endpointId: "relay-hk", priority: 3)

        let endpoints: [String: SAEndpoint] = [
            "api-sg":   .init(id: "api-sg",   url: direct.baseURL, kind: .http, role: .direct, priority: 1),
            "api-hk":   .init(id: "api-hk",   url: backup.baseURL, kind: .http, role: .backup, priority: 2),
            "relay-hk": .init(id: "relay-hk", url: relay.baseURL,  kind: .http, role: .relay,  priority: 3),
        ]
        var states = [String: SAEndpointState]()
        for id in endpoints.keys {
            var s = SAEndpointState()
            s.recordLatency(100)
            s.consecutiveSuccesses = 3
            states[id] = s
        }

        let chosen = PathSelector().selectBest(
            candidates: [direct, backup, relay],
            endpointStates: states,
            endpointsById: endpoints,
            current: nil
        )
        XCTAssertEqual(chosen?.id, "p1")
    }

    func testSkipsBreakerOpen() {
        let direct = ConnectivityPath(id: "p1", kind: .directDomain,
                                      baseURL: URL(string: "https://a.example.com")!,
                                      endpointId: "a", priority: 1)
        let backup = ConnectivityPath(id: "p2", kind: .backupDomain,
                                      baseURL: URL(string: "https://b.example.com")!,
                                      endpointId: "b", priority: 2)
        let endpoints: [String: SAEndpoint] = [
            "a": .init(id: "a", url: direct.baseURL, kind: .http, role: .direct, priority: 1),
            "b": .init(id: "b", url: backup.baseURL, kind: .http, role: .backup, priority: 2),
        ]
        var sA = SAEndpointState()
        sA.breakerOpenUntil = Date().addingTimeInterval(60)
        var sB = SAEndpointState()
        sB.recordLatency(100); sB.consecutiveSuccesses = 2

        let states = ["a": sA, "b": sB]

        let chosen = PathSelector().selectBest(
            candidates: [direct, backup],
            endpointStates: states,
            endpointsById: endpoints,
            current: nil
        )
        XCTAssertEqual(chosen?.id, "p2")
    }
}
