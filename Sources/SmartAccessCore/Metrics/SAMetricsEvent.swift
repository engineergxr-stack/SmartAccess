import Foundation

/// 度量事件。
///
/// SDK 自己不上报任何后台。事件只通过 `SmartAccessConfig.metricsSink` 回调给客户埋点系统。
public enum SAMetricsEvent: Sendable {
    case startupBegan
    case startupCompleted(durationMs: Int, selectedPathId: String?)
    case startupTimedOut(durationMs: Int)
    case pathSelected(pathId: String, kind: ConnectivityPathKind)
    case pathChanged(fromPathId: String?, toPathId: String, reason: String)
    case probeResult(ConnectivityResult)
    case dnsDiagnostic(DNSDiagnosticReport)
    case ipPoolDiagnostic(host: String, results: [IPConnectivityResult])
    case policyUpdated(version: Int, source: String)
    case policyRejected(reason: String)
    case licenseDegraded(reason: String)
    case noReachablePath(ReachabilityReport)
    case reportedSuccess(endpointId: String, latencyMs: Int)
    case reportedFailure(endpointId: String, errorCode: String, stage: ConnectivityStage)
}

/// Sink 协议。客户实现这个协议把事件转发到自己的埋点 / Sentry / Datadog。
public protocol SAMetricsSink: Sendable {
    func emit(_ event: SAMetricsEvent)
}

/// 默认空实现。
public struct NullMetricsSink: SAMetricsSink {
    public init() {}
    public func emit(_ event: SAMetricsEvent) {}
}
