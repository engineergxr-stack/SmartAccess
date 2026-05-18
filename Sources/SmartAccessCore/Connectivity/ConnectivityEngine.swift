import Foundation

/// 核心编排器。
///
/// 职责：
/// - 把 policy 转成 `[ConnectivityPath]` 候选集合（含 direct / backup / relay）；
/// - 并发跑 HTTP / WebSocket probe，更新 EndpointState；
/// - 调用 `PathSelector` 选出 current path；
/// - 维护 `ReachabilityReport`（最近一次完整 warmup 的诊断）；
/// - 串接 DNSResolverManager / IPPoolChecker 做诊断（不参与业务流量路径，仅写入报告）。
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

    // MARK: - Init

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
    }

    // MARK: - Public API

    /// 应用一个新 policy（首次 / 刷新都走这里）。
    func applyPolicy(_ newPolicy: SmartAccessPolicy) async {
        self.policy = newPolicy
        await endpointManager.setEndpoints(newPolicy.endpoints)
        self.paths = await buildCandidatePaths(from: newPolicy)
        await selectAndPublish(reason: "policy_applied")
    }

    /// 一次完整 warmup。
    @discardableResult
    func warmup() async -> ConnectivityPath? {
        metrics.emit(.startupBegan)
        let startedAt = Date()

        // 把 actor 隔离的状态先抽成 Sendable 局部值，
        // 后面在 withTaskGroup 的 @Sendable 闭包里只用局部值。
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
                errorCode: r.errorCode
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
                attemptedAt: Date()
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
                    latencyMs: r.latencyMs, errorCode: r.errorCode
                )
                attempts.append(.init(
                    pathId: "ws:\(ep.id)",
                    endpointId: ep.id,
                    kind: .directDomain,
                    stage: r.stage,
                    success: r.success,
                    errorCode: r.errorCode,
                    latencyMs: r.latencyMs,
                    attemptedAt: Date()
                ))
            }
        }

        // ---- DNS diagnostic（不影响业务路径，仅生成报告）
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

        lastReport = ReachabilityReport(
            generatedAt: Date(),
            policyVersion: policyVersion,
            attemptedPaths: attempts
        )

        await selectAndPublish(reason: "warmup_completed")

        let duration = Int(Date().timeIntervalSince(startedAt) * 1000)
        metrics.emit(.startupCompleted(durationMs: duration, selectedPathId: currentPath?.id))
        return currentPath
    }

    // MARK: - Reads

    func currentSelectedPath() -> ConnectivityPath? { currentPath }
    func reachabilityReport() -> ReachabilityReport { lastReport }
    func candidatePaths() -> [ConnectivityPath] { paths }

    // MARK: - Customer feedback hooks

    func reportSuccess(endpointId: String, latencyMs: Int?) async {
        await endpointManager.recordProbe(endpointId: endpointId, success: true, latencyMs: latencyMs, errorCode: nil)
        metrics.emit(.reportedSuccess(endpointId: endpointId, latencyMs: latencyMs ?? 0))
    }

    func reportFailure(endpointId: String, error: Error) async {
        let (stage, code) = ErrorClassifier.classify(error)
        await endpointManager.recordProbe(endpointId: endpointId, success: false, latencyMs: nil, errorCode: code)
        metrics.emit(.reportedFailure(endpointId: endpointId, errorCode: code, stage: stage))
        // 业务失败后立即重选（不重发本次请求；POST 默认不自动 retry）
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

        let newPath = pathSelector.selectBest(
            candidates: availablePaths,
            endpointStates: states,
            endpointsById: endpointsById,
            current: currentPath
        )

        if newPath?.id != currentPath?.id {
            metrics.emit(.pathChanged(
                fromPathId: currentPath?.id,
                toPathId: newPath?.id ?? "<none>",
                reason: reason
            ))
            if let np = newPath {
                metrics.emit(.pathSelected(pathId: np.id, kind: np.kind))
            } else {
                metrics.emit(.noReachablePath(lastReport))
            }
        }
        currentPath = newPath
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
            guard ep.kind == .http else { continue } // ws endpoint 仅参与诊断
            let kind: ConnectivityPathKind
            switch ep.role {
            case .direct: kind = .directDomain
            case .backup: kind = .backupDomain
            case .relay:
                if !relayEnabled { continue }
                kind = .relay
            }
            paths.append(ConnectivityPath(
                id: "\(kind.rawValue):\(ep.id)",
                kind: kind,
                baseURL: ep.url,
                endpointId: ep.id,
                priority: ep.priority,
                metadata: ep.metadata
            ))
        }
        return paths
    }
}
