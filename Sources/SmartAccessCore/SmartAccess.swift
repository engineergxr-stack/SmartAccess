import Foundation

/// SmartAccess SDK 公共 Facade。
///
/// 使用流程：
/// ```swift
/// let config = SmartAccessConfig(
///     projectId: "customer_app",
///     licenseFileURL: Bundle.main.url(forResource: "SmartAccess", withExtension: "license")!,
///     licensePublicKey: "<base64 ed25519 public key>",
///     policyPublicKey: "<base64 ed25519 public key>",
///     seedPolicyFileURL: Bundle.main.url(forResource: "SmartAccessSeedPolicy", withExtension: "signed.json")
/// )
/// try await SmartAccess.shared.start(config: config, mode: .fastWarmup(maxWaitMs: 500))
///
/// // 业务网络层：
/// let baseURL = await SmartAccess.shared.currentBaseURL()
///
/// // 业务回调：
/// await SmartAccess.shared.reportSuccess(endpointId: ep.id, latencyMs: 120)
/// await SmartAccess.shared.reportFailure(endpointId: ep.id, error: err)
/// ```
public final class SmartAccess: @unchecked Sendable {

    public static let shared = SmartAccess()
    private init() {}

    private let lock = NSLock()
    private var state: State = .notStarted

    private enum State {
        case notStarted
        case starting
        case running(Runtime)
    }

    /// 顶层启动。
    /// - 校验 license（失败抛错；过期/grace 由 LicenseManager 内部判断）。
    /// - bootstrap policy（cached > seed）。
    /// - 启动 ConnectivityEngine，按 mode 决定阻塞策略。
    ///
    /// - Returns: bootstrap 后选出的 ConnectivityPath（可能后续会被 warmup 替换，并通过 metrics 通知）。
    @discardableResult
    public func start(
        config: SmartAccessConfig,
        mode: SmartAccessStartupMode
    ) async throws -> ConnectivityPath? {

        // 状态机入口保护
        lock.lock()
        switch state {
        case .running:
            lock.unlock()
            throw SmartAccessError.alreadyStarted
        case .starting:
            lock.unlock()
            throw SmartAccessError.alreadyStarted
        case .notStarted:
            state = .starting
            lock.unlock()
        }

        let log = SALog(config.logger)

        do {
            let runtime = try await Runtime.build(config: config, log: log)
            // bootstrap policy 与 endpoint 已就绪，让 engine 应用一次
            await runtime.engine.applyPolicy(runtime.initialPolicy)

            let bootstrapPath = await runtime.engine.currentSelectedPath()

            // 标记 running
            lock.lock()
            state = .running(runtime)
            lock.unlock()

            // 根据 mode 决定阻塞策略
            switch mode {
            case .fastWarmup(let maxWaitMs):
                // raceWarmup 已经启动了 warmup（取消只是设置标志，warmup 会跑完）；
                // 这里同时启动 policy refresh，不再额外启动重复 warmup。
                _ = await Self.raceWarmup(engine: runtime.engine, maxWaitMs: maxWaitMs)
                Task.detached(priority: .utility) {
                    if let v = await runtime.policyResolver.refreshFromRemote() {
                        if let p = await runtime.policyResolver.currentPolicy {
                            await runtime.engine.applyPolicy(p)
                            log.info("policy.refresh.applied version=\(v)")
                        }
                    }
                }
            case .fullWarmup(let timeoutMs):
                _ = await Self.raceWarmup(engine: runtime.engine, maxWaitMs: timeoutMs)
            case .lazy:
                Task.detached(priority: .utility) {
                    await runtime.engine.warmup()
                }
            }

            return await runtime.engine.currentSelectedPath() ?? bootstrapPath
        } catch {
            lock.lock()
            state = .notStarted
            lock.unlock()
            throw error
        }
    }

    /// 同步取当前 baseURL。如果尚未 start，返回 nil。
    public func currentBaseURL() async -> URL? {
        guard let rt = currentRuntime() else { return nil }
        let path = await rt.engine.currentSelectedPath()
        return path?.baseURL
    }

    /// 同步取当前 path（含 kind、endpointId、metadata）。
    public func currentPath() async -> ConnectivityPath? {
        guard let rt = currentRuntime() else { return nil }
        return await rt.engine.currentSelectedPath()
    }

    /// 客户业务请求成功回调。
    public func reportSuccess(endpointId: String, latencyMs: Int?) async {
        guard let rt = currentRuntime() else { return }
        await rt.engine.reportSuccess(endpointId: endpointId, latencyMs: latencyMs)
    }

    /// 客户业务请求失败回调。
    public func reportFailure(endpointId: String, error: Error) async {
        guard let rt = currentRuntime() else { return }
        await rt.engine.reportFailure(endpointId: endpointId, error: error)
    }

