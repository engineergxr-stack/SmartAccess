import Foundation

/// 连接过程的阶段。一次失败必须落到某个 stage，方便客户运维定位。
public enum ConnectivityStage: String, Codable, Sendable, Equatable {
    case dns          // 域名解析阶段失败
    case tcp          // TCP 建连阶段失败
    case tls          // TLS 握手阶段失败
    case http         // HTTP 请求阶段失败（如 timeout，连接被重置）
    case ws           // WebSocket 握手阶段失败
    case healthBody   // 收到响应但 /healthy 内容/状态码不符合预期
    case server       // 服务器明确返回 5xx
    case unknown      // 未分类
}
