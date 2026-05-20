import Foundation

/// 内部使用的复合 sink：把 metrics event 同时发给客户 sink + 本地日志存储。
///
/// 还做两件事：
/// - 启动早期事件缓冲（在 storage 还没准备好时缓冲，准备好后 flush）；
/// - noReachablePath 升级判定（连续 N 次才发 `noReachablePathEscalated`，避免抖动期刷屏）。
final class CompositeSink: SAMetricsSink, @unchecked Sendable {

    private let customer: SAMetricsSink
    private let storage: SALogStorage
    private let storageEnabled: Bool

    private let lock = NSLock()
    private var consecutiveNoReachable = 0
    private let escalationThreshold = 3

    init(customer: SAMetricsSink, storage: SALogStorage) {
        self.customer = customer
        self.storage = storage
        self.storageEnabled = !(storage is NullLogStorage)
    }

    func emit(_ event: SAMetricsEvent) {
        // 1. 客户 sink（同步）
        customer.emit(event)

        // 2. 本地日志（异步）
        if storageEnabled {
            let log = SADiagnosticLog.from(event)
            Task.detached { [storage] in
                await storage.append(log)
            }
        }

        // 3. noReachablePath 升级
        switch event {
        case .noReachablePath(let report):
            lock.lock()
            consecutiveNoReachable += 1
            let count = consecutiveNoReachable
            let shouldEscalate = count >= escalationThreshold && count % escalationThreshold == 0
            lock.unlock()
            if shouldEscalate {
                let escalation = SAMetricsEvent.noReachablePathEscalated(report, consecutiveCount: count)
                customer.emit(escalation)
                if storageEnabled {
                    let log = SADiagnosticLog.from(escalation)
                    Task.detached { [storage] in await storage.append(log) }
                }
            }
        case .pathSelected, .pathChanged, .reportedSuccess:
            lock.lock()
            consecutiveNoReachable = 0
            lock.unlock()
        default:
            break
        }
    }

    func emitBatch(_ events: [SAMetricsEvent]) {
        customer.emitBatch(events)
        if storageEnabled {
            let logs = events.map { SADiagnosticLog.from($0) }
            Task.detached { [storage] in
                for l in logs { await storage.append(l) }
            }
        }
    }
}
