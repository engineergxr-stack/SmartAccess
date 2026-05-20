import Foundation

/// 从 policy 解码出来的 endpoint 模型。
///
/// SDK 不接受任何运行时硬编码 endpoint，所有 endpoint 必须来自已签名 policy。
public struct SAEndpoint: Codable, Sendable, Equatable, Identifiable {

    /// Relay IP 直连模式（仅 role == .relay 时有意义）。
    public enum DirectIPMode: String, Codable, Sendable, Equatable {
        case off       // 永不用 IP 直连，纯走 URLSession 域名访问
        case fallback  // 默认。系统 DNS 失败才走 IP 直连
        case always    // 始终走 HTTPDNS + IP 直连
    }

    public let id: String
    public let url: URL
    public let kind: SAEndpointKind
    public let role: SAEndpointRole
    public let healthPath: String?
    public let priority: Int
    public let enabled: Bool
    public let metadata: [String: String]

    // V2 新增
    public let group: String?              // 物理隔离分组（AS / cloud / region），同 group 默认视为同时挂的风险体
    public let directIPMode: DirectIPMode  // 仅 role == .relay 有意义

    public init(
        id: String,
        url: URL,
        kind: SAEndpointKind,
        role: SAEndpointRole,
        healthPath: String? = nil,
        priority: Int = 100,
        enabled: Bool = true,
        metadata: [String: String] = [:],
        group: String? = nil,
        directIPMode: DirectIPMode = .off
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.role = role
        self.healthPath = healthPath
        self.priority = priority
        self.enabled = enabled
        self.metadata = metadata
        self.group = group
        self.directIPMode = directIPMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, kind, role
        case healthPath = "health_path"
        case priority, enabled, metadata
        case group
        case directIPMode = "direct_ip_mode"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.url = try c.decode(URL.self, forKey: .url)
        self.kind = try c.decode(SAEndpointKind.self, forKey: .kind)
        self.role = try c.decode(SAEndpointRole.self, forKey: .role)
        self.healthPath = try c.decodeIfPresent(String.self, forKey: .healthPath)
        self.priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 100
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        self.group = try c.decodeIfPresent(String.self, forKey: .group)
        self.directIPMode = try c.decodeIfPresent(DirectIPMode.self, forKey: .directIPMode)
            ?? (self.role == .relay ? .fallback : .off)
    }

    /// 拼接 healthPath 后的完整探测 URL。仅对 kind == .http 有意义。
    public var healthURL: URL? {
        guard kind == .http else { return nil }
        guard let path = healthPath, !path.isEmpty else { return url }
        if path.hasPrefix("/") {
            return url.appendingPathComponent(String(path.dropFirst()))
        }
        return url.appendingPathComponent(path)
    }
}
