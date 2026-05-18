import Foundation

/// Endpoint 的角色。
///
/// - direct: 直连域名 endpoint。优先级最高，PathSelector 默认偏好。
/// - backup: 备用域名 endpoint。direct 失败或 latency 显著恶化时启用。
/// - relay:  客户自建 Relay / Gateway endpoint。SDK 不托管，仅作为一种 ConnectivityPath 候选。
///
/// 注意：SmartAccess 永远不会托管 relay。relay 由客户自建、自运维、自合规，
/// 且必须固定 upstream、路径白名单、不得开放代理。
public enum SAEndpointRole: String, Codable, Sendable, Equatable {
    case direct
    case backup
    case relay
}
