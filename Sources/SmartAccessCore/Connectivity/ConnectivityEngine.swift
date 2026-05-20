import Foundation

/// 核心编排器（V2）。
///
/// 在 V1 基础上增加：
/// - PathSelector 改为 mutating，支持 round-robin
/// - Relay 提权事件 (`relayPromoted`、`relaySelectedAsFailover`) 发到 metrics
/// - ReachabilityReport 写入 selection + dnsSnapshots + group
/// - half-open probe：熔断到期后先发探针再放真实流量
/// - DNS 预热（生产模式 prewarm Relay host）
actor ConnectivityEngine {

    // MARK: - State

    private var policy: SmartAccessPolicy
    private let endpointManager: EndpointManager
    private let httpChecker: HTTPHealthChecker
    private let wsChecker: WebSocketConnectivityChecker
    private let dnsManager: DNSResolverManager
    private let ipChecker: IPPoolChecker
    private var pathSelector = PathSelector()
    private let metrics: SAMetricsSink
    private let log: SALog
    private let licenseManager: LicenseManager

    private var paths: [ConnectivityPath] = []
    private var currentPath: ConnectivityPath?
    private var lastReport: ReachabilityReport = .empty

    init(
        initialPolicy: SmartAccessPolicy,
        endpointManager: EndpointManager,
        httpChecker: HTTPHealthChecker,
        wsChecker: WebSocketConnectivityChecker,
        dnsManager: DNSResolverManager,
        ipChecker: IPPoolChecker,
        licenseManager: LicenseManager,
        metrics: SAMetricsSink,
        log: SALog
    ) {
        self.policy = initialPolicy
        self.endpointManager = endpointManager
        self.httpChecker = httpChecker
        self.wsChecker = wsChecker
        self.dnsManager = dnsManager
        self.ipChecker = ipChecker
        self.licenseManager = licenseManager
        self.metrics = metrics
        self.log = log
        self.pathSelector.relayFailoverStrategy = initialPolicy.relayFailoverStrategy
    }

    // MARK: - Public API

    func applyPolicy(_ newPolicy: SmartAccessPolicy) async {
        self.policy = newPolicy
        await endpointManager.updateBreakerConfig(direct: newPolicy.circuitBreaker, relay: newPolicy.relayCircuitBreaker)
        await endpointManager.setEndpoints(newPolicy.endpoints)
        self.paths = await buildCandidatePaths(from: newPolicy)
        self.pathSelector.relayFailoverStrategy = newPolicy.relayFailoverStrategy
        await selectAndPublish(reason: "policy_applied")
    }

    @discardableResult
    func warmup() async -> ConnectivityPath? {
        metrics.emit(.startupBegan)
        let startedAt = Date()

        // 把 actor 隔离状态先抽成局部值
        let endpoints       = await endpointManager.endpoints
        let httpEndpoints   = endpoints.filter { $0.kind == .http }
        let wsEndpoints     = endpoints.filter { $0.kind == .websocket }
        let httpChecker     = self.httpChecker
        let wsChecker       = self.wsChecker
        let httpTimeoutMs   = policy.healthCheck.timeoutMs
        let wsTimeoutMs     = policy.websocketCheck.timeoutMs
        let parallelLimit   = max(1, policy.healthCheck.parallelLimit)
        let wsEnabled       = policy.websocketCheck.enabled
        let wsLicensed      = await licenseManager.isFeatureEnabled(SALicenseFeature.webSocketCheck)
        let ipLicensed      = await licenseManager.isFeatureEnabled(SALicenseFeature.ipPool)
        let dnsLicensed     = await licenseManager.isFeatureEnabled(SALicenseFeature.httpDNS)
            || await licenseManager.isFeatureEnabled(SALicenseFeature.doh)
            || await licenseManager.isFeatureEnabled(SALicenseFeature.staticDNS)
        let dnsStrategy     = policy.dnsStrategy
        let ipPools         = policy.ipPools
        let policyVersion   = policy.version
        let dnsMgr          = self.dnsManager
        let ipChecker       = self.ipChecker
        let snapshotPaths   = self.paths
        let endpointsById   = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, $0) })

        // V2: DNS 预热 Relay host
        let relayHosts = endpoints.filter { $0.role == .relay }.compactMap { $0.url.host }
        if !relayHosts.isEmpty {
            await dnsMgr.prewarm(hosts: Array(Set(relayHosts)), timeoutMs: 2000)
            for h in relayHosts {
                if let dns = await dnsMgr.dnsCache.valid(host: h) {
                    metrics.emit(.dnsResolutionUpdated(host: h, source: dns.source, ipCount: dns.ips.count))
                }
            }
        }

        var attempts: [ReachabilityReport.PathAttempt] = []

        // ---- HTTP probes
        let httpResults: [(SAEndpoint, SAHealthResult)] = await withTaskGroup(
            of: (SAEndpoint, SAHealthResult).self
        ) { group in
            let limit = AsyncSemaphore(value: parallelLimit)
            for ep in httpEndpoints {
                group.addTask {
                    await limit.wait()
                    let r = await httpChecker.probe(endpoint: ep, timeoutMs: httpTimeoutMs)
                    await limit.signal()
                    return (ep, r)
                }
            }
            var out: [(SAEndpoint, SAHealthResult)] = []
            for await x in group { out.append(x) }
            return out
        }

        for (ep, r) in httpResults {
            await endpointManager.recordProbe(
                endpointId: ep.id,
                success: r.success,
                latencyMs: r.latencyMs,
                errorCode: r.errorCode,
                errorStage: r.success ? nil : r.stage
            )
            let kind = pathKind(forRole: ep.role)
            let path = snapshotPaths.first { $0.endpointId == ep.id && $0.kind == kind }
            let result = ConnectivityResult(
                pathId: path?.id ?? "ep:\(ep.id)",
                endpointId: ep.id,
                kind: kind,
                success: r.success,
                stage: r.stage,
                latencyMs: r.latencyMs,
                errorCode: r.errorCode
            )
            attempts.append(.init(
                pathId: result.pathId,
                endpointId: ep.id,
                kind: kind,
                stage: r.stage,
                success: r.success,
                errorCode: r.errorCode,
                latencyMs: r.latencyMs,
                attemptedAt: Date(),
                group: ep.group
            ))
            metrics.emit(.probeResult(result))
        }

        // ---- WebSocket probes
        if wsEnabled, wsLicensed {
            let wsResults: [(SAEndpoint, SAHealthResult)] = await withTaskGroup(
                of: (SAEndpoint, SAHealthResult).self
            ) { group in
                for ep in wsEndpoints {
                    group.addTask {
                        let r = await wsChecker.probe(endpoint: ep, timeoutMs: wsTimeoutMs)
                        return (ep, r)
                    }
                }
                var out: [(SAEndpoint, SAHealthResult)] = []
                for await x in group { out.append(x) }
                return out
            }
            for (ep, r) in wsResults {
                await endpointManager.recordProbe(
                    endpointId: ep.id, success: r.success,
                    latencyMs: r.latencyMs, errorCode: r.errorCode,
                    errorStage: r.success ? nil : r.stage
                )
                attempts.append(.init(
                    pathId: "ws:\(ep.id)",
                    endpointId: ep.id,
                    kind: .directDomain,
                    stage: r.stage,
                    success: r.success,
                    errorCode: r.errorCode,
                    latencyMs: r.latencyMs,
                    attemptedAt: Date(),
                    group: ep.group
                ))
            }
        }

        // ---- DNS diagnostic
        if let dns = dnsStrategy, dns.diagnosticOnly, dnsLicensed {
            for ep in httpEndpoints {
                guard let host = ep.url.host else { continue }
                let report = await dnsMgr.diagnose(host: host, timeoutMs: 2000)
                metrics.emit(.dnsDiagnostic(report))
            }
        }

        // ---- IP pool diagnostic
        if !ipPools.isEmpty, ipLicensed {
            for pool in ipPools {
                let results = await ipChecker.probePool(
                    pool,
                    timeoutMs: httpTimeoutMs,
                    parallelLimit: parallelLimit
                )
                metrics.emit(.ipPoolDiagnostic(host: pool.host, results: results))
            }
        }

        // 收集 DNS 快照
        var dnsSnapshots: [ReachabilityReport.DNSSnapshot] = []
        let allHosts = Set(endpoints.compactMap { $0.url.host })
        for h in allHosts {
            if let hit = await dnsMgr.dnsCache.valid(host: h) {
                dnsSnapshots.append(.init(host: h, source: hit.source, ips: hit.ips))
            } else if let stale = await dnsMgr.dnsCache.stale(host: h) {
                dnsSnapshots.append(.init(host: h, source: stale.source, ips: stale.ips))
            }
        }

        let preliminarySelection = ReachabilityReport.Selection(
            pathId: currentPath?.id,
            kind: currentPath?.kind,
            reason: "pending_post_warmup"
        )
        lastReport = ReachabilityReport(
            generatedAt: Date(),
            policyVersion: policyVersion,
            attemptedPaths: attempts,
            selection: preliminarySelection,
            dnsSnapshots: dnsSnapshots
        )

        await selectAndPublish(reason: "warmup_completed")

        let duration = Int(Date().timeIntervalSince(startedAt) * 1000)
        metrics.emit(.startupCompleted(durationMs: duration, selectedPathId: currentPath?.id))
        _ = endpointsById
        return currentPath
    }

    // MARK: - V2: half-open probe

    /// 被 SmartAccess 周期性触发：对熔断到期的 endpoint 发一次探针，
    /// 成功才让它重新加入选路池子，避免真实流量踩坑。
    func performHalfOpenProbes() async {
        let candidates = await endpointManager.endpointsNeedingHalfOpenProbe()
        guard !candidates.isEmpty else { return }
        let httpTimeoutMs = policy.healthCheck.timeoutMs
        let httpChecker = self.httpChecker

        for ep in candidates {
            await endpointManager.markHalfOpenScheduled(endpointId: ep.id, at: Date().addingTimeInterval(10))
            guard ep.kind == .http else { continue }
            let r = await httpChecker.probe(endpoint: ep, timeoutMs: httpTimeoutMs)
            await endpointManager.recordProbe(
                endpointId: ep.id, success: r.success,
                latencyMs: r.latencyMs, errorCode: r.errorCode,
                errorStage: r.success ? nil : r.stage
            )
            metrics.emit(.circuitBreakerHalfOpenProbed(endpointId: ep.id, success: r.success))
        }
        await selectAndPublish(reason: "half_open_probe_completed")
    }

    // MARK: - Reads

    func currentSelectedPath() -> ConnectivityPath? { currentPath }
    func reachabilityReport() -> ReachabilityReport { lastReport }
    func candidatePaths() -> [ConnectivityPath] { paths }

    // MARK: - Customer feedback hooks

    func reportSuccess(endpointId: String, latencyMs: Int?) async {
        await endpointManager.recordProbe(endpointId: endpointId, success: true, latencyMs: latencyMs, errorCode: nil, errorStage: nil)
        metrics.emit(.reportedSuccess(endpointId: endpointId, latencyMs: latencyMs ?? 0))
    }

    func reportFailure(endpointId: String, error: Error) async {
        let (stage, code) = ErrorClassifier.classify(error)
        await endpointManager.recordProbe(endpointId: endpointId, success: false, latencyMs: nil, errorCode: code, errorStage: stage)
        metrics.emit(.reportedFailure(endpointId: endpointId, errorCode: code, stage: stage))
        await selectAndPublish(reason: "report_failure:\(code)")
    }

    // MARK: - Selection

    private func selectAndPublish(reason: String) async {
        let endpoints = await endpointManager.endpoints
        let states = await endpointManager.allStates()
        let endpointsById = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, $0) })

        let availableEndpoints = EndpointSelector.availableEndpoints(endpoints, states: states)
        let availableIds = Set(availableEndpoints.map(\.id))
        let availablePaths = paths.filter {
            guard let id = $0.endpointId else { return false }
            return availableIds.contains(id)
        }

        let (newPath, selectorReason) = pathSelector.selectBest(
            candidates: availablePaths,
            endpointStates: states,
            endpointsById: endpointsById,
            current: currentPath
        )

        // V2: 检测 Relay 升级事件
        let wasRelay = currentPath?.kind == .relay
        let willRelay = newPath?.kind == .relay

        if newPath?.id != currentPath?.id {
            metrics.emit(.pathChanged(
                fromPathId: currentPath?.id,
                toPathId: newPath?.id ?? "<none>",
                reason: "\(reason)|\(selectorReason)"
            ))
            if let np = newPath {
                metrics.emit(.pathSelected(pathId: np.id, kind: np.kind))
                if willRelay && !wasRelay {
                    metrics.emit(.relaySelectedAsFailover(pathId: np.id, reason: selectorReason))
                }
            } else {
                metrics.emit(.noReachablePath(lastReport))
            }
        }

        if selectorReason.contains("relay_promoted") {
            metrics.emit(.relayPromoted(reason: selectorReason))
        }

        currentPath = newPath

        // 更新 lastReport 的 selection
        lastReport = ReachabilityReport(
            generatedAt: lastReport.generatedAt,
            policyVersion: lastReport.policyVersion,
            attemptedPaths: lastReport.attemptedPaths,
            selection: .init(pathId: newPath?.id, kind: newPath?.kind, reason: selectorReason),
            dnsSnapshots: lastReport.dnsSnapshots
        )
    }

    // MARK: - Path construction

    private func pathKind(forRole role: SAEndpointRole) -> ConnectivityPathKind {
        switch role {
        case .direct: return .directDomain
        case .backup: return .backupDomain
        case .relay:  return .relay
        }
    }

    private func buildCandidatePaths(from policy: SmartAccessPolicy) async -> [ConnectivityPath] {
        var paths: [ConnectivityPath] = []
        let relayEnabled = await licenseManager.isFeatureEnabled(SALicenseFeature.relay)

        for ep in policy.endpoints where ep.enabled {
            guard ep.kind == .http else { continue }
            let kind: ConnectivityPathKind
            switch ep.role {
            case .direct: kind = .directDomain
            case .backup: kind = .backupDomain
            case .relay:
                if !relayEnabled { continue }
                kind = .relay
            }
            var meta = ep.metadata
            if let g = ep.group { meta["group"] = g }
            meta["direct_ip_mode"] = ep.directIPMode.rawValue
            paths.append(ConnectivityPath(
                id: "\(kind.rawValue):\(ep.id)",
                kind: kind,
                baseURL: ep.url,
                endpointId: ep.id,
                priority: ep.priority,
                metadata: meta
            ))
        }
        return paths
    }
}
