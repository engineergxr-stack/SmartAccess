import Foundation

/// Probe（HTTP / WebSocket）的底层返回类型，调用方再适配成 `ConnectivityResult`。
struct SAHealthResult: Sendable, Equatable {
    let success: Bool
    let stage: ConnectivityStage
    let latencyMs: Int?
    let errorCode: String?

    static func success(stage: ConnectivityStage = .http, latencyMs: Int) -> SAHealthResult {
        SAHealthResult(success: true, stage: stage, latencyMs: latencyMs, errorCode: nil)
    }

    static func failure(stage: ConnectivityStage, errorCode: String, latencyMs: Int? = nil) -> SAHealthResult {
        SAHealthResult(success: false, stage: stage, latencyMs: latencyMs, errorCode: errorCode)
    }
}
