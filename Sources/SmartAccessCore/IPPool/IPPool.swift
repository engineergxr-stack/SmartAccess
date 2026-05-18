import Foundation

/// 来自 policy 的 IP 池配置。
///
/// `tlsServerName` 与 `hostHeader` 必须由客户在 policy 中显式给出，
/// SDK 在 IP 直连诊断时会保留这些语义（SNI 与 Host），不允许关闭 TLS 校验。
public struct IPPool: Codable, Sendable, Equatable {

    public let host: String
    public let ips: [String]
    public let tlsServerName: String
    public let hostHeader: String

    public init(host: String, ips: [String], tlsServerName: String, hostHeader: String) {
        self.host = host
        self.ips = ips
        self.tlsServerName = tlsServerName
        self.hostHeader = hostHeader
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case ips
        case tlsServerName = "tls_server_name"
        case hostHeader    = "host_header"
    }
}
