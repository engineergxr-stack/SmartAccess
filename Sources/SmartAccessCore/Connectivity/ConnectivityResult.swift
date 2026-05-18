import Foundation

/// 单次 Probe 的结果。
public struct ConnectivityResult: Sendable, Equatable {
    public let pathId: String
    public let endpointId: String?
    public let kind: ConnectivityPathKind
    public let success: Bool
    public let stage: ConnectivityStage
    public let latencyMs: Int?
    public let errorCode: String?
    public let timestamp: Date

    public init(
        pathId: String,
        endpointId: String?,
        kind: ConnectivityPathKind,
        success: Bool,
        stage: ConnectivityStage,
        latencyMs: Int?,
        errorCode: String?,
        timestamp: Date = Date()
    ) {
        self.pathId = pathId
        self.endpointId = endpointId
        self.kind = kind
        self.success = success
        self.stage = stage
        self.latencyMs = latencyMs
        self.errorCode = errorCode
        self.timestamp = timestamp
    }
}
