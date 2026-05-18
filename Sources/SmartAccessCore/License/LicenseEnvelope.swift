import Foundation

/// 已签名 License 的外层 envelope。
/// JSON 结构：
/// ```
/// {
///   "license": { ... },
///   "signature": "base64_ed25519_signature_of_canonical_license_bytes"
/// }
/// ```
public struct LicenseEnvelope: Sendable, Equatable {

    public let license: SmartAccessLicense
    public let signature: Data
    public let canonicalLicenseBytes: Data

    public init(license: SmartAccessLicense, signature: Data, canonicalLicenseBytes: Data) {
        self.license = license
        self.signature = signature
        self.canonicalLicenseBytes = canonicalLicenseBytes
    }

    public static func decode(from data: Data) throws -> LicenseEnvelope {
        guard
            let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let licenseDict = root["license"] as? [String: Any],
            let sigBase64 = root["signature"] as? String,
            let signature = Data(base64Encoded: sigBase64)
        else {
            throw SmartAccessError.licenseDecodeFailed(reason: "envelope_malformed")
        }

        let canonical: Data
        do {
            canonical = try JSONSerialization.data(withJSONObject: licenseDict, options: [.sortedKeys])
        } catch {
            throw SmartAccessError.licenseDecodeFailed(reason: "canonicalize_failed: \(error.localizedDescription)")
        }

        let decoder = JSONDecoder()
        let license: SmartAccessLicense
        do {
            license = try decoder.decode(SmartAccessLicense.self, from: canonical)
        } catch {
            throw SmartAccessError.licenseDecodeFailed(reason: "license_decode_failed: \(error)")
        }

        return LicenseEnvelope(
            license: license,
            signature: signature,
            canonicalLicenseBytes: canonical
        )
    }
}
