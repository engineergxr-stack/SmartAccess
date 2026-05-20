import Foundation

/// Endpoint 仓库。
///
/// - 维护当前 policy 下的 endpoint 列表 + 每个 endpoint 的运行期状态
/// - V2: 不同 role 用不同熔断参数（direct vs relay）
/// - V2: 维护 half-open probe 时间，让熔断恢复期内的 endpoint 先被探针打一次再放真实流量
actor EndpointManager {

    private(set) var endpoints: [SAEndpoint] = []
    private var states: [String: SAEndpointState] = [:]
    private var directBreaker: CircuitBreakerConfig
    private var relayBreaker: RelayCircuitBreakerConfig
    private let log: SALog

    init(
        circuitBreakerConfig: CircuitBreakerConfig = .default,
        relayBreakerConfig: RelayCircuitBreakerConfig = .default,
        log: SALog
    ) {
        self.directBreaker = circuitBreakerConfig
        self.relayBreaker = relayBreakerConfig
        self.log = log
    }

    func updateBreakerConfig(direct: CircuitBreakerConfig, relay: RelayCircuitBreakerConfig) {
        self.directBreaker = direct
        self.relayBreaker = relay
    }

    func setEndpoints(_ new: [SAEndpoint]) {
        let newIds = Set(new.map(\.id))
        states = states.filter { newIds.contains($0.key) }
        for ep in new where states[ep.id] == nil {
            states[ep.id] = SAEndpointState()
        }
        endpoints = new
        log.debug("endpoint.manager updated count=\(new.count)")
    }

    func state(of endpointId: String) -> SAEndpointState? { states[endpointId] }
    func allStates() -> [String: SAEndpointState] { states }

    func recordProbe(endpointId: String, success: Bool, latencyMs: Int?, errorCode: String?, errorStage: ConnectivityStage? = nil) {
        guard var st = states[endpointId] else { return }
        guard let ep = endpoints.first(where: { $0.id == endpointId }) else { return }

        st.lastProbeAt = Date()
        st.lastErrorCode = errorCode
        st.lastErrorStage = errorStage

        if success {
            if let ms = latencyMs { st.recordLatency(ms) }
            st.lastSuccessAt = Date()
            st.consecutiveFailures = 0
            st.consecutiveSuccesses += 1
            st.breakerOpenUntil = nil
            st.nextHalfOpenProbeAt = nil
        } else {
            st.lastFailureAt = Date()
            st.consecutiveSuccesses = 0
            st.consecutiveFailures += 1

            let isRelay = ep.role == .relay
            let threshold = isRelay ? relayBreaker.failureThreshold : directBreaker.failureThreshold
            let openSeconds = isRelay ? relayBreaker.openSeconds : directBreaker.openSeconds

            if st.consecutiveFailures >= threshold {
                st.breakerOpenUntil = Date().addingTimeInterval(TimeInterval(openSeconds))
                if isRelay {
                    st.nextHalfOpenProbeAt = Date().addingTimeInterval(TimeInterval(openSeconds + relayBreaker.halfOpenProbeIntervalSeconds))
                }
                log.warn("endpoint.breaker_open id=\(endpointId) role=\(ep.role.rawValue) for=\(openSeconds)s")
            }
        }
        states[endpointId] = st
    }

    /// 给指定 endpoint 强制安排一次 half-open probe（用于 PathSelector 决策时主动触发）。
    func markHalfOpenScheduled(endpointId: String, at: Date) {
        states[endpointId]?.nextHalfOpenProbeAt = at
    }

    /// 列出当前需要做 half-open probe 的 endpoint（熔断到期且未做过 probe）。
    func endpointsNeedingHalfOpenProbe(now: Date = Date()) -> [SAEndpoint] {
        endpoints.filter { ep in
            guard let st = states[ep.id] else { return false }
            guard let open = st.breakerOpenUntil else { return false }
            return open <= now &&
                (st.nextHalfOpenProbeAt.map { $0 <= now } ?? true)
        }
    }

    func clearAllBreakers() {
        for id in states.keys {
            states[id]?.breakerOpenUntil = nil
            states[id]?.nextHalfOpenProbeAt = nil
        }
    }
}
