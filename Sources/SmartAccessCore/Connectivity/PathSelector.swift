import Foundation

/// 在所有候选 ConnectivityPath 中按评分选出当前 best path。
///
/// 评分维度：
/// - 最近一次 probe 是否成功（最大权重）
/// - EMA latency（越低越好）
/// - role 权重：direct > backup > relay
/// - 熔断惩罚：被熔断的直接淘汰（由 EndpointSelector 在上游过滤）
///
/// 滞回：如果当前已有 path 且仍处可用集合内，必须 newScore > currentScore * (1 + hysteresis) 才切换。
struct PathSelector {

    var hysteresis: Double = 0.10  // 10%
    var preferredRoleWeights: [SAEndpointRole: Double] = [
        .direct: 1.0,
        .backup: 0.6,
        .relay:  0.4
    ]

    /// 输入候选 path 集合 + 各 endpoint 的当前 state + 当前已选 path（用于滞回）。
    /// 返回新的 best path。如果候选为空则返回 nil。
    func selectBest(
        candidates: [ConnectivityPath],
        endpointStates: [String: SAEndpointState],
        endpointsById: [String: SAEndpoint],
        current: ConnectivityPath?
    ) -> ConnectivityPath? {

        let scored = candidates.compactMap { p -> (ConnectivityPath, Double)? in
            guard let score = score(path: p, endpointStates: endpointStates, endpointsById: endpointsById) else {
                return nil
            }
            return (p, score)
        }

        guard let top = scored.max(by: { $0.1 < $1.1 }) else { return nil }

        // 滞回：若 current 仍在候选中且 newScore 没显著高于 currentScore，则保持
        if let curr = current,
           let currScore = scored.first(where: { $0.0.id == curr.id })?.1,
           top.0.id != curr.id {
            if top.1 <= currScore * (1.0 + hysteresis) {
                return curr
            }
        }
        return top.0
    }

    private func score(
        path: ConnectivityPath,
        endpointStates: [String: SAEndpointState],
        endpointsById: [String: SAEndpoint]
    ) -> Double? {

        var s: Double = 0

        // role weight
        if let endpointId = path.endpointId, let ep = endpointsById[endpointId] {
            s += (preferredRoleWeights[ep.role] ?? 0.5) * 100
        } else {
            s += 50
        }

        // probe success
        let st = path.endpointId.flatMap { endpointStates[$0] }
        if let s2 = st {
            if s2.isBreakerOpen { return nil }
            if s2.consecutiveFailures > 0 && s2.consecutiveSuccesses == 0 {
                s -= 30
            }
            if let ema = s2.emaLatencyMs {
                // latency 越低 score 越高，1000ms = -25 分
                s -= ema / 40.0
            }
            // 长期成功加分
            s += min(20, Double(s2.consecutiveSuccesses) * 2.0)
        }

        // path priority（policy 给的 endpoint.priority 越小越好）
        s -= Double(path.priority) * 0.1

        return s
    }
}
