import Foundation

/// 对 HTTP endpoint 的 /healthy 路径做一次性探测。
///
/// 边界：
/// - 不解析 body，只看 status code（2xx 成功）。
/// - 不跟随重定向（避免污染路径选择）。
/// - 不写自定义 SNI / Host，让系统按 URL 处理。
/// - 不关闭 TLS 校验。
struct HTTPHealthChecker: @unchecked Sendable {

    private let session: URLSession

    init(sessionConfig: URLSessionConfiguration? = nil) {
        let config = sessionConfig ?? {
            let c = URLSessionConfiguration.ephemeral
            c.allowsCellularAccess = true
            c.waitsForConnectivity = false
            c.httpShouldUsePipelining = false
            c.httpAdditionalHeaders = ["User-Agent": "SmartAccessSDK/1.0 HealthChecker"]
            return c
        }()
        // 不跟随重定向
        self.session = URLSession(
            configuration: config,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    /// 探测一次。
    /// - Parameters:
    ///   - endpoint: 必须是 kind == .http 的 endpoint。
    ///   - timeoutMs: 单次超时。
    func probe(endpoint: SAEndpoint, timeoutMs: Int) async -> SAHealthResult {
        guard endpoint.kind == .http, let url = endpoint.healthURL else {
            return .failure(stage: .http, errorCode: "endpoint.invalid_for_http_probe")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let start = DispatchTime.now()

        do {
            let (_, response) = try await session.data(for: request)
            let elapsedMs = elapsedMilliseconds(since: start)

            guard let http = response as? HTTPURLResponse else {
                return .failure(stage: .http, errorCode: "http.no_response", latencyMs: elapsedMs)
            }

            if (200..<300).contains(http.statusCode) {
                return .success(stage: .http, latencyMs: elapsedMs)
            } else if (500..<600).contains(http.statusCode) {
                return .failure(stage: .server, errorCode: "http.\(http.statusCode)", latencyMs: elapsedMs)
            } else {
                return .failure(stage: .healthBody, errorCode: "http.\(http.statusCode)", latencyMs: elapsedMs)
            }
        } catch {
            let elapsedMs = elapsedMilliseconds(since: start)
            let (stage, code) = ErrorClassifier.classify(error)
            return .failure(stage: stage, errorCode: code, latencyMs: elapsedMs)
        }
    }

    private func elapsedMilliseconds(since start: DispatchTime) -> Int {
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        return Int(elapsedNs / 1_000_000)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // 不跟随重定向；当作 3xx 响应返回上层处理
        completionHandler(nil)
    }
}
