import Foundation

/// Endpoint 的运行期状态（不持久化，由 `EndpointManager` 在内存中维护）。
struct SAEndpointState: Sendable, Equatable {
    var lastProbeAt: Date?
    var lastLatencyMs: Int?
    var emaLatencyMs: Double?
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var consecutiveFailures: Int
    var consecutiveSuccesses: Int
    var lastErrorCode: String?
    var lastErrorStage: ConnectivityStage?
    var breakerOpenUntil: Date?
    // V2: half-open 探针
    var nextHalfOpenProbeAt: Date?

    init() {
        self.lastProbeAt = nil
        self.lastLatencyMs = nil
        self.emaLatencyMs = nil
        self.lastSuccessAt = nil
        self.lastFailureAt = nil
        self.consecutiveFailures = 0
        self.consecutiveSuccesses = 0
        self.lastErrorCode = nil
        self.lastErrorStage = nil
        self.breakerOpenUntil = nil
        self.nextHalfOpenProbeAt = nil
    }

    /// 指数加权平均 latency，α 默认 0.3（新值权重）。
    mutating func recordLatency(_ ms: Int, alpha: Double = 0.3) {
        lastLatencyMs = ms
        if let prev = emaLatencyMs {
            emaLatencyMs = alpha * Double(ms) + (1 - alpha) * prev
        } else {
            emaLatencyMs = Double(ms)
        }
    }

    var isBreakerOpen: Bool {
        guard let until = breakerOpenUntil else { return false }
        return until > Date()
    }
}