    /// 取最近一次完整 warmup 的可达性诊断报告。
    public func reachabilityReport() async -> ReachabilityReport {
        guard let rt = currentRuntime() else { return .empty }
        return await rt.engine.reachabilityReport()
    }

    /// 主动触发一次 warmup（不常用，调试用）。
    @discardableResult
    public func warmupNow() async -> ConnectivityPath? {
        guard let rt = currentRuntime() else { return nil }
        return await rt.engine.warmup()
    }

    // MARK: - V2: 诊断包导出

    /// 导出诊断包。客户在用户报问题时调用一次，拿到 manifest + 最近 ReachabilityReport + 日志。
    /// 返回的目录由 SDK 创建；上传到客户工单系统由客户自行处理（SDK 不上报后台）。
    public func exportDiagnosticBundle() async throws -> DiagnosticBundle {
        guard let rt = currentRuntime() else { throw SmartAccessError.notStarted }
        let report = await rt.engine.reachabilityReport()
        let licenseId = await rt.licenseManager.currentLicense()?.licenseId
        let policyVersion = await rt.policyResolver.currentPolicy?.version
        let bundle = try await DiagnosticBundleBuilder.build(
            targetDirectory: rt.config.diagnosticExportDirectoryURL,
            storage: rt.config.localLogStorage,
            report: report,
            sdkVersion: rt.config.sdkVersion,
            bundleId: rt.config.bundleId,
            projectId: rt.config.projectId,
            policyVersion: policyVersion,
            licenseId: licenseId
        )
        rt.compositeSink.emit(.diagnosticBundleExported(
            path: bundle.directory.path,
            sizeBytes: bundle.totalBytes
        ))
        return bundle
    }

    /// 清空本地日志（不影响诊断包已导出的副本）。
    public func purgeLocalLogs() async {
        guard let rt = currentRuntime() else { return }
        await rt.config.localLogStorage.purge()
    }

    // MARK: - V2: Relay IP 直连入口

    /// 通过当前选中的 Relay endpoint 走 IP 直连发请求。
    ///
    /// **仅用于 Relay endpoint**。业务源站请求走客户自己的 URLSession + currentBaseURL 即可。
    ///
    /// 调用时机：
    /// - 客户网络层在拼好 request 后，**先**判断 `await SmartAccess.shared.shouldUseRelayDirect()`
    /// - 若 true，调用 `await SmartAccess.shared.sendViaRelayDirect(method:path:headers:body:)`
    /// - 若 false，按 URLSession + currentBaseURL 走 V1 兼容路径
    ///
    /// 客户也可以一直走 V1 兼容路径，不用调这套 API——SDK 不会强制。
    public func shouldUseRelayDirect() async -> Bool {
        guard let rt = currentRuntime() else { return false }
        guard let path = await rt.engine.currentSelectedPath(), path.kind == .relay else { return false }
        // 只在 directIPMode 启用时才走
        let mode = path.metadata["direct_ip_mode"] ?? "off"
        return mode == "fallback" || mode == "always"
    }

    /// 走 Relay IP 直连发请求。失败抛 `RelayDirectTransport.DirectError`。
    public func sendViaRelayDirect(
        method: String,
        path: String,
        headers: [(String, String)] = [],
        body: Data? = nil,
        timeoutMs: Int = 10_000
    ) async throws -> RelayDirectTransport.Response {
        guard let rt = currentRuntime() else { throw SmartAccessError.notStarted }
        guard let currentPath = await rt.engine.currentSelectedPath(),
              currentPath.kind == .relay,
              let endpointId = currentPath.endpointId else {
            throw SmartAccessError.invalidEndpoint(reason: "current_path_is_not_relay")
        }
        guard let endpoint = await rt.endpointManager.endpoints.first(where: { $0.id == endpointId }) else {
            throw SmartAccessError.invalidEndpoint(reason: "endpoint_not_found")
        }
        guard let execution = await rt.relayPathResolver.resolve(endpoint: endpoint, timeoutMs: timeoutMs) else {
            throw SmartAccessError.invalidEndpoint(reason: "relay_no_ip_resolved")
        }
        let transport = RelayDirectTransport()
        let req = RelayDirectTransport.Request(method: method, path: path, headers: headers, body: body)
        return try await transport.send(
            ip: execution.ip,
            port: execution.port,
            hostname: execution.hostname,
            request: req,
            timeoutMs: timeoutMs
        )
    }

    /// 关闭：清空运行时。调用者负责确保没有 in-flight 请求依赖 currentBaseURL。
    public func shutdown() {
        lock.lock()
        state = .notStarted
        lock.unlock()
    }

    // MARK: - Helpers

    private func currentRuntime() -> Runtime? {
        lock.lock(); defer { lock.unlock() }
        if case .running(let rt) = state { return rt }
        return nil
    }

