import Foundation

/// Endpoint 仓库。
///
/// - 维护当前 policy 下的 endpoint 列表，以及每个 endpoint 的运行期状态。
/// - 当 policy 更新时 diff：保留未变 endpoint 的 state；新 endpoint 用空 state；
///   被移除的 endpoint 丢弃。
actor EndpointManager {

    private(set) var endpoints: [SAEndpoint] = []
    private var states: [String: SAEndpointState] = [:]
    private let circuitBreakerConfig: CircuitBreakerConfig
    private let log: SALog

    init(circuitBreakerConfig: CircuitBreakerConfig = .default, log: SALog) {
        self.circuitBreakerConfig = circuitBreakerConfig
        self.log = log
    }

    func setEndpoints(_ new: [SAEndpoint]) {
        let newIds = Set(new.map(\.id))
        // 保留未变 endpoint 的 state，丢弃 stale state
        states = states.filter { newIds.contains($0.key) }
        for ep in new where states[ep.id] == nil {
            states[ep.id] = SAEndpointState()
        }
        endpoints = new
        log.debug("endpoint.manager updated count=\(new.count)")
    }

    func state(of endpointId: String) -> SAEndpointState? { states[endpointId] }
    func allStates() -> [String: SAEndpointState] { states }

    func recordProbe(endpointId: String, success: Bool, latencyMs: Int?, errorCode: String?) {
        guard var st = states[endpointId] else { return }
        st.lastProbeAt = Date()
        st.lastErrorCode = errorCode
        if success {
            if let ms = latencyMs { st.recordLatency(ms) }
            st.lastSuccessAt = Date()
            st.consecutiveFailures = 0
            st.consecutiveSuccesses += 1
            st.breakerOpenUntil = nil
        } else {
            st.lastFailureAt = Date()
            st.consecutiveSuccesses = 0
            st.consecutiveFailures += 1
            if st.consecutiveFailures >= circuitBreakerConfig.failureThreshold {
                st.breakerOpenUntil = Date().addingTimeInterval(TimeInterval(circuitBreakerConfig.openSeconds))
                log.warn("endpoint.breaker_open id=\(endpointId) for=\(circuitBreakerConfig.openSeconds)s")
            }
        }
        states[endpointId] = st
    }

    func clearAllBreakers() {
        for id in states.keys {
            states[id]?.breakerOpenUntil = nil
        }
    }
}
