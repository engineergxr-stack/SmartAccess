import Foundation

/// SmartAccess 启动模式。
///
/// - fastWarmup: 推荐。`maxWaitMs` 内若已选出可用 path 立即返回，否则用 `lastGoodPath` / seed policy 立刻返回，
///   后台继续 warmup，完成后通过 `onPathChange` 通知客户。
/// - fullWarmup: 阻塞等待所有 path 探测完成或 `timeoutMs` 触发，适合可控冷启动场景。
/// - lazy: `start()` 立即返回，warmup 在首次取 `currentBaseURL()` 或第一次 `reportFailure` 时按需触发。
public enum SmartAccessStartupMode: Equatable, Sendable {
    case fastWarmup(maxWaitMs: Int = 500)
    case fullWarmup(timeoutMs: Int = 3000)
    case lazy
}
