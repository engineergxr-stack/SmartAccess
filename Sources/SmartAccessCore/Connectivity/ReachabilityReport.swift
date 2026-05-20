import Foundation

/// 可达性诊断报告。
///
/// V2 升级：
/// - 增加 `groups: [String: [PathAttempt]]`（direct / backup / relay 分组），便于客户运维快速判断
/// - 增加 `selection`：当前选中 path + 选中原因（如 `relay_promoted_all_direct_failed_dns_or_tcp`）
/// - 增加 `dnsSnapshot`：每个域名的当前 DNS 解析快照（来自 DNSCache）
public struct ReachabilityReport: Codable, Sendable, Equatable {

    public struct PathAttempt: Codable, Sendable, Equatable {
        public let pathId: String
        public let endpointId: String?
        public let kind: ConnectivityPathKind
        public let stage: ConnectivityStage
        public let success: Bool
        public let errorCode: String?
        public let latencyMs: Int?
        public let attemptedAt: Date
        public let group: String?   // V2 新增：来自 endpoint.group

        public init(
            pathId: String,
            endpointId: String?,
            kind: ConnectivityPathKind,
            stage: ConnectivityStage,
            success: Bool,
            errorCode: String?,
            latencyMs: Int?,
            attemptedAt: Date,
            group: String? = nil
        ) {
            self.pathId = pathId
            self.endpointId = endpointId
            self.kind = kind
            self.stage = stage
            self.success = success
            self.errorCode = errorCode
            self.latencyMs = latencyMs
            self.attemptedAt = attemptedAt
            self.group = group
        }
    }

    /// V2: 当前选中 path 的描述。
    public struct Selection: Codable, Sendable, Equatable {
        public let pathId: String?
        public let kind: ConnectivityPathKind?
        public let reason: String

        public init(pathId: String?, kind: ConnectivityPathKind?, reason: String) {
            self.pathId = pathId
            self.kind = kind
            self.reason = reason
        }
    }

    /// V2: DNS 解析快照。
    public struct DNSSnapshot: Codable, Sendable, Equatable {
        public let host: String
        public let source: DNSResult.Source
        public let ips: [String]

        public init(host: String, source: DNSResult.Source, ips: [String]) {
            self.host = host
            self.source = source
            self.ips = ips
        }
    }

    public let generatedAt: Date
    public let policyVersion: Int?
    public let attemptedPaths: [PathAttempt]
    public let selection: Selection
    public let dnsSnapshots: [DNSSnapshot]

    public init(
        generatedAt: Date,
        policyVersion: Int?,
        attemptedPaths: [PathAttempt],
        selection: Selection = .init(pathId: nil, kind: nil, reason: "unknown"),
        dnsSnapshots: [DNSSnapshot] = []
    ) {
        self.generatedAt = generatedAt
        self.policyVersion = policyVersion
        self.attemptedPaths = attemptedPaths
        self.selection = selection
        self.dnsSnapshots = dnsSnapshots
    }

    public static let empty = ReachabilityReport(
        generatedAt: Date(timeIntervalSince1970: 0),
        policyVersion: nil,
        attemptedPaths: []
    )

    // V2 视图：按 kind 分组方便 UI / 日志展示。
    public var attemptsByKind: [ConnectivityPathKind: [PathAttempt]] {
        Dictionary(grouping: attemptedPaths, by: { $0.kind })
    }
}
