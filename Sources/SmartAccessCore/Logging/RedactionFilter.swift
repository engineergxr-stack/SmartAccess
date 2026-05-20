import Foundation

/// 把 `SAMetricsEvent` 转成可落盘的 fields 字典，全程过滤敏感数据。
///
/// 规则：
/// - 永不写入 URLRequest.httpBody / Authorization / Cookie / Set-Cookie / X-Auth-Token；
/// - URL 字段只保留 host + 路径模板（无 query、无 fragment）；
/// - 不写入任何含 `token / secret / password / authorization / api[_-]?key` 字样的字段名（大小写不敏感）；
/// - errorCode 是稳定字符串，可写入；underlying NSError.userInfo 整体不写。
public enum RedactionFilter {

    /// banlist。出现在 header 名或自定义 field 名里的关键字会被屏蔽。
    static let bannedKeywords: [String] = [
        "authorization",
        "cookie",
        "set-cookie",
        "x-auth-token",
        "x-api-key",
        "api-key",
        "apikey",
        "secret",
        "password",
        "passwd",
        "token",
        "session",
        "csrf"
    ]

    /// 公开方法：把任意 key 经过 banlist 判断。
    public static func isFieldNameAllowed(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !bannedKeywords.contains { lower.contains($0) }
    }

    /// 把任意字符串截断到 max（避免日志被长 URL / 错误消息撑爆）。
    static func truncated(_ s: String, max: Int = 256) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[s.startIndex..<idx]) + "…"
    }

    /// 把 URL 脱敏成 "host + 路径模板"（去掉 query、fragment、userinfo）。
    public static func sanitize(url: URL) -> String {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.fragment = nil
        comps?.user = nil
        comps?.password = nil
        return comps?.url?.absoluteString ?? url.host ?? "<url>"
    }

    /// 用户提供的自定义 fields 经过 banlist 过滤后写出。
    public static func sanitize(fields: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in fields {
            guard isFieldNameAllowed(k) else { continue }
            out[k] = truncated(v)
        }
        return out
    }

    /// SAMetricsEvent → fields。
    static func fields(for event: SAMetricsEvent) -> [String: String] {
        switch event {

        case .startupBegan:
            return [:]

        case .startupCompleted(let ms, let pid):
            return ["duration_ms": String(ms), "selected_path_id": pid ?? ""]

        case .startupTimedOut(let ms):
            return ["duration_ms": String(ms)]

        case .pathSelected(let pid, let kind):
            return ["path_id": pid, "kind": kind.rawValue]

        case .pathChanged(let from, let to, let reason):
            return ["from": from ?? "", "to": to, "reason": truncated(reason)]

        case .probeResult(let r):
            return [
                "path_id": r.pathId,
                "endpoint_id": r.endpointId ?? "",
                "kind": r.kind.rawValue,
                "success": r.success ? "true" : "false",
                "stage": r.stage.rawValue,
                "latency_ms": r.latencyMs.map(String.init) ?? "",
                "error_code": r.errorCode ?? ""
            ]

        case .dnsDiagnostic(let report):
            return [
                "host": report.host,
                "resolver_count": String(report.results.count),
                "successful_resolvers": String(report.results.filter(\.success).count)
            ]

        case .dnsResolutionUpdated(let host, let source, let count):
            return ["host": host, "source": source.rawValue, "ip_count": String(count)]

        case .ipPoolDiagnostic(let host, let results):
            return [
                "host": host,
                "ip_count": String(results.count),
                "healthy_count": String(results.filter(\.success).count)
            ]

        case .policyUpdated(let v, let source):
            return ["version": String(v), "source": source]

        case .policyRejected(let reason):
            return ["reason": truncated(reason)]

        case .licenseDegraded(let reason):
            return ["reason": truncated(reason)]

        case .noReachablePath(let report):
            return [
                "path_attempts": String(report.attemptedPaths.count),
                "policy_version": report.policyVersion.map(String.init) ?? ""
            ]

        case .noReachablePathEscalated(let report, let count):
            return [
                "consecutive_count": String(count),
                "path_attempts": String(report.attemptedPaths.count)
            ]

        case .relaySelectedAsFailover(let pid, let reason):
            return ["path_id": pid, "reason": truncated(reason)]

        case .relayPromoted(let reason):
            return ["reason": truncated(reason)]

        case .circuitBreakerOpened(let id, let secs):
            return ["endpoint_id": id, "open_seconds": String(secs)]

        case .circuitBreakerHalfOpenProbed(let id, let success):
            return ["endpoint_id": id, "success": success ? "true" : "false"]

        case .reportedSuccess(let id, let latency):
            return ["endpoint_id": id, "latency_ms": String(latency)]

        case .reportedFailure(let id, let code, let stage):
            return ["endpoint_id": id, "error_code": code, "stage": stage.rawValue]

        case .diagnosticBundleExported(let path, let size):
            return ["path": sanitize(url: URL(fileURLWithPath: path)), "size_bytes": String(size)]
        }
    }
}
