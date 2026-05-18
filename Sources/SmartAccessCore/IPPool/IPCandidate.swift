import Foundation

/// 探测时单个 IP 候选的运行期状态。
struct IPCandidate: Sendable, Equatable {
    let host: String
    let ip: String
    let tlsServerName: String
    let hostHeader: String

    var lastProbeAt: Date?
    var lastStage: ConnectivityStage?
    var lastSuccess: Bool?
    var lastLatencyMs: Int?
    var lastErrorCode: String?
}
