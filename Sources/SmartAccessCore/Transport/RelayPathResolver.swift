import Foundation

/// 给客户网络层用的"Relay 路径解析器"。
///
/// 用法：
/// 1. 客户网络层取 `currentBaseURL()` 拼好业务 URL（仍是 https://gateway-hk.example.com/...）。
/// 2. 当 SDK 判定当前 Relay 应走 IP 直连时，**客户网络层有两种选择**：
///    a) 继续用 URLSession 走域名访问，让系统 DNS 自己解析（V1 兼容路径）。
///    b) 调 `SmartAccess.shared.sendViaRelayDirect(request:)` 让 SDK 走 NWConnection IP 直连
///       （只对 Relay endpoint 启用；不要对业务源站调用）。
///
/// 这个文件提供了 (b) 的入口逻辑。
///
/// 重要边界：
/// - 仅当 endpoint.role == .relay && endpoint.directIPMode ≠ .off 时才会走 IP 直连。
/// - 业务源站的 endpoint（direct / backup）永远不会被 IP 直连。
public actor RelayPathResolver {

    public struct DirectExecution: Sendable {
        public let ip: String
        public let hostname: String
        public let port: UInt16
    }

    private let dnsManager: DNSResolverManager
    private let log: SALog

    public init(dnsManager: DNSResolverManager, log: SALog) {
        self.dnsManager = dnsManager
        self.log = log
    }

    /// 给定一个 Relay endpoint，决定是否需要走 IP 直连，需要的话给出 ip+hostname+port。
    /// - 返回 nil 表示"按 URLSession 域名访问即可"，调用方走 V1 兼容路径。
    public func resolve(endpoint: SAEndpoint, timeoutMs: Int = 3000) async -> DirectExecution? {
        guard endpoint.role == .relay else { return nil }
        guard let host = endpoint.url.host else { return nil }
        let port: UInt16 = UInt16(endpoint.url.port ?? 443)

        switch endpoint.directIPMode {
        case .off:
            return nil
        case .always:
            return await pickIP(for: host, port: port, timeoutMs: timeoutMs)
        case .fallback:
            // V2 策略：先做一次系统 DNS quick check，若成功就走域名访问；失败再用 HTTPDNS IP
            if await systemDNSWorks(for: host) {
                return nil
            }
            return await pickIP(for: host, port: port, timeoutMs: timeoutMs)
        }
    }

    private func systemDNSWorks(for host: String) async -> Bool {
        let result = await SystemDNSResolver(id: "system-check").resolve(host: host, timeoutMs: 800)
        return result.success
    }

    private func pickIP(for host: String, port: UInt16, timeoutMs: Int) async -> DirectExecution? {
        guard let dns = await dnsManager.resolveForProduction(host: host, timeoutMs: timeoutMs, preferFallback: true) else {
            return nil
        }
        // 简单地选第一个；后续可加 happy eyeballs / IP 健康分
        guard let ip = dns.ips.first else { return nil }
        log.info("relay.direct picked ip=\(ip) for host=\(host) source=\(dns.source.rawValue)")
        return DirectExecution(ip: ip, hostname: host, port: port)
    }
}
