import Foundation

/// 客户 App 内置的离线 License 内容。
public struct SmartAccessLicense: Codable, Sendable, Equatable {

    public let licenseId: String
    public let customer: String
    public let projectId: String
    public let platforms: [String]    // 例如 ["ios"]
    public let bundleIds: [String]    // 允许的 bundle id 列表
    public let features: [String]     // 已购功能：例如 ["relay", "websocket_check", "ip_pool"]
    public let maxEndpoints: Int
    public let issuedAt: Date
    public let expiresAt: Date
    public let graceDays: Int
    public let sdkMinVersion: String
    public let sdkMaxVersion: String

    private enum CodingKeys: String, CodingKey {
        case licenseId      = "license_id"
        case customer
        case projectId      = "project_id"
        case platforms
        case bundleIds      = "bundle_ids"
        case features
        case maxEndpoints   = "max_endpoints"
        case issuedAt       = "issued_at"
        case expiresAt      = "expires_at"
        case graceDays      = "grace_days"
        case sdkMinVersion  = "sdk_min_version"
        case sdkMaxVersion  = "sdk_max_version"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.licenseId      = try c.decode(String.self, forKey: .licenseId)
        self.customer       = try c.decode(String.self, forKey: .customer)
        self.projectId      = try c.decode(String.self, forKey: .projectId)
        self.platforms      = try c.decode([String].self, forKey: .platforms)
        self.bundleIds      = try c.decode([String].self, forKey: .bundleIds)
        self.features       = try c.decodeIfPresent([String].self, forKey: .features) ?? []
        self.maxEndpoints   = try c.decodeIfPresent(Int.self, forKey: .maxEndpoints) ?? 32
        let issued          = try c.decode(Double.self, forKey: .issuedAt)
        let expires         = try c.decode(Double.self, forKey: .expiresAt)
        self.issuedAt       = Date(timeIntervalSince1970: issued)
        self.expiresAt      = Date(timeIntervalSince1970: expires)
        self.graceDays      = try c.decodeIfPresent(Int.self, forKey: .graceDays) ?? 7
        self.sdkMinVersion  = try c.decodeIfPresent(String.self, forKey: .sdkMinVersion) ?? "0.0.0"
        self.sdkMaxVersion  = try c.decodeIfPresent(String.self, forKey: .sdkMaxVersion) ?? "99.99.99"
    }

    public init(
        licenseId: String,
        customer: String,
        projectId: String,
        platforms: [String],
        bundleIds: [String],
        features: [String],
        maxEndpoints: Int,
        issuedAt: Date,
        expiresAt: Date,
        graceDays: Int,
        sdkMinVersion: String,
        sdkMaxVersion: String
    ) {
        self.licenseId = licenseId
        self.customer = customer
        self.projectId = projectId
        self.platforms = platforms
        self.bundleIds = bundleIds
        self.features = features
        self.maxEndpoints = maxEndpoints
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.graceDays = graceDays
        self.sdkMinVersion = sdkMinVersion
        self.sdkMaxVersion = sdkMaxVersion
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(licenseId, forKey: .licenseId)
        try c.encode(customer,  forKey: .customer)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(platforms, forKey: .platforms)
        try c.encode(bundleIds, forKey: .bundleIds)
        try c.encode(features,  forKey: .features)
        try c.encode(maxEndpoints, forKey: .maxEndpoints)
        try c.encode(issuedAt.timeIntervalSince1970,  forKey: .issuedAt)
        try c.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAt)
        try c.encode(graceDays, forKey: .graceDays)
        try c.encode(sdkMinVersion, forKey: .sdkMinVersion)
        try c.encode(sdkMaxVersion, forKey: .sdkMaxVersion)
    }
}

/// License 已知的能力位。SDK 内部用，便于代码静态引用。
enum SALicenseFeature {
    static let relay            = "relay"
    static let webSocketCheck   = "websocket_check"
    static let ipPool           = "ip_pool"
    static let httpDNS          = "httpdns"
    static let doh              = "doh"
    static let staticDNS        = "static_dns"
    static let remotePolicy     = "remote_policy"
    static let metrics          = "metrics"
}
