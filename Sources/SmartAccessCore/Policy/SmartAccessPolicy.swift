import Foundation

/// 客户自托管 policy.json 的 Codable 镜像。
///
/// SDK 不接受未签名 policy。policy 整体作为 envelope 的一部分进行签名校验。
public struct SmartAccessPolicy: Codable, Sendable, Equatable {

    // MARK: - Top-level

    public let projectId: String
    public let version: Int
    public let issuedAt: Date
    public let expiresAt: Date

    public let configSources: [ConfigSource]
    public let endpoints: [SAEndpoint]
    public let dnsStrategy: DNSStrategy?
    public let ipPools: [IPPool]
    public let healthCheck: HealthCheckConfig
    public let websocketCheck: WebSocketCheckConfig
    public let retry: RetryConfig
    public let circuitBreaker: CircuitBreakerConfig

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case projectId      = "project_id"
        case version
        case issuedAt       = "issued_at"
        case expiresAt      = "expires_at"
        case configSources  = "config_sources"
        case endpoints
        case dnsStrategy    = "dns_strategy"
        case ipPools        = "ip_pools"
        case healthCheck    = "health_check"
        case websocketCheck = "websocket_check"
        case retry
        case circuitBreaker = "circuit_breaker"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.projectId = try c.decode(String.self, forKey: .projectId)
        self.version   = try c.decode(Int.self, forKey: .version)

        // issued_at / expires_at 在 JSON 中是 epoch seconds
        let issued = try c.decode(Double.self, forKey: .issuedAt)
        let expires = try c.decode(Double.self, forKey: .expiresAt)
        self.issuedAt  = Date(timeIntervalSince1970: issued)
        self.expiresAt = Date(timeIntervalSince1970: expires)

        self.configSources  = try c.decodeIfPresent([ConfigSource].self,  forKey: .configSources) ?? []
        self.endpoints      = try c.decode([SAEndpoint].self, forKey: .endpoints)
        self.dnsStrategy    = try c.decodeIfPresent(DNSStrategy.self,     forKey: .dnsStrategy)
        self.ipPools        = try c.decodeIfPresent([IPPool].self,        forKey: .ipPools) ?? []
        self.healthCheck    = try c.decodeIfPresent(HealthCheckConfig.self, forKey: .healthCheck) ?? .default
        self.websocketCheck = try c.decodeIfPresent(WebSocketCheckConfig.self, forKey: .websocketCheck) ?? .default
        self.retry          = try c.decodeIfPresent(RetryConfig.self,     forKey: .retry) ?? .default
        self.circuitBreaker = try c.decodeIfPresent(CircuitBreakerConfig.self, forKey: .circuitBreaker) ?? .default
    }

    public init(
        projectId: String,
        version: Int,
        issuedAt: Date,
        expiresAt: Date,
        configSources: [ConfigSource],
        endpoints: [SAEndpoint],
        dnsStrategy: DNSStrategy?,
        ipPools: [IPPool],
        healthCheck: HealthCheckConfig = .default,
        websocketCheck: WebSocketCheckConfig = .default,
        retry: RetryConfig = .default,
        circuitBreaker: CircuitBreakerConfig = .default
    ) {
        self.projectId = projectId
        self.version = version
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.configSources = configSources
        self.endpoints = endpoints
        self.dnsStrategy = dnsStrategy
        self.ipPools = ipPools
        self.healthCheck = healthCheck
        self.websocketCheck = websocketCheck
        self.retry = retry
        self.circuitBreaker = circuitBreaker
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(version,   forKey: .version)
        try c.encode(issuedAt.timeIntervalSince1970,  forKey: .issuedAt)
        try c.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAt)
        try c.encode(configSources,  forKey: .configSources)
        try c.encode(endpoints,      forKey: .endpoints)
        try c.encodeIfPresent(dnsStrategy, forKey: .dnsStrategy)
        try c.encode(ipPools,        forKey: .ipPools)
        try c.encode(healthCheck,    forKey: .healthCheck)
        try c.encode(websocketCheck, forKey: .websocketCheck)
        try c.encode(retry,          forKey: .retry)
        try c.encode(circuitBreaker, forKey: .circuitBreaker)
    }
}

