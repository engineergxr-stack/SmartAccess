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

        var selector = PathSelector()
        let chosen = selector.selectBest(
            candidates: [direct, backup, relay],
            endpointStates: states,
            endpointsById: endpoints,
            current: nil
        )
        XCTAssertEqual(chosen.path?.id, "p1")
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

        var selector = PathSelector()
        let chosen = selector.selectBest(
            candidates: [direct, backup],
            endpointStates: states,
            endpointsById: endpoints,
            current: nil
        )
        XCTAssertEqual(chosen.path?.id, "p2")
    }

    /// V2: 所有 direct/backup 都死在 dns 阶段时，Relay 必须被立刻提到首选。
    func testRelayPromotedWhenAllDirectsDeadOnDNS() {
        let direct = ConnectivityPath(id: "p1", kind: .directDomain,
                                      baseURL: URL(string: "https://a.example.com")!,
                                      endpointId: "a", priority: 1)
        let relay  = ConnectivityPath(id: "p2", kind: .relay,
                                      baseURL: URL(string: "https://gw.example.com")!,
                                      endpointId: "gw", priority: 3)
        let endpoints: [String: SAEndpoint] = [
            "a":  .init(id: "a",  url: direct.baseURL, kind: .http, role: .direct, priority: 1),
            "gw": .init(id: "gw", url: relay.baseURL,  kind: .http, role: .relay,  priority: 3),
        ]

        var sA = SAEndpointState()
        sA.consecutiveFailures = 2
        sA.lastFailureAt = Date()
        sA.lastErrorStage = .dns
        sA.breakerOpenUntil = Date().addingTimeInterval(-1) // 已恢复，但 lastErrorStage 还是 dns

        var sGW = SAEndpointState()
        sGW.recordLatency(180); sGW.consecutiveSuccesses = 2

        // 注意：breakerOpenUntil 在过去，因此 A 仍然在候选里。我们要测的是「即使 A 在候选里，
        // 但因为最近失败在 dns 阶段，PathSelector 也应该提权 Relay」。
        let states = ["a": sA, "gw": sGW]

        var selector = PathSelector()
        let chosen = selector.selectBest(
            candidates: [direct, relay],
            endpointStates: states,
            endpointsById: endpoints,
            current: nil
        )
        XCTAssertEqual(chosen.path?.id, "p2", "expected relay promoted")
        XCTAssertTrue(chosen.reason.contains("relay_promoted"))
    }
}
