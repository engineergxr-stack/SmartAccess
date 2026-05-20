import Foundation

/// V2 升级：
/// - 角色权重不变（direct > backup > relay）
/// - 但当所有 direct/backup path 死在 `.dns` 或 `.tcp` 阶段时，
///   把 relay 角色权重**临时**提到与 direct 同级 → Relay 立刻被选中
/// - failover_strategy: nearest / roundRobin / weighted 决定多 Relay 之间如何选
struct PathSelector {

    var hysteresis: Double = 0.10  // 10%
    var preferredRoleWeights: [SAEndpointRole: Double] = [
        .direct: 1.0,
        .backup: 0.6,
        .relay:  0.4
    ]

    /// V2: 检测到 direct/backup 全死在 DNS/TCP 阶段时使用的提权后权重。
    var elevatedRelayWeight: Double = 1.0

    var relayFailoverStrategy: RelayFailoverStrategy = .nearest

    private var roundRobinCursor: Int = 0

    /// 输入候选 path 集合 + 各 endpoint 的当前 state + 当前已选 path（用于滞回）。
    /// V2 多返一个 `reason` 字符串，用于 metrics / 报告。
    mutating func selectBest(
        candidates: [ConnectivityPath],
        endpointStates: [String: SAEndpointState],
        endpointsById: [String: SAEndpoint],
        current: ConnectivityPath?
    ) -> (path: ConnectivityPath?, reason: String) {

        // 1. 判断是否需要 Relay 提权
        let promoteRelay = shouldPromoteRelay(
            candidates: candidates,
            endpointStates: endpointStates,
            endpointsById: endpointsById
        )

        // 2. 评分
        let scored: [(ConnectivityPath, Double)] = candidates.compactMap { p in
            guard let s = score(
                path: p,
                endpointStates: endpointStates,
                endpointsById: endpointsById,
                promoteRelay: promoteRelay
            ) else { return nil }
            return (p, s)
        }
        guard !scored.isEmpty else {
            return (nil, "no_available_candidates")
        }

        // 3. 在 relay 之间应用 failover_strategy
        let relayCandidates = scored.filter { $0.0.kind == .relay }
        let nonRelay = scored.filter { $0.0.kind != .relay }

        let chosen: (ConnectivityPath, Double)? = {
            if nonRelay.isEmpty || promoteRelay {
                return selectAmongRelays(relayCandidates)
            }
            // 默认非 relay 路径里选最大值
            return nonRelay.max(by: { $0.1 < $1.1 })
        }()

        guard let top = chosen ?? scored.max(by: { $0.1 < $1.1 }) else {
            return (nil, "no_top_after_strategy")
        }

        // 4. 滞回
        if let curr = current,
           let currScore = scored.first(where: { $0.0.id == curr.id })?.1,
           top.0.id != curr.id {
            if top.1 <= currScore * (1.0 + hysteresis) {
                return (curr, "kept_via_hysteresis")
            }
        }

        let reason: String
        if promoteRelay && top.0.kind == .relay {
            reason = "relay_promoted_all_direct_failed_dns_or_tcp"
        } else if current == nil {
            reason = "initial_selection"
        } else if top.0.id != current?.id {
            reason = "switched_to_better_path"
        } else {
            reason = "no_change"
        }

        return (top.0, reason)
    }

    // MARK: - Helpers

    private func shouldPromoteRelay(
        candidates: [ConnectivityPath],
        endpointStates: [String: SAEndpointState],
        endpointsById: [String: SAEndpoint]
    ) -> Bool {
        // direct/backup 类候选
        let nonRelayCandidates = candidates.filter { $0.kind != .relay }
        guard !nonRelayCandidates.isEmpty else { return false }

        // 全部死在 .dns 或 .tcp 阶段才提权
        var allDead = true
        for p in nonRelayCandidates {
            guard let eid = p.endpointId, let st = endpointStates[eid] else { allDead = false; break }
            if !st.isBreakerOpen && st.lastFailureAt == nil {
                // 没失败过，不算死
                allDead = false; break
            }
            let stage = st.lastErrorStage
            if stage != .dns && stage != .tcp {
                allDead = false; break
            }
        }
        return allDead
    }

    private mutating func selectAmongRelays(_ relays: [(ConnectivityPath, Double)]) -> (ConnectivityPath, Double)? {
        guard !relays.isEmpty else { return nil }
        switch relayFailoverStrategy {
        case .nearest, .weighted:
            return relays.max(by: { $0.1 < $1.1 })
        case .roundRobin:
            let sorted = relays.sorted { $0.0.id < $1.0.id }
            let idx = roundRobinCursor % sorted.count
            roundRobinCursor = (roundRobinCursor + 1) % sorted.count
            return sorted[idx]
        }
    }

    private func score(
        path: ConnectivityPath,
        endpointStates: [String: SAEndpointState],
        endpointsById: [String: SAEndpoint],
        promoteRelay: Bool
    ) -> Double? {
        var s: Double = 0

        // role weight
        if let endpointId = path.endpointId, let ep = endpointsById[endpointId] {
            let baseWeight = preferredRoleWeights[ep.role] ?? 0.5
            let weight = (ep.role == .relay && promoteRelay) ? elevatedRelayWeight : baseWeight
            s += weight * 100
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
                s -= ema / 40.0
            }
            s += min(20, Double(s2.consecutiveSuccesses) * 2.0)
        }

        s -= Double(path.priority) * 0.1
        return s
    }
}
