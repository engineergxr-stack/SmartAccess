import Foundation

/// 可达性诊断报告。是 `SmartAccessError.noReachablePath` 的载荷。
///
/// 客户运维拿到这份报告应该能立刻判断：
///   - DNS 是否出错？
///   - 哪条 path 死在 TCP / TLS / HTTP / WS？
///   - relay 是否也死？
///   - IP 池里哪些 IP 不可达？
public struct ReachabilityReport: Codable, Sendable, Equatable {

    public struct PathAttempt: Codable, Sendable, Equatable {
        public let pathId: String
        public let endpointId: String?
        public let kind: ConnectivityPathKind
        public let stage: ConnectivityStage
        public let success: Bool
        public let errorCode: String?
        public let latencyMs: Int?
        public let attemptedAt: Date

        public init(
            pathId: String,
            endpointId: String?,
            kind: ConnectivityPathKind,
            stage: ConnectivityStage,
            success: Bool,
            errorCode: String?,
            latencyMs: Int?,
            attemptedAt: Date
        ) {
            self.pathId = pathId
            self.endpointId = endpointId
            self.kind = kind
            self.stage = stage
            self.success = success
            self.errorCode = errorCode
            self.latencyMs = latencyMs
            self.attemptedAt = attemptedAt
        }
    }

    public let generatedAt: Date
    public let policyVersion: Int?
    public let attemptedPaths: [PathAttempt]

    public init(generatedAt: Date, policyVersion: Int?, attemptedPaths: [PathAttempt]) {
        self.generatedAt = generatedAt
        self.policyVersion = policyVersion
        self.attemptedPaths = attemptedPaths
    }

    public static let empty = ReachabilityReport(
        generatedAt: Date(timeIntervalSince1970: 0),
        policyVersion: nil,
        attemptedPaths: []
    )
}
