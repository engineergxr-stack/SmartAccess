import Foundation

/// 带 TTL 的 DNS 缓存。
///
/// V2 生产模式下 DNSResolverManager 用这个缓存：
/// - 启动时预热客户配置中所有已知 host
/// - HTTPDNS / DoH 返回的 IP 按各自 TTL 缓存
/// - 业务侧（Relay IP 直连）取最近未过期的 IP；过期了背景刷新
actor DNSCache {

    private struct Entry {
        let ips: [String]
        let source: DNSResult.Source
        let expiresAt: Date
        let updatedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private let defaultTTLSeconds: TimeInterval

    init(defaultTTLSeconds: TimeInterval = 300) {
        self.defaultTTLSeconds = defaultTTLSeconds
    }

    func record(host: String, ips: [String], source: DNSResult.Source, ttlSeconds: TimeInterval? = nil) {
        guard !ips.isEmpty else { return }
        let ttl = ttlSeconds ?? defaultTTLSeconds
        cache[host] = Entry(
            ips: ips,
            source: source,
            expiresAt: Date().addingTimeInterval(ttl),
            updatedAt: Date()
        )
    }

    /// 取一份未过期的 IP 列表。如果过期或不存在返回 nil。
    func valid(host: String, now: Date = Date()) -> (ips: [String], source: DNSResult.Source)? {
        guard let entry = cache[host], entry.expiresAt > now else { return nil }
        return (entry.ips, entry.source)
    }

    /// 取一份 IP 列表，**忽略 TTL**。用于过期后兜底（"stale-while-revalidate"）。
    func stale(host: String) -> (ips: [String], source: DNSResult.Source)? {
        guard let entry = cache[host] else { return nil }
        return (entry.ips, entry.source)
    }

    func purge(host: String) { cache.removeValue(forKey: host) }
    func purgeAll() { cache.removeAll() }
}
