import Foundation
import Network

/// Relay 专用 IP 直连 HTTP/1.1 客户端。
///
/// 设计边界（务必读完再用）：
/// - **只用于客户自建的 Relay endpoint**。不要拿来发业务源站请求——业务源站走 URLSession 域名访问。
/// - SNI、Host 头、证书校验全部按 hostname 走，不会因为连的是 IP 就泄漏出去。
/// - HTTP/1.1 only。每个请求一条连接，不复用（避免引入 keep-alive 状态管理）。
/// - 不跟随重定向。Relay 收到 3xx 必须立刻报错给业务层。
/// - 不解压响应。客户业务层自行处理 gzip 等。
public struct RelayDirectTransport: Sendable {

    public struct Response: Sendable {
        public let statusCode: Int
        public let headers: [(String, String)]
        public let body: Data
    }

    public struct Request: Sendable {
        public let method: String
        public let path: String           // 含 query，例如 "/v1/orders?limit=20"
        public let headers: [(String, String)]
        public let body: Data?
        public init(method: String, path: String, headers: [(String, String)] = [], body: Data? = nil) {
            self.method = method
            self.path = path
            self.headers = headers
            self.body = body
        }
    }

    public enum DirectError: Error, Equatable {
        case timeout(stage: ConnectivityStage)
        case tcpFailed(String)
        case tlsFailed(String)
        case sendFailed(String)
        case readFailed(String)
        case parseFailed(String)
    }

    /// 发起一次请求。
    /// - Parameters:
    ///   - ip: 实际建连 IP（来自 HTTPDNS / IPPool）
    ///   - port: 端口（443 默认）
    ///   - hostname: 原始 Relay 域名，用于 SNI / Host 头 / 证书校验
    ///   - request: HTTP 请求
    ///   - pinnedSPKIHashes: 可选 SPKI pinning
    ///   - timeoutMs: 整体超时
    public func send(
        ip: String,
        port: UInt16 = 443,
        hostname: String,
        request: Request,
        pinnedSPKIHashes: [String] = [],
        timeoutMs: Int = 10_000
    ) async throws -> Response {

        // 1. 准备 TLS options，强制 SNI = hostname，证书校验按 hostname
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, hostname)
        let verify = TLSVerifier.makeVerifyBlock(hostname: hostname, pinnedSPKIHashes: pinnedSPKIHashes)
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            verify,
            DispatchQueue.global(qos: .userInitiated)
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = max(1, timeoutMs / 1000)

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.preferNoProxies = true   // 直连，不走系统代理

        let endpoint = NWEndpoint.hostPort(host: .init(ip), port: .init(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: parameters)

        // 2. 建连
        try await waitForReady(connection, timeoutMs: timeoutMs)

        // 3. 发请求
        let raw = buildRequestBytes(request: request, hostname: hostname)
        try await sendBytes(connection, data: raw, timeoutMs: timeoutMs)

        // 4. 读响应
        let responseData = try await readResponse(connection, timeoutMs: timeoutMs)

        // 5. 关闭
        connection.cancel()

        // 6. 解析
        do {
            let parsed = try HTTPParser.parse(responseData)
            return Response(statusCode: parsed.statusCode, headers: parsed.headers, body: parsed.body)
        } catch {
            throw DirectError.parseFailed("\(error)")
        }
    }

    // MARK: - Private

    private func waitForReady(_ conn: NWConnection, timeoutMs: Int) async throws {
        let flag = ResumeFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if flag.swap(true) { cont.resume() }
                case .failed(let err):
                    if flag.swap(true) {
                        let mapped = mapNWError(err)
                        cont.resume(throwing: mapped)
                    }
                case .cancelled:
                    if flag.swap(true) {
                        cont.resume(throwing: DirectError.tcpFailed("cancelled"))
                    }
                default:
                    break
                }
            }
            // 超时兜底
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                if flag.swap(true) {
                    conn.cancel()
                    cont.resume(throwing: DirectError.timeout(stage: .tls))
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    private func sendBytes(_ conn: NWConnection, data: Data, timeoutMs: Int) async throws {
        let flag = ResumeFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if flag.swap(true) {
                    if let err = err {
                        cont.resume(throwing: DirectError.sendFailed("\(err)"))
                    } else {
                        cont.resume()
                    }
                }
            })
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                if flag.swap(true) {
                    cont.resume(throwing: DirectError.timeout(stage: .http))
                }
            }
        }
    }

    private func readResponse(_ conn: NWConnection, timeoutMs: Int) async throws -> Data {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        var buffer = Data()
        // 简单循环读：当看到 \r\n\r\n（header 结束）后，根据 Content-Length / chunked
        // 决定还需要读多少。这里走更保守的方案：一直读到连接关闭或超时，
        // 然后让 HTTPParser 统一处理。
        while Date() < deadline {
            let chunk = try await receiveChunk(conn, timeoutMs: max(100, Int(deadline.timeIntervalSinceNow * 1000)))
            if chunk.isEmpty { break }
            buffer.append(chunk)
            // 尝试解析一次：如果能成功解析说明已经够了
            if buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil,
               (try? HTTPParser.parse(buffer)) != nil {
                return buffer
            }
        }
        guard !buffer.isEmpty else {
            throw DirectError.timeout(stage: .http)
        }
        return buffer
    }

    private func receiveChunk(_ conn: NWConnection, timeoutMs: Int) async throws -> Data {
        let flag = ResumeFlag()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, err in
                if flag.swap(true) {
                    if let err = err {
                        cont.resume(throwing: DirectError.readFailed("\(err)"))
                    } else if isComplete && (data?.isEmpty ?? true) {
                        cont.resume(returning: Data())
                    } else {
                        cont.resume(returning: data ?? Data())
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                if flag.swap(true) {
                    cont.resume(throwing: DirectError.timeout(stage: .http))
                }
            }
        }
    }

    private func buildRequestBytes(request: Request, hostname: String) -> Data {
        var lines: [String] = []
        lines.append("\(request.method.uppercased()) \(request.path) HTTP/1.1")
        lines.append("Host: \(hostname)")
        lines.append("User-Agent: SmartAccessSDK/2.0 RelayDirect")
        lines.append("Connection: close")
        lines.append("Accept: */*")
        if let body = request.body {
            lines.append("Content-Length: \(body.count)")
        }
        for (k, v) in request.headers {
            // 不让调用者用自己的 Host / Connection / Content-Length 覆盖我们
            let lower = k.lowercased()
            if lower == "host" || lower == "connection" || lower == "content-length" { continue }
            lines.append("\(k): \(v)")
        }
        var data = lines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
        data.append(contentsOf: [0x0D, 0x0A, 0x0D, 0x0A])
        if let body = request.body { data.append(body) }
        return data
    }

    private func mapNWError(_ err: NWError) -> DirectError {
        switch err {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .tcpFailed("tcp.connection_refused")
            case .ECONNRESET:   return .tcpFailed("tcp.connection_reset")
            case .EHOSTUNREACH: return .tcpFailed("tcp.host_unreachable")
            case .ENETUNREACH:  return .tcpFailed("tcp.net_unreachable")
            case .ETIMEDOUT:    return .timeout(stage: .tcp)
            default:            return .tcpFailed("posix.\(code.rawValue)")
            }
        case .tls(let status):
            return .tlsFailed("tls.osstatus_\(status)")
        case .dns(let code):
            return .tcpFailed("dns.\(code)")
        @unknown default:
            return .tcpFailed("nwerror.unknown")
        }
    }
}
