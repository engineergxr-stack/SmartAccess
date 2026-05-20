import Foundation

/// SmartAccess 启动配置。
///
/// 强约束：
/// - `policyPublicKey` 与 `licensePublicKey` 由发行方在签发 policy / license 时持有私钥，
///   客户 App 内嵌的只是公钥。两者可以是同一把公钥，也可以分开。
/// - 不允许在 config 里塞 endpoint URL；endpoint 必须来自已签名 policy。
public struct SmartAccessConfig: Sendable {

    public let projectId: String
    public let bundleId: String
    public let sdkVersion: String

    public let licenseFileURL: URL
    public let licensePublicKey: String
    public let policyPublicKey: String

    public let seedPolicyFileURL: URL?
    public let cacheDirectoryURL: URL

    public let logger: SALogger
    public let metricsSink: SAMetricsSink

    // V2 新增 ─────────────────────────────────────────────────

    /// 本地结构化日志存储。客户可注入自定义实现，
    /// 默认 `NullLogStorage`（不落盘）。
    /// 想开启文件落盘的话，传 `FileLogStorage(directory: cacheDir.appendingPathComponent("smartaccess/logs"))`。
    public let localLogStorage: SALogStorage

    /// 诊断包导出目录（由 `SmartAccess.shared.exportDiagnosticBundle()` 使用）。
    /// 默认 `<cacheDir>/smartaccess/diagnostics`。
    public let diagnosticExportDirectoryURL: URL

    /// 客户 metrics sink 的最低严重度。`nil` 表示全收。
    /// 例如 `.warn` 只让 sink 收到 warn / error / fatal 事件。
    public let metricsMinSeverity: SASeverity?

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
        metricsSink: SAMetricsSink = NullMetricsSink(),
        localLogStorage: SALogStorage? = nil,
        diagnosticExportDirectoryURL: URL? = nil,
        metricsMinSeverity: SASeverity? = nil
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
        self.localLogStorage = localLogStorage ?? NullLogStorage()
        self.diagnosticExportDirectoryURL = diagnosticExportDirectoryURL
            ?? cacheDirectoryURL.appendingPathComponent("smartaccess/diagnostics", isDirectory: true)
        self.metricsMinSeverity = metricsMinSeverity
    }

    /// 便利方法：开启默认的文件落盘日志。
    public static func withFileLogging(
        baseConfig: SmartAccessConfig,
        rotatingMaxBytes: Int = 5 * 1024 * 1024,
        maxFiles: Int = 3
    ) -> SmartAccessConfig {
        let logDir = baseConfig.cacheDirectoryURL
            .appendingPathComponent("smartaccess/logs", isDirectory: true)
        let storage = FileLogStorage(
            directory: logDir,
            rotatingMaxBytes: rotatingMaxBytes,
            maxFiles: maxFiles
        )
        return SmartAccessConfig(
            projectId: baseConfig.projectId,
            bundleId: baseConfig.bundleId,
            sdkVersion: baseConfig.sdkVersion,
            licenseFileURL: baseConfig.licenseFileURL,
            licensePublicKey: baseConfig.licensePublicKey,
            policyPublicKey: baseConfig.policyPublicKey,
            seedPolicyFileURL: baseConfig.seedPolicyFileURL,
            cacheDirectoryURL: baseConfig.cacheDirectoryURL,
            logger: baseConfig.logger,
            metricsSink: baseConfig.metricsSink,
            localLogStorage: storage,
            diagnosticExportDirectoryURL: baseConfig.diagnosticExportDirectoryURL,
            metricsMinSeverity: baseConfig.metricsMinSeverity
        )
    }
}

/// SDK 版本号常量。发布时同步修改这里 + Package 版本。
public enum SmartAccessVersion {
    public static let current = "2.0.0-beta.1"
}
