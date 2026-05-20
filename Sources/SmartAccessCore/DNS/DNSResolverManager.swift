import Foundation

/// V2 升级：
/// - V1 只做诊断（并发查多个 resolver 写报告）
/// - V2 同时支持生产模式：把解析结果写入 `DNSCache`，业务侧（Relay IP 直连）可读取
///
/// 策略：
/// - 启动期对 policy 中所有 Relay endpoint 的 host 预热解析
/// - 每个 host 优先级：HTTPDNS / DoH > Static > System（受 DNSStrategy.mode 影响）
/// - 失败时回退到 stale 缓存（stale-while-revalidate）
actor DNSResolverManager {

    private let systemResolver: SystemDNSResolver
    private var fallbackResolvers: [DNSResolver]
    private let log: SALog
    private let cache: DNSCache

    init(fallbackResolvers: [DNSResolver], log: SALog) {
        self.systemResolver = SystemDNSResolver(id: "system")
        self.fallbackResolvers = fallbackResolvers
        self.log = log
        self.cache = DNSCache()
    }

    func updateFallbackResolvers(_ resolvers: [DNSResolver]) {
        self.fallbackResolvers = resolvers
    }

    var dnsCache: DNSCache { cache }

    // MARK: - 诊断（V1 已有）

    /// 并发解析一个 host，所有 resolver 都参与，**不取消**，因为是诊断模式。
    func diagnose(host: String, timeoutMs: Int) async -> DNSDiagnosticReport {
        var resolvers: [DNSResolver] = [systemResolver]
        resolvers.append(contentsOf: fallbackResolvers)

        let results: [DNSResult] = await withTaskGroup(of: DNSResult.self) { group in
            for r in resolvers {
                group.addTask { await r.resolve(host: host, timeoutMs: timeoutMs) }
            }
            var collected: [DNSResult] = []
            for await result in group { collected.append(result) }
            return collected
        }

        // 顺手把成功的结果灌进缓存（生产模式可直接读）
        for r in results where r.success {
            await cache.record(host: r.host, ips: r.ips, source: r.source)
        }

        let report = DNSDiagnosticReport(host: host, results: results)
        log.debug("DNS diagnostic for \(host): \(results.map { "\($0.resolverId)=\($0.ips)" })")
        return report
    }

    // MARK: - 生产解析（V2 新增）

    /// 生产模式解析：返回单个最权威的 IP 列表。
    /// 优先级：HTTPDNS / DoH 任意先成功 → Static map → System DNS
    /// 失败时回退 stale cache。
    func resolveForProduction(host: String, timeoutMs: Int, preferFallback: Bool = false) async -> DNSResult? {
        // 1. 缓存命中
        if let hit = await cache.valid(host: host) {
            return DNSResult(
                host: host,
                resolverId: "cache",
                source: hit.source,
                ips: hit.ips,
                latencyMs: 0,
                errorCode: nil
            )
        }

        // 2. 按优先级跑
        let orderedResolvers: [DNSResolver] = {
            if preferFallback {
                return fallbackResolvers + [systemResolver]
            }
            return [systemResolver] + fallbackResolvers
        }()

        for r in orderedResolvers {
            let res = await r.resolve(host: host, timeoutMs: timeoutMs)
            if res.success {
                await cache.record(host: host, ips: res.ips, source: res.source)
                return res
            }
        }

        // 3. 全部失败：回 stale，让调用者决定要不要用
        if let stale = await cache.stale(host: host) {
            return DNSResult(
                host: host,
                resolverId: "cache-stale",
                source: stale.source,
                ips: stale.ips,
                latencyMs: 0,
                errorCode: "all_resolvers_failed_using_stale"
            )
        }
        return nil
    }

    /// 预热一组 host（用于 Relay endpoint）。
    func prewarm(hosts: [String], timeoutMs: Int) async {
        await withTaskGroup(of: Void.self) { group in
            for h in hosts {
                group.addTask {
                    _ = await self.resolveForProduction(host: h, timeoutMs: timeoutMs, preferFallback: true)
                }
            }
        }
    }
}

/// 用 CFHost API 拿系统解析结果。第一版做法保持不变。
struct SystemDNSResolver: DNSResolver {
    let id: String
    let source: DNSResult.Source = .system

    init(id: String) { self.id = id }

    func resolve(host: String, timeoutMs: Int) async -> DNSResult {
        let start = DispatchTime.now()
        let ips = await Task.detached(priority: .userInitiated) { () -> [String] in
            resolveBlocking(host: host)
        }.value
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
        return DNSResult(
            host: host,
            resolverId: id,
            source: source,
            ips: ips,
            latencyMs: elapsed,
            errorCode: ips.isEmpty ? "system.lookup_failed" : nil
        )
    }

    private func resolveBlocking(host: String) -> [String] {
        let cfHost = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
        CFHostStartInfoResolution(cfHost, .addresses, nil)

        var success: DarwinBoolean = false
        guard let addresses = CFHostGetAddressing(cfHost, &success)?.takeUnretainedValue() as? [Data], success.boolValue else {
            return []
        }

        var ips: [String] = []
        for data in addresses {
            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let r = getnameinfo(
                    sa,
                    socklen_t(data.count),
                    &hostBuf,
                    socklen_t(hostBuf.count),
                    nil, 0,
                    NI_NUMERICHOST
                )
                if r == 0 {
                    ips.append(String(cString: hostBuf))
                }
            }
        }
        return ips
    }
}
