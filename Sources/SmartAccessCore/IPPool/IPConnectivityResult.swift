import Foundation

/// IP 池单次诊断结果。
public struct IPConnectivityResult: Codable, Sendable, Equatable {
    public let host: String
    public let ip: String
    public let stage: ConnectivityStage   // 死在 .tcp / .tls，成功为 .tls（握手完成即视为可达）
    public let success: Bool
    public let latencyMs: Int?
    public let errorCode: String?
    public let probedAt: Date

    public init(
        host: String,
        ip: String,
        stage: ConnectivityStage,
        success: Bool,
        latencyMs: Int?,
        errorCode: String?,
        probedAt: Date = Date()
    ) {
        self.host = host
        self.ip = ip
        self.stage = stage
        self.success = success
        self.latencyMs = latencyMs
        self.errorCode = errorCode
        self.probedAt = probedAt
    }
}
