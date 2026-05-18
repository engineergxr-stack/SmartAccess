import Foundation

/// 从 App Bundle 读取内置的 seed policy。
struct SeedPolicyProvider: Sendable {

    let fileURL: URL?

    /// - Parameter fileURL: 客户在 SmartAccessConfig 里给的 seed policy 文件位置（Bundle 内）。
    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    func loadEnvelope() async -> PolicyEnvelope? {
        guard let url = fileURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PolicyEnvelope.decode(from: data)
    }
}