// MARK: - Nested config types

public struct ConfigSource: Codable, Sendable, Equatable {
    public let id: String
    public let url: URL
    public let priority: Int
    public let enabled: Bool

    public init(id: String, url: URL, priority: Int = 100, enabled: Bool = true) {
        self.id = id
        self.url = url
        self.priority = priority
        self.enabled = enabled
    }
}

public struct DNSStrategy: Codable, Sendable, Equatable {

    public enum Mode: String, Codable, Sendable, Equatable {
        case systemFirst   = "system_first"
        case fallbackFirst = "fallback_first"
        case diagnosticOnly = "diagnostic_only"
    }

    public struct Resolver: Codable, Sendable, Equatable {

        public enum Kind: String, Codable, Sendable, Equatable {
            case httpsJson = "https_json"
            case doh
            case staticMap = "static"
        }

        public let id: String
        public let type: Kind
        public let url: URL?
        public let map: [String: [String]]?

        public init(id: String, type: Kind, url: URL? = nil, map: [String: [String]]? = nil) {
            self.id = id
            self.type = type
            self.url = url
            self.map = map
        }
    }

    public let mode: Mode
    public let fallbackResolvers: [Resolver]
    public let diagnosticOnly: Bool

    private enum CodingKeys: String, CodingKey {
        case mode
        case fallbackResolvers = "fallback_resolvers"
        case diagnosticOnly    = "diagnostic_only"
    }

    public init(mode: Mode = .systemFirst, fallbackResolvers: [Resolver] = [], diagnosticOnly: Bool = true) {
        self.mode = mode
        self.fallbackResolvers = fallbackResolvers
        self.diagnosticOnly = diagnosticOnly
    }
}

public struct HealthCheckConfig: Codable, Sendable, Equatable {
    public let timeoutMs: Int
    public let startupMaxWaitMs: Int
    public let parallelLimit: Int

    private enum CodingKeys: String, CodingKey {
        case timeoutMs        = "timeout_ms"
        case startupMaxWaitMs = "startup_max_wait_ms"
        case parallelLimit    = "parallel_limit"
    }

    public init(timeoutMs: Int = 2000, startupMaxWaitMs: Int = 500, parallelLimit: Int = 3) {
        self.timeoutMs = timeoutMs
        self.startupMaxWaitMs = startupMaxWaitMs
        self.parallelLimit = parallelLimit
    }

    public static let `default` = HealthCheckConfig()
}

public struct WebSocketCheckConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let timeoutMs: Int

    private enum CodingKeys: String, CodingKey {
        case enabled
        case timeoutMs = "timeout_ms"
    }

    public init(enabled: Bool = true, timeoutMs: Int = 3000) {
        self.enabled = enabled
        self.timeoutMs = timeoutMs
    }

    public static let `default` = WebSocketCheckConfig()
}

public struct RetryConfig: Codable, Sendable, Equatable {
    public let maxAttempts: Int
    public let retryMethods: [String]

    private enum CodingKeys: String, CodingKey {
        case maxAttempts  = "max_attempts"
        case retryMethods = "retry_methods"
    }

    public init(maxAttempts: Int = 2, retryMethods: [String] = ["GET", "HEAD"]) {
        self.maxAttempts = maxAttempts
        self.retryMethods = retryMethods
    }

    public static let `default` = RetryConfig()
}

public struct CircuitBreakerConfig: Codable, Sendable, Equatable {
    public let failureThreshold: Int
    public let openSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case failureThreshold = "failure_threshold"
        case openSeconds      = "open_seconds"
    }

    public init(failureThreshold: Int = 2, openSeconds: Int = 60) {
        self.failureThreshold = failureThreshold
        self.openSeconds = openSeconds
    }

    public static let `default` = CircuitBreakerConfig()
}
