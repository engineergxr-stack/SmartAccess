import Foundation

/// SmartAccess 启动配置。
///
/// 强约束：
/// - `policyPublicKey` 与 `licensePublicKey` 由发行方在签发 policy / license 时持有私钥，
///   客户 App 内嵌的只是公钥。两者**可以**是同一把公钥，也**可以**分开。
/// - 不允许在 config 里塞 endpoint URL；endpoint 必须来自已签名 policy。
public struct SmartAccessConfig: Sendable {

    /// 客户在自己后台注册的 projectId，必须与 license / policy 中的 project_id 完全一致。
    public let projectId: String

    /// 当前 App 的 bundleId（默认从 `Bundle.main.bundleIdentifier` 读取）。
    public let bundleId: String

    /// 当前 SDK 版本（用于 license 的 sdk_min/max 校验）。
    public let sdkVersion: String

    /// 内置 license 文件的位置（一般是 Bundle 里的 `SmartAccess.license`）。
    public let licenseFileURL: URL

    /// 用于校验 license 签名的 Ed25519 公钥（base64 或 hex）。
    public let licensePublicKey: String

    /// 用于校验 policy 签名的 Ed25519 公钥（base64 或 hex）。
    public let policyPublicKey: String

    /// 内置 seed policy 的位置（可选，强烈建议提供）。
    public let seedPolicyFileURL: URL?

    /// 缓存目录（用于落盘 cached policy）。默认 Caches 目录。
    public let cacheDirectoryURL: URL

    /// Logger 注入。
    public let logger: SALogger

    /// 度量回调注入。
    public let metricsSink: SAMetricsSink

    public init(
        projectId: String,
        bundleId: String = Bundle.main.bundleIdentifier ?? "unknown.bundle",
        sdkVersion: String = SmartAccessVersion.current,
        licenseFileURL: URL,
        licensePublicKey: String,
        policyPublicKey: String,
        seedPolicyFileURL: URL? = nil,
        cacheDirectoryURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()),
        logger: SALogger = OSLoggerSink(),
        metricsSink: SAMetricsSink = NullMetricsSink()
    ) {
        self.projectId = projectId
        self.bundleId = bundleId
        self.sdkVersion = sdkVersion
        self.licenseFileURL = licenseFileURL
        self.licensePublicKey = licensePublicKey
        self.policyPublicKey = policyPublicKey
        self.seedPolicyFileURL = seedPolicyFileURL
        self.cacheDirectoryURL = cacheDirectoryURL
        self.logger = logger
        self.metricsSink = metricsSink
    }
}

/// SDK 版本号常量。发布时同步修改这里 + Package 版本。
public enum SmartAccessVersion {
    public static let current = "1.0.0"
}
