import Foundation
import Network
import Security
import CryptoKit

/// Network.framework 的 TLS verify block 实现。
///
/// 目的：客户端连的是 IP（HTTPDNS 给的），但证书必须按原始 hostname 校验，
/// 否则证书 SAN 不会包含 IP，握手会失败。
///
/// 规则：
/// - 用 `SecPolicyCreateSSL(true, hostname)` 重建 policy，让 trust 按 hostname 比对 SAN
/// - 链合法性 / 过期 / OCSP 默认仍由系统 trust evaluation 处理（`SecTrustEvaluateWithError`）
/// - 可选 SPKI pinning：如果客户在 policy 里配了公钥指纹列表，必须命中其中之一
///
/// **严禁**绕过 TLS 校验的写法。任何允许"未校验通过仍然 complete(true)"的分支
/// 都会让本 SDK 立刻变成不合规产品。
enum TLSVerifier {

    /// 构造一个 verify_block，用于 `sec_protocol_options_set_verify_block`。
    /// - Parameters:
    ///   - hostname: 期望的证书 hostname（原始 Relay 域名）
    ///   - pinnedSPKIHashes: 可选。base64-encoded SHA-256(SecKeyCopyExternalRepresentation) 指纹白名单。
    ///     空数组表示不做 pinning。**生产部署前必须用相同算法离线生成 pin 与本算法对账**。
    static func makeVerifyBlock(
        hostname: String,
        pinnedSPKIHashes: [String]
    ) -> sec_protocol_verify_t {
        let pinned = pinnedSPKIHashes // 闭包捕获副本
        let host = hostname
        let block: sec_protocol_verify_t = { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()

            // 1. 强制按 hostname 重新校验
            let policy = SecPolicyCreateSSL(true, host as CFString)
            SecTrustSetPolicies(trust, policy)

            var cfError: CFError?
            let trusted = SecTrustEvaluateWithError(trust, &cfError)
            guard trusted else {
                complete(false)
                return
            }

            // 2. 可选 SPKI pinning
            if !pinned.isEmpty {
                guard let leaf = leafKeyFingerprint(trust: trust),
                      pinned.contains(leaf) else {
                    complete(false)
                    return
                }
            }

            complete(true)
        }
        return block
    }

    /// 提取证书链中 leaf 证书公钥的 SHA-256，base64 编码。
    static func leafKeyFingerprint(trust: SecTrust) -> String? {
        guard SecTrustGetCertificateCount(trust) > 0,
              let leaf = SecTrustGetCertificateAtIndex(trust, 0) else { return nil }
        guard let pubkey = SecCertificateCopyKey(leaf) else { return nil }
        var error: Unmanaged<CFError>?
        guard let extData = SecKeyCopyExternalRepresentation(pubkey, &error) as Data? else { return nil }
        let digest = SHA256.hash(data: extData)
        return Data(digest).base64EncodedString()
    }
}
