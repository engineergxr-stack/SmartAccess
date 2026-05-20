import Foundation

/// 单条结构化日志。
///
/// 所有字段都必须是稳定字符串或简单可序列化的值，**绝不**包含：
/// - URLRequest.httpBody
/// - URLRequest.allHTTPHeaderFields 整体
/// - Authorization / Cookie / Set-Cookie / X-Auth-Token 等敏感 header
/// - 任何 token / secret / password 字样的字段
/// - 完整 URL 的 query 字符串（query 参数可能含 token，全部丢弃）
///
/// 这些规则在 `RedactionFilter.swift` 里有单测保证。
public struct SADiagnosticLog: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let severity: SASeverity
    public let event: String
    public let fields: [String: String]

    public init(timestamp: Date = Date(), severity: SASeverity, event: String, fields: [String: String] = [:]) {
        self.timestamp = timestamp
        self.severity = severity
        self.event = event
        self.fields = fields
    }

    /// 一行 JSON 序列化（用于 FileLogStorage 落盘）。
    public func toJSONLine() -> Data {
        let dto = DTO(
            ts: ISO8601DateFormatter.smartAccessFormatter.string(from: timestamp),
            severity: severity.rawValue,
            event: event,
            fields: fields
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = (try? encoder.encode(dto)) ?? Data()
        data.append(0x0A) // newline
        return data
    }

    /// 从一行 JSON 解析（用于读取诊断文件回放）。
    public static func parse(_ data: Data) -> SADiagnosticLog? {
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data) else { return nil }
        let date = ISO8601DateFormatter.smartAccessFormatter.date(from: dto.ts) ?? Date(timeIntervalSince1970: 0)
        return SADiagnosticLog(
            timestamp: date,
            severity: SASeverity(rawValue: dto.severity) ?? .info,
            event: dto.event,
            fields: dto.fields
        )
    }

    private struct DTO: Codable {
        let ts: String
        let severity: Int
        let event: String
        let fields: [String: String]
    }
}

extension ISO8601DateFormatter {
    static let smartAccessFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Event → SADiagnosticLog 转换

extension SADiagnosticLog {

    /// 把 `SAMetricsEvent` 转换成可落盘的结构化日志条目。
    /// 转换过程经过 `RedactionFilter`，确保不会带出敏感字段。
    public static func from(_ event: SAMetricsEvent, at timestamp: Date = Date()) -> SADiagnosticLog {
        let fields = RedactionFilter.fields(for: event)
        return SADiagnosticLog(
            timestamp: timestamp,
            severity: event.severity,
            event: event.name,
            fields: fields
        )
    }
}
