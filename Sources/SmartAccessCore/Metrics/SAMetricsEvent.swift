import Foundation

/// 事件严重度。客户 sink 可按此过滤。
public enum SASeverity: Int, Sendable, Comparable, Codable {
    case debug = 0
    case info  = 1
    case warn  = 2
    case error = 3
    case fatal = 4

    public static func < (lhs: SASeverity, rhs: SASeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 度量事件。
///
/// SDK 自己不上报任何后台。事件只通过 `SAMetricsSink.emit` 回调给客户埋点系统。
/// V2 增加：severity、Relay 兜底事件、policy 刷新结果、诊断包导出。
public enum SAMetricsEvent: Sendable {
    case startupBegan
    case startupCompleted(durationMs: Int, selectedPathId: String?)
    case startupTimedOut(durationMs: Int)
    case pathSelected(pathId: String, kind: ConnectivityPathKind)
    case pathChanged(fromPathId: String?, toPathId: String, reason: String)
    case probeResult(ConnectivityResult)
    case dnsDiagnostic(DNSDiagnosticReport)
    case dnsResolutionUpdated(host: String, source: DNSResult.Source, ipCount: Int)  // V2
    case ipPoolDiagnostic(host: String, results: [IPConnectivityResult])
    case policyUpdated(version: Int, source: String)
    case policyRejected(reason: String)
    case licenseDegraded(reason: String)
    case noReachablePath(ReachabilityReport)
    case noReachablePathEscalated(ReachabilityReport, consecutiveCount: Int)         // V2
    case relaySelectedAsFailover(pathId: String, reason: String)                     // V2
    case relayPromoted(reason: String)                                               // V2
    case circuitBreakerOpened(endpointId: String, openSeconds: Int)                  // V2
    case circuitBreakerHalfOpenProbed(endpointId: String, success: Bool)             // V2
    case reportedSuccess(endpointId: String, latencyMs: Int)
    case reportedFailure(endpointId: String, errorCode: String, stage: ConnectivityStage)
    case diagnosticBundleExported(path: String, sizeBytes: Int)                     // V2
}

extension SAMetricsEvent {

    /// 事件的默认严重度。客户 sink 可以按此过滤，也可以全收。
    public var severity: SASeverity {
        switch self {
        case .startupBegan, .startupCompleted, .pathSelected:                       return .info
        case .startupTimedOut:                                                       return .warn
        case .pathChanged:                                                           return .info
        case .probeResult(let r):                                                    return r.success ? .debug : .warn
        case .dnsDiagnostic, .dnsResolutionUpdated:                                  return .debug
        case .ipPoolDiagnostic:                                                      return .debug
        case .policyUpdated:                                                         return .info
        case .policyRejected:                                                        return .warn
        case .licenseDegraded:                                                       return .warn
        case .noReachablePath:                                                       return .error
        case .noReachablePathEscalated:                                              return .fatal
        case .relaySelectedAsFailover, .relayPromoted:                               return .warn
        case .circuitBreakerOpened:                                                  return .warn
        case .circuitBreakerHalfOpenProbed:                                          return .debug
        case .reportedSuccess:                                                       return .debug
        case .reportedFailure:                                                       return .warn
        case .diagnosticBundleExported:                                              return .info
        }
    }

    /// 简短的事件名（用于结构化日志的 `event` 字段，便于聚合）。
    public var name: String {
        switch self {
        case .startupBegan:                          return "startup.began"
        case .startupCompleted:                      return "startup.completed"
        case .startupTimedOut:                       return "startup.timeout"
        case .pathSelected:                          return "path.selected"
        case .pathChanged:                           return "path.changed"
        case .probeResult:                           return "probe.result"
        case .dnsDiagnostic:                         return "dns.diagnostic"
        case .dnsResolutionUpdated:                  return "dns.resolved"
        case .ipPoolDiagnostic:                      return "ip_pool.diagnostic"
        case .policyUpdated:                         return "policy.updated"
        case .policyRejected:                        return "policy.rejected"
        case .licenseDegraded:                       return "license.degraded"
        case .noReachablePath:                       return "connectivity.no_reachable_path"
        case .noReachablePathEscalated:              return "connectivity.no_reachable_path_escalated"
        case .relaySelectedAsFailover:               return "relay.failover_selected"
        case .relayPromoted:                         return "relay.promoted"
        case .circuitBreakerOpened:                  return "breaker.opened"
        case .circuitBreakerHalfOpenProbed:          return "breaker.half_open_probe"
        case .reportedSuccess:                       return "report.success"
        case .reportedFailure:                       return "report.failure"
        case .diagnosticBundleExported:              return "diagnostic.bundle_exported"
        }
    }
}

/// Sink 协议。客户实现这个协议把事件转发到自己的埋点 / Sentry / Datadog。
///
/// 默认 `emit(_:)` 单条；可选实现 `emitBatch(_:)` 批量。
public protocol SAMetricsSink: Sendable {
    func emit(_ event: SAMetricsEvent)
    /// 默认实现遍历调用 emit；客户可重写以减少请求数。
    func emitBatch(_ events: [SAMetricsEvent])
}

public extension SAMetricsSink {
    func emitBatch(_ events: [SAMetricsEvent]) {
        for e in events { emit(e) }
    }
}

/// 默认空实现。
public struct NullMetricsSink: SAMetricsSink {
    public init() {}
    public func emit(_ event: SAMetricsEvent) {}
}

/// 按严重度过滤的包装。
public struct FilteredMetricsSink: SAMetricsSink {
    public let minSeverity: SASeverity
    public let wrapped: SAMetricsSink
    public init(minSeverity: SASeverity, wrapped: SAMetricsSink) {
        self.minSeverity = minSeverity
        self.wrapped = wrapped
    }
    public func emit(_ event: SAMetricsEvent) {
        guard event.severity >= minSeverity else { return }
        wrapped.emit(event)
    }
    public func emitBatch(_ events: [SAMetricsEvent]) {
        let filtered = events.filter { $0.severity >= minSeverity }
        guard !filtered.isEmpty else { return }
        wrapped.emitBatch(filtered)
    }
}
