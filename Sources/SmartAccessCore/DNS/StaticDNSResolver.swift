import Foundation

/// 来自 policy 的 host→IP 静态映射，作为最后兜底。
struct StaticDNSResolver: DNSResolver {

    let id: String
    let source: DNSResult.Source = .staticMap
    private let map: [String: [String]]

    init(id: String, map: [String: [String]]) {
        self.id = id
        self.map = map
    }

    func resolve(host: String, timeoutMs: Int) async -> DNSResult {
        let ips = map[host] ?? []
        return DNSResult(
            host: host,
            resolverId: id,
            source: source,
            ips: ips,
            latencyMs: 0,
            errorCode: ips.isEmpty ? "static.no_entry" : nil
        )
    }
}
