import Foundation

/// 已签名 policy 的外层 envelope。
///
/// JSON 结构：
/// ```
/// {
///   "policy": { ... },
///   "signature": "base64_ed25519_signature_of_the_canonical_policy_bytes"
/// }
/// ```
///
/// 签名规则：对 `policy` 对象用 JSONEncoder.OutputFormatting = [.sortedKeys] 序列化后的字节计算 Ed25519 签名。
/// SDK 在校验时也必须以同样的方式重新序列化再校验，不能依赖原始字节流（避免格式差异）。
public struct PolicyEnvelope: Sendable, Equatable {

    public let policy: SmartAccessPolicy
    public let signature: Data           // 64 bytes Ed25519 signature
    public let canonicalPolicyBytes: Data // 用于复核签名所用的标准化字节

    public init(policy: SmartAccessPolicy, signature: Data, canonicalPolicyBytes: Data) {
        self.policy = policy
        self.signature = signature
        self.canonicalPolicyBytes = canonicalPolicyBytes
    }

    /// 从 raw JSON Data 解析。
    /// - Parameter data: 原始 JSON 字节。
    /// - Returns: envelope。SDK 调用方（PolicyResolver）随后调用 `SignatureVerifier.verifyEd25519(...)` 校验签名。
    public static func decode(from data: Data) throws -> PolicyEnvelope {
        guard
            let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let policyDict = root["policy"] as? [String: Any],
            let sigBase64 = root["signature"] as? String,
            let signature = Data(base64Encoded: sigBase64)
        else {
            throw SmartAccessError.policyDecodeFailed(reason: "envelope_malformed")
        }

        // canonical bytes: re-serialize the policy subtree with sorted keys
        let canonical: Data
        do {
            canonical = try JSONSerialization.data(
                withJSONObject: policyDict,
                options: [.sortedKeys]
            )
        } catch {
            throw SmartAccessError.policyDecodeFailed(reason: "canonicalize_failed: \(error.localizedDescription)")
        }

        let decoder = JSONDecoder()
        let policy: SmartAccessPolicy
        do {
            policy = try decoder.decode(SmartAccessPolicy.self, from: canonical)
        } catch {
            throw SmartAccessError.policyDecodeFailed(reason: "policy_decode_failed: \(error)")
        }

        return PolicyEnvelope(
            policy: policy,
            signature: signature,
            canonicalPolicyBytes: canonical
        )
    }
}
