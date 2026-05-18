import Foundation

/// DNS Resolver 协议。所有具体 resolver 都实现这个协议。
protocol DNSResolver: Sendable {
    var id: String { get }
    var source: DNSResult.Source { get }

    /// 解析。如果失败，应返回 errorCode 非空的 `DNSResult`（而不是抛错），便于多 resolver 并发汇总。
    func resolve(host: String, timeoutMs: Int) async -> DNSResult
}