    private static func raceWarmup(engine: ConnectivityEngine, maxWaitMs: Int) async -> ConnectivityPath? {
        return await withTaskGroup(of: ConnectivityPath?.self, returning: ConnectivityPath?.self) { group in
            group.addTask {
                await engine.warmup()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(maxWaitMs) * 1_000_000)
                return await engine.currentSelectedPath()
            }
            if let r = await group.next() {
                group.cancelAll()
                return r
            }
            return nil
        }
    }
}

// MARK: - Runtime

extension SmartAccess {

    /// 启动完成后的运行时容器，封装所有 manager。
    final class Runtime {
        let config: SmartAccessConfig
        let licenseManager: LicenseManager
        let policyResolver: PolicyResolver
        let endpointManager: EndpointManager
        let engine: ConnectivityEngine
        let initialPolicy: SmartAccessPolicy
        let compositeSink: CompositeSink
        let relayPathResolver: RelayPathResolver

        init(
            config: SmartAccessConfig,
            licenseManager: LicenseManager,
            policyResolver: PolicyResolver,
            endpointManager: EndpointManager,
            engine: ConnectivityEngine,
            initialPolicy: SmartAccessPolicy,
            compositeSink: CompositeSink,
            relayPathResolver: RelayPathResolver
        ) {
            self.config = config
            self.licenseManager = licenseManager
            self.policyResolver = policyResolver
            self.endpointManager = endpointManager
            self.engine = engine
            self.initialPolicy = initialPolicy
            self.compositeSink = compositeSink
            self.relayPathResolver = relayPathResolver
        }

        static func build(config: SmartAccessConfig, log: SALog) async throws -> Runtime {

            // 公钥
            let licensePub = try SignatureVerifier.parsePublicKey(config.licensePublicKey)
            let policyPub  = try SignatureVerifier.parsePublicKey(config.policyPublicKey)

            // License
            let licenseManager = LicenseManager(
                publicKey: licensePub,
                bundleId: config.bundleId,
                sdkVersion: config.sdkVersion,
                log: log
            )
            try await licenseManager.load(licenseFileURL: config.licenseFileURL)

            // Policy
            let seedProvider   = SeedPolicyProvider(fileURL: config.seedPolicyFileURL)
            let cachedProvider = CachedPolicyProvider(cacheDirectoryURL: config.cacheDirectoryURL)
            let remoteProvider = RemotePolicyProvider()
            let resolver = PolicyResolver(
                seedProvider: seedProvider,
                cachedProvider: cachedProvider,
                remoteProvider: remoteProvider,
                publicKey: policyPub,
                projectId: config.projectId,
                log: log
            )
            let initialPolicy = try await resolver.bootstrap()

            // Probes / DNS / IP
            let endpointManager = EndpointManager(
                circuitBreakerConfig: initialPolicy.circuitBreaker,
                relayBreakerConfig: initialPolicy.relayCircuitBreaker,
                log: log
            )
            await endpointManager.setEndpoints(initialPolicy.endpoints)

            let dnsResolvers: [DNSResolver] = (initialPolicy.dnsStrategy?.fallbackResolvers ?? []).compactMap { r in
                switch r.type {
                case .httpsJson:
                    guard let url = r.url else { return nil }
                    return HTTPDNSResolver(id: r.id, endpoint: url)
                case .doh:
                    guard let url = r.url else { return nil }
                    return DoHResolver(id: r.id, endpoint: url)
                case .staticMap:
                    return StaticDNSResolver(id: r.id, map: r.map ?? [:])
                }
            }
            let dnsManager = DNSResolverManager(fallbackResolvers: dnsResolvers, log: log)

            // V2: 复合 sink = 客户 sink + 本地日志 + escalation 判定
            let filteredCustomer: SAMetricsSink = {
                if let min = config.metricsMinSeverity {
                    return FilteredMetricsSink(minSeverity: min, wrapped: config.metricsSink)
                }
                return config.metricsSink
            }()
            let compositeSink = CompositeSink(
                customer: filteredCustomer,
                storage: config.localLogStorage
            )

            let engine = ConnectivityEngine(
                initialPolicy: initialPolicy,
                endpointManager: endpointManager,
                httpChecker: HTTPHealthChecker(),
                wsChecker: WebSocketConnectivityChecker(),
                dnsManager: dnsManager,
                ipChecker: IPPoolChecker(),
                licenseManager: licenseManager,
                metrics: compositeSink,
                log: log
            )

            let relayPathResolver = RelayPathResolver(dnsManager: dnsManager, log: log)

            return Runtime(
                config: config,
                licenseManager: licenseManager,
                policyResolver: resolver,
                endpointManager: endpointManager,
                engine: engine,
                initialPolicy: initialPolicy,
                compositeSink: compositeSink,
                relayPathResolver: relayPathResolver
            )
        }
    }
}
