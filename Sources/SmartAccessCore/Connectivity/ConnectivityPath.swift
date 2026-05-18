import Foundation

/// 连接路径。`PathSelector` 最终选择的对象。
///
/// 注意：`baseURL` 是 SDK 在该路径下应该让客户网络层使用的 URL。
/// - 对于 directDomain / backupDomain / relay：baseURL 即 endpoint.url。
/// - 对于 dnsResolved / staticIP：baseURL 可能仍为域名 URL（保留 SNI/Host 语义），
///   IP 仅作为诊断信息保存在 `metadata["resolvedIP"]`。
///   第一版默认不把业务请求改写为 https://IP，原因见 README 中的「DNS/IP 限制说明」。
public struct ConnectivityPath: Sendable, Equatable, Identifiable {

    public let id: String
    public let kind: ConnectivityPathKind
    public let baseURL: URL
    public let endpointId: String?
    public let priority: Int
    public let metadata: [String: String]

    public init(
        id: String,
        kind: ConnectivityPathKind,
        baseURL: URL,
        endpointId: String?,
        priority: Int,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL
        self.endpointId = endpointId
        self.priority = priority
        self.metadata = metadata
    }
}
