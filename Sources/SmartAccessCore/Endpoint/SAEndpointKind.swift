import Foundation

/// Endpoint 的协议种类。第一版只支持 http (含 https) 与 websocket (含 wss)。
public enum SAEndpointKind: String, Codable, Sendable, Equatable {
    case http
    case websocket
}
