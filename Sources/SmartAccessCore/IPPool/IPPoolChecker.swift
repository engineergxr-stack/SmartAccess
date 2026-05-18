import Foundation
import Network

/// IP 池可达性诊断。
///
/// 用 `Network.framework` 的 `NWConnection` 对每个 IP 做 TCP + TLS 握手，
/// 成功完成 TLS 握手即视为该 IP 在网络层可达。
///
/// 强约束：
/// - 必须保留正确 SNI（来自 `IPPool.tlsServerName`），不得关闭 TLS 校验。
/// - 不发送任何 HTTP body，只用于诊断。
/// - 这个文件**不会**把业务请求改写为 https://IP；那是 advanced / limited 能力，
///   需要客户专门评估证书、Host 头、CDN 动态 IP 等问题。
struct IPPoolChecker: Sendable {

    /// 单 IP 诊断。
    func probe(host: String, ip: String, port: UInt16 = 443, tlsServerName: String, timeoutMs: Int) async -> IPConnectivityResult {
        let endpoint = NWEndpoint.hostPort(
            host: .init(ip),
            port: .init(rawValue: port)!
        )

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, tlsServerName)
        // 不能 disable 校验：保持默认 trust 评估

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = max(1, timeoutMs / 1000)

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.preferNoProxies = true   // 不走系统代理

        let connection = NWConnection(to: endpoint, using: params)
        let start = DispatchTime.now()

        return await withCheckedContinuation { (cont: CheckedContinuation<IPConnectivityResult, Never>) in
            let resumed = ResumeFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = elapsedMs(since: start)
                    if resumed.swap(true) {
                        connection.cancel()
                        cont.resume(returning: IPConnectivityResult(
                            host: host, ip: ip, stage: .tls, success: true,
                            latencyMs: elapsed, errorCode: nil
                        ))
                    }
                case .failed(let err):
                    let elapsed = elapsedMs(since: start)
                    let (stage, code) = classifyNWError(err)
                    if resumed.swap(true) {
                        connection.cancel()
                        cont.resume(returning: IPConnectivityResult(
                            host: host, ip: ip, stage: stage, success: false,
                            latencyMs: elapsed, errorCode: code
                        ))
                    }
                case .cancelled:
                    if resumed.swap(true) {
                        let elapsed = elapsedMs(since: start)
                        cont.resume(returning: IPConnectivityResult(
                            host: host, ip: ip, stage: .tcp, success: false,
                            latencyMs: elapsed, errorCode: "cancelled"
                        ))
                    }
                default:
                    break
                }
            }

            // 超时兜底
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                if resumed.swap(true) {
                    let elapsed = elapsedMs(since: start)
                    connection.cancel()
                    cont.resume(returning: IPConnectivityResult(
                        host: host, ip: ip, stage: .tcp, success: false,
                        latencyMs: elapsed, errorCode: "timeout"
                    ))
                }
            }

            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    /// 探测一个 IP 池里全部 IP（并发，受 parallelLimit 限制）。
    func probePool(_ pool: IPPool, timeoutMs: Int, parallelLimit: Int = 3) async -> [IPConnectivityResult] {
        let limit = max(1, parallelLimit)
        let semaphore = AsyncSemaphore(value: limit)
        return await withTaskGroup(of: IPConnectivityResult.self) { group in
            for ip in pool.ips {
                group.addTask {
                    await semaphore.wait()
                    let r = await self.probe(
                        host: pool.host,
                        ip: ip,
                        tlsServerName: pool.tlsServerName,
                        timeoutMs: timeoutMs
                    )
                    await semaphore.signal()
                    return r
                }
            }
            var out: [IPConnectivityResult] = []
            for await r in group { out.append(r) }
            return out
        }
    }
}

// MARK: - Helpers

private func elapsedMs(since start: DispatchTime) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
}

private func classifyNWError(_ err: NWError) -> (ConnectivityStage, String) {
    switch err {
    case .posix(let code):
        switch code {
        case .ECONNREFUSED: return (.tcp, "tcp.connection_refused")
        case .ECONNRESET:   return (.tcp, "tcp.connection_reset")
        case .EHOSTUNREACH: return (.tcp, "tcp.host_unreachable")
        case .ENETUNREACH:  return (.tcp, "tcp.net_unreachable")
        case .ETIMEDOUT:    return (.tcp, "tcp.timeout")
        default:            return (.tcp, "posix.\(code.rawValue)")
        }
    case .tls(let status):
        return (.tls, "tls.osstatus_\(status)")
    case .dns(let code):
        return (.dns, "dns.\(code)")
    @unknown default:
        return (.unknown, "nwerror.unknown")
    }
}

/// 简单的 actor 信号量。
final class AsyncSemaphore: @unchecked Sendable {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    init(value: Int) { self.count = value }

    func wait() async {
        lock.lock()
        if count > 0 {
            count -= 1
            lock.unlock()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
            lock.unlock()
        }
    }

    func signal() async {
        lock.lock()
        if let w = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            w.resume()
        } else {
            count += 1
            lock.unlock()
        }
    }
}

/// 一次性 resume 标志，避免多次 resume。
final class ResumeFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    /// 返回 true 表示「现在轮到你 resume」。
    func swap(_ newValue: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = newValue
        return true
    }
}
