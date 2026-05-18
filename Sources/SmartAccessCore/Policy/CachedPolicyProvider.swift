import Foundation

/// 磁盘上的 policy 缓存读写。
///
/// 路径：`<cacheDir>/smartaccess/policy.signed.json`
/// 权限：尽量 0600（iOS 上 sandbox 已经够安全，仍保留 setAttributes 以求一致）。
actor CachedPolicyProvider {

    private let fileURL: URL

    init(cacheDirectoryURL: URL) {
        let dir = cacheDirectoryURL.appendingPathComponent("smartaccess", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.fileURL = dir.appendingPathComponent("policy.signed.json")
    }

    func load() -> PolicyEnvelope? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? PolicyEnvelope.decode(from: data)
    }

    func save(rawSignedBytes: Data) throws {
        try rawSignedBytes.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
