import Foundation

/// WebSocket 连接可达性探测。
///
/// 严格只做连接检查：握手 → 发一帧 ping → 收 pong → close。
/// 不做业务订阅，不保留长连接，不做断线重连。
struct WebSocketConnectivityChecker: @unchecked Sendable {

    private let session: URLSession

    init(sessionConfig: URLSessionConfiguration? = nil) {
        let config = sessionConfig ?? {
            let c = URLSessionConfiguration.ephemeral
            c.allowsCellularAccess = true
            c.waitsForConnectivity = false
            return c
        }()
        self.session = URLSession(configuration: config)
    }

    /// 探测一次。
    /// - Parameters:
    ///   - endpoint: 必须是 kind == .websocket。
    ///   - timeoutMs: 整体握手+ping 超时。
    func probe(endpoint: SAEndpoint, timeoutMs: Int) async -> SAHealthResult {
        guard endpoint.kind == .websocket else {
            return .failure(stage: .ws, errorCode: "endpoint.invalid_for_ws_probe")
        }

        var req = URLRequest(url: endpoint.url)
        req.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        let task = session.webSocketTask(with: req)

        let start = DispatchTime.now()

        do {
            // 用 Task 包一层做整体超时
            return try await withThrowingTaskGroup(of: SAHealthResult.self) { group in
                group.addTask {
                    await self.handshakeAndPing(task: task, start: start)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    return .failure(stage: .ws, errorCode: "ws.timeout", latencyMs: timeoutMs)
                }

                if let first = try await group.next() {
                    group.cancelAll()
                    task.cancel(with: .normalClosure, reason: nil)
                    return first
                }
                return .failure(stage: .ws, errorCode: "ws.no_result")
            }
        } catch {
            let elapsed = elapsedMs(since: start)
            let (stage, code) = ErrorClassifier.classify(error)
            task.cancel(with: .abnormalClosure, reason: nil)
            return .failure(stage: stage == .unknown ? .ws : stage, errorCode: code, latencyMs: elapsed)
        }
    }

    private func handshakeAndPing(task: URLSessionWebSocketTask, start: DispatchTime) async -> SAHealthResult {
        task.resume()
        // 发一条空 ping，sendPing 闭包回调即代表握手已成功
        return await withCheckedContinuation { (continuation: CheckedContinuation<SAHealthResult, Never>) in
            task.sendPing { error in
                let elapsed = self.elapsedMs(since: start)
                if let error = error {
                    let (stage, code) = ErrorClassifier.classify(error)
                    continuation.resume(returning: .failure(stage: stage == .unknown ? .ws : stage, errorCode: code, latencyMs: elapsed))
                } else {
                    continuation.resume(returning: .success(stage: .ws, latencyMs: elapsed))
                }
            }
        }
    }

    private func elapsedMs(since start: DispatchTime) -> Int {
        let ns = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        return Int(ns / 1_000_000)
    }
}
