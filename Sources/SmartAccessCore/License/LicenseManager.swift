import Foundation
import CryptoKit

/// 离线 License 校验。
///
/// 启动时一次性 load + verify。运行期通过 `isFeatureEnabled(_:)` 查询能力。
/// 过期后进入 grace 期；超过 grace 进入 disabled。disabled 时 SDK 不 crash，
/// 但所有高级 feature 调用会以 `featureNotLicensed` 拒绝。
actor LicenseManager {

    enum Status: Sendable, Equatable {
        case unloaded
        case valid
        case grace(daysRemaining: Int)
        case expired
        case disabled(reason: String)
    }

    private let publicKey: Curve25519.Signing.PublicKey
    private let bundleId: String
    private let platform: String
    private let sdkVersion: String
    private let log: SALog

    private(set) var status: Status = .unloaded
    private(set) var license: SmartAccessLicense?

    init(
        publicKey: Curve25519.Signing.PublicKey,
        bundleId: String,
        platform: String = "ios",
        sdkVersion: String,
        log: SALog
    ) {
        self.publicKey = publicKey
        self.bundleId = bundleId
        self.platform = platform
        self.sdkVersion = sdkVersion
        self.log = log
    }

    func load(licenseFileURL: URL) async throws {
        guard let data = try? Data(contentsOf: licenseFileURL) else {
            status = .disabled(reason: "license.file_missing")
            throw SmartAccessError.licenseFileMissing
        }
        let envelope = try LicenseEnvelope.decode(from: data)

        guard SignatureVerifier.verifyEd25519(
            data: envelope.canonicalLicenseBytes,
            signature: envelope.signature,
            publicKey: publicKey
        ) else {
            status = .disabled(reason: "license.signature_invalid")
            throw SmartAccessError.licenseSignatureInvalid
        }

        let lic = envelope.license

        // bundle id
        if !lic.bundleIds.isEmpty, !lic.bundleIds.contains(bundleId) {
            status = .disabled(reason: "license.bundle_mismatch")
            throw SmartAccessError.licenseBundleMismatch(expected: lic.bundleIds.joined(separator: ","), actual: bundleId)
        }

        // platform
        if !lic.platforms.isEmpty, !lic.platforms.contains(platform) {
            status = .disabled(reason: "license.platform_mismatch")
            throw SmartAccessError.licensePlatformMismatch
        }

        // sdk version range
        if !semverInRange(sdkVersion, min: lic.sdkMinVersion, max: lic.sdkMaxVersion) {
            status = .disabled(reason: "license.sdk_version_unsupported")
            throw SmartAccessError.licenseSDKVersionUnsupported
        }

        // expiration / grace
        let now = Date()
        let graceUntil = lic.expiresAt.addingTimeInterval(TimeInterval(lic.graceDays) * 86_400)
        if now <= lic.expiresAt {
            status = .valid
        } else if now <= graceUntil {
            let daysLeft = max(0, Int(graceUntil.timeIntervalSince(now) / 86_400))
            status = .grace(daysRemaining: daysLeft)
            log.warn("license.grace days_remaining=\(daysLeft)")
        } else {
            status = .expired
            license = lic
            throw SmartAccessError.licenseGracePeriodExceeded
        }

        license = lic
        log.info("license.loaded customer=\(lic.customer) project=\(lic.projectId) status=\(status)")
    }

    func isFeatureEnabled(_ feature: String) -> Bool {
        switch status {
        case .valid, .grace:
            return license?.features.contains(feature) ?? false
        case .expired, .disabled, .unloaded:
            return false
        }
    }

    func currentLicense() -> SmartAccessLicense? { license }

    private func semverInRange(_ v: String, min: String, max: String) -> Bool {
        compare(v, min) >= 0 && compare(v, max) <= 0
    }

    private func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = Swift.max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
