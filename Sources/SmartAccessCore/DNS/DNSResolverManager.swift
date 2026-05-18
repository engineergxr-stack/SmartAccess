import Foundation

/// DNS 解析编排。第一版策略：diagnostic_only 默认 true，
/// 即 SDK 仅做诊断报告，不会把业务请求改写为 https://IP。
///
/// 即便如此，SDK 也会并发查询 system / httpDNS / DoH / static，
/// 把结果汇总进 `DNSDiagnosticReport`，并写入 `ReachabilityReport` 的 path metadata。
actor DNSResolverManager {

    private let systemResolver: SystemDNSResolver
    private var fallbackResolvers: [DNSResolver]
    private let log: SALog

    init(fallbackResolvers: [DNSResolver], log: SALog) {
        self.systemResolver = SystemDNSResolver(id: "system")
        self.fallbackResolvers = fallbackResolvers
        self.log = log
    }

    func updateFallbackResolvers(_ resolvers: [DNSResolver]) {
        self.fallbackResolvers = resolvers
    }

    /// 并发解析一个 host，所有 resolver 都参与，无论谁先返回都不会取消其他人，
    /// 因为目的是「全量诊断」。
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

        let report = DNSDiagnosticReport(host: host, results: results)
        log.debug("DNS diagnostic for \(host): \(results.map { "\($0.resolverId)=\($0.ips)" })")
        return report
    }
}

/// 用 `Network.framework` 的 NWConnection 间接驱动系统 DNS：
/// 我们其实需要的是「能解析出来」，所以这里通过 CFHost API 拿同步结果。
/// （CFHost 在 iOS 上仍然可用，且解析路径与 URLSession 一致。）
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
                    let s = String(cString: hostBuf)
                    ips.append(s)
                }
            }
        }
        return ips
    }
}
