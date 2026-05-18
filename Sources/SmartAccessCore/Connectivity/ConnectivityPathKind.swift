import Foundation

/// 连接路径种类。最终被 `PathSelector` 选中的不是单纯 endpoint，而是一种 `ConnectivityPath`。
public enum ConnectivityPathKind: String, Codable, Sendable, Equatable {
    case directDomain
    case backupDomain
    case dnsResolved
    case staticIP
    case relay
}
