import Foundation

/// DNS 解析结果。
public struct DNSResult: Codable, Sendable, Equatable {

    public enum Source: String, Codable, Sendable, Equatable {
        case system
        case httpDNS
        case doh
        case staticMap
    }

    public let host: String
    public let resolverId: String
    public let source: Source
    public let ips: [String]
    public let latencyMs: Int
    public let resolvedAt: Date
    public let errorCode: String?

    public init(
        host: String,
        resolverId: String,
        source: Source,
        ips: [String],
        latencyMs: Int,
        resolvedAt: Date = Date(),
        errorCode: String? = nil
    ) {
        self.host = host
        self.resolverId = resolverId
        self.source = source
        self.ips = ips
        self.latencyMs = latencyMs
        self.resolvedAt = resolvedAt
        self.errorCode = errorCode
    }

    public var success: Bool { !ips.isEmpty && errorCode == nil }
}

/// 一次 DNS 诊断的汇总报告（多个 resolver 并行解析后合并）。
public struct DNSDiagnosticReport: Codable, Sendable, Equatable {
    public let host: String
    public let results: [DNSResult]
    public let generatedAt: Date

    public init(host: String, results: [DNSResult], generatedAt: Date = Date()) {
        self.host = host
        self.results = results
        self.generatedAt = generatedAt
    }
}
