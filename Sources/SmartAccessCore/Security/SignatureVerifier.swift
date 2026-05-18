import Foundation
import CryptoKit

/// 仅用 Ed25519 校验 policy / license 签名。
///
/// 不做密钥协商、不做加密、不做 X.509。policy 和 license 都用这一个工具。
enum SignatureVerifier {

    /// Ed25519 公钥可以是 32-byte 原始字节，也可以是 base64 / hex 表达。
    static func parsePublicKey(_ raw: String) throws -> Curve25519.Signing.PublicKey {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. base64
        if let data = Data(base64Encoded: trimmed), data.count == 32 {
            return try Curve25519.Signing.PublicKey(rawRepresentation: data)
        }
        // 2. hex
        if let data = hexToData(trimmed), data.count == 32 {
            return try Curve25519.Signing.PublicKey(rawRepresentation: data)
        }
        throw SmartAccessError.policySignatureInvalid
    }

    /// 校验 Ed25519 签名。
    /// - Parameters:
    ///   - data: 被签名的原始字节（必须是 canonical 形式）。
    ///   - signature: 64-byte 签名。
    ///   - publicKey: Ed25519 公钥。
    /// - Returns: true 表示签名合法。
    static func verifyEd25519(
        data: Data,
        signature: Data,
        publicKey: Curve25519.Signing.PublicKey
    ) -> Bool {
        guard signature.count == 64 else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }

    // MARK: - Helpers

    private static func hexToData(_ hex: String) -> Data? {
        var str = hex
        if str.hasPrefix("0x") || str.hasPrefix("0X") { str.removeFirst(2) }
        guard str.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(str.count / 2)
        var i = str.startIndex
        while i < str.endIndex {
            let j = str.index(i, offsetBy: 2)
            guard let b = UInt8(str[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return Data(bytes)
    }
}
