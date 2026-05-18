import Foundation

/// 从客户自托管 policy URL 拉取已签名 policy。
///
/// 多个 config_sources 按 priority 串行尝试（priority 越小越先），第一个 200 即停。
/// 没有任何 source 返回 200，则抛 `policyAllSourcesUnreachable`。
struct RemotePolicyProvider: @unchecked Sendable {

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let s = session {
            self.session = s
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 5
            c.timeoutIntervalForResource = 10
            c.allowsCellularAccess = true
            c.httpAdditionalHeaders = ["User-Agent": "SmartAccessSDK/1.0 PolicyFetcher"]
            self.session = URLSession(configuration: c)
        }
    }

    /// 拉取一份新的 envelope + rawBytes。rawBytes 用于写入磁盘缓存（不重新序列化以保留签名一致性）。
    func fetch(from sources: [ConfigSource]) async throws -> (PolicyEnvelope, Data) {
        let enabled = sources.filter { $0.enabled }.sorted { $0.priority < $1.priority }
        guard !enabled.isEmpty else {
            throw SmartAccessError.policyAllSourcesUnreachable
        }

        var lastError: Error?
        for source in enabled {
            do {
                var req = URLRequest(url: source.url)
                req.httpMethod = "GET"
                req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    lastError = SmartAccessError.policyDecodeFailed(reason: "http_\(status) from \(source.id)")
                    continue
                }
                let envelope = try PolicyEnvelope.decode(from: data)
                return (envelope, data)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? SmartAccessError.policyAllSourcesUnreachable
    }
}
