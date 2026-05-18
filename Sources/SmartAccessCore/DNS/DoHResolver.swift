import Foundation

/// DNS over HTTPS（JSON 风格，RFC 8484 wire 也支持 application/dns-json）。
///
/// 期望请求：GET https://doh.customer.com/dns-query?name=<host>&type=A
/// Accept: application/dns-json
/// 返回：{ "Status": 0, "Answer": [ { "name": ..., "type": 1, "TTL": 60, "data": "1.2.3.4" }, ... ] }
struct DoHResolver: DNSResolver, @unchecked Sendable {

    let id: String
    let source: DNSResult.Source = .doh
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
        items.append(URLQueryItem(name: "name", value: host))
        items.append(URLQueryItem(name: "type", value: "A"))
        comps?.queryItems = items
        guard let url = comps?.url else {
            return DNSResult(host: host, resolverId: id, source: source, ips: [],
                             latencyMs: 0, errorCode: "doh.bad_url")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let start = DispatchTime.now()
        do {
            let (data, response) = try await session.data(for: req)
            let elapsed = elapsedMs(since: start)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                return DNSResult(host: host, resolverId: id, source: source, ips: [],
                                 latencyMs: elapsed, errorCode: "doh.http_\(status)")
            }

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return DNSResult(host: host, resolverId: id, source: source, ips: [],
                                 latencyMs: elapsed, errorCode: "doh.bad_json")
            }
            let answers = (root["Answer"] as? [[String: Any]]) ?? []
            let ips = answers.compactMap { item -> String? in
                // type 1 = A record
                guard let type = item["type"] as? Int, type == 1, let data = item["data"] as? String else { return nil }
                return data
            }
            return DNSResult(host: host, resolverId: id, source: source, ips: ips,
                             latencyMs: elapsed, errorCode: ips.isEmpty ? "doh.no_answer" : nil)
        } catch {
            let elapsed = elapsedMs(since: start)
            let (_, code) = ErrorClassifier.classify(error)
            return DNSResult(host: host, resolverId: id, source: source, ips: [],
                             latencyMs: elapsed, errorCode: code)
        }
    }

    private func elapsedMs(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }
}
