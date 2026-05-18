import Foundation

/// 客户自托管 HTTPDNS over HTTPS（JSON 协议）。
///
/// 期望请求：
///   GET https://dns.customer.com/resolve?host=api-sg.customer.com
///   返回：
///   { "host": "api-sg.customer.com", "ips": ["1.2.3.4", "1.2.3.5"], "ttl": 60 }
///
/// 如果客户用别的 JSON 形状，需要自己写适配器，而不是改这个文件——SDK 边界要稳定。
struct HTTPDNSResolver: DNSResolver, @unchecked Sendable {

    let id: String
    let source: DNSResult.Source = .httpDNS
    let endpoint: URL
    let session: URLSession

    init(id: String, endpoint: URL, session: URLSession = .shared) {
        self.id = id
        self.endpoint = endpoint
        self.session = session
    }

    func resolve(host: String, timeoutMs: Int) async -> DNSResult {
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "host", value: host))
        comps?.queryItems = items
        guard let url = comps?.url else {
            return DNSResult(host: host, resolverId: id, source: source, ips: [],
                             latencyMs: 0, errorCode: "httpdns.bad_url")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let start = DispatchTime.now()
        do {
            let (data, response) = try await session.data(for: req)
            let elapsed = ms(since: start)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                return DNSResult(host: host, resolverId: id, source: source, ips: [],
                                 latencyMs: elapsed, errorCode: "httpdns.http_\(status)")
            }
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ipsAny = root["ips"] as? [String]
            else {
                return DNSResult(host: host, resolverId: id, source: source, ips: [],
                                 latencyMs: elapsed, errorCode: "httpdns.bad_json")
            }
            return DNSResult(host: host, resolverId: id, source: source, ips: ipsAny,
                             latencyMs: elapsed, errorCode: nil)
        } catch {
            let elapsed = ms(since: start)
            let (_, code) = ErrorClassifier.classify(error)
            return DNSResult(host: host, resolverId: id, source: source, ips: [],
                             latencyMs: elapsed, errorCode: code)
        }
    }

    private func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }
}
