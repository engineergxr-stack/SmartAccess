import Foundation

/// 诊断包：客户在用户报问题时调一次 `SmartAccess.shared.exportDiagnosticBundle()`，
/// 拿到一个本地目录，里面包含：
///
///   - manifest.json                 ← bundle 元信息（policy version、license id 脱敏、SDK 版本、生成时间）
///   - reachability.json             ← 最近一次 ReachabilityReport
///   - logs.current.ndjson           ← 最近的日志（每行一条 JSON）
///   - logs.1.ndjson, logs.2.ndjson  ← 已轮转的日志（按顺序）
///
/// 客户上传到自己的工单系统时，可以选择整个目录打 zip（用 NSFileCoordinator 或者三方库），
/// SDK 不内置 zip 依赖。
public struct DiagnosticBundle: Sendable {

    public struct Manifest: Codable, Sendable {
        public let sdkVersion: String
        public let bundleId: String
        public let projectId: String
        public let policyVersion: Int?
        public let licenseIdMasked: String
        public let generatedAt: Date
        public let platform: String  // "ios"
        public let osVersion: String
    }

    public let directory: URL
    public let files: [URL]
    public let manifest: Manifest

    public var totalBytes: Int {
        let fm = FileManager.default
        return files.compactMap { url -> Int? in
            (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int)
        }.reduce(0, +)
    }
}

/// 构建诊断包。
enum DiagnosticBundleBuilder {

    static func build(
        targetDirectory: URL,
        storage: SALogStorage,
        report: ReachabilityReport,
        sdkVersion: String,
        bundleId: String,
        projectId: String,
        policyVersion: Int?,
        licenseId: String?
    ) async throws -> DiagnosticBundle {

        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let outDir = targetDirectory.appendingPathComponent("diagnostic-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        var files: [URL] = []

        // 1. reachability.json
        let reachURL = outDir.appendingPathComponent("reachability.json")
        let reachEnc = JSONEncoder()
        reachEnc.outputFormatting = [.prettyPrinted, .sortedKeys]
        reachEnc.dateEncodingStrategy = .iso8601
        let reachData = try reachEnc.encode(report)
        try reachData.write(to: reachURL, options: [.atomic])
        files.append(reachURL)

        // 2. logs
        let logFiles = try await storage.export(to: outDir)
        files.append(contentsOf: logFiles)

        // 3. manifest.json
        let manifest = DiagnosticBundle.Manifest(
            sdkVersion: sdkVersion,
            bundleId: bundleId,
            projectId: projectId,
            policyVersion: policyVersion,
            licenseIdMasked: maskLicenseId(licenseId),
            generatedAt: Date(),
            platform: "ios",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        let manifestURL = outDir.appendingPathComponent("manifest.json")
        let manEnc = JSONEncoder()
        manEnc.outputFormatting = [.prettyPrinted, .sortedKeys]
        manEnc.dateEncodingStrategy = .iso8601
        let manData = try manEnc.encode(manifest)
        try manData.write(to: manifestURL, options: [.atomic])
        files.append(manifestURL)

        return DiagnosticBundle(directory: outDir, files: files, manifest: manifest)
    }

    /// license id 脱敏：只显示前 4 后 4。
    private static func maskLicenseId(_ id: String?) -> String {
        guard let id = id, id.count > 8 else { return "***" }
        let prefix = id.prefix(4)
        let suffix = id.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}
