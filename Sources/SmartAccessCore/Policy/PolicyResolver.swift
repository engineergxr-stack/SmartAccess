import Foundation
import CryptoKit

/// 编排 seed / cached / remote 三个 provider，决定当前生效的 policy。
///
/// 规则：
/// - 启动期立即用 `cached ?? seed`（仍需验签）；
/// - 后台从 remote 拉取；新 policy 必须满足：
///     1. envelope 签名合法（Ed25519，公钥来自 SmartAccessConfig）；
///     2. policy.projectId == configured projectId；
///     3. policy.version > current.version（version 不可回退）；
///     4. policy.expiresAt > now（或仍在允许范围，由调用方决定 grace）。
/// - 不满足任何条件 → 直接拒绝，保留当前 policy。
actor PolicyResolver {

    private let seedProvider: SeedPolicyProvider
    private let cachedProvider: CachedPolicyProvider
    private let remoteProvider: RemotePolicyProvider
    private let publicKey: Curve25519.Signing.PublicKey
    private let projectId: String
    private let log: SALog

    private(set) var currentPolicy: SmartAccessPolicy?
    private(set) var currentEnvelope: PolicyEnvelope?

    init(
        seedProvider: SeedPolicyProvider,
        cachedProvider: CachedPolicyProvider,
        remoteProvider: RemotePolicyProvider,
        publicKey: Curve25519.Signing.PublicKey,
        projectId: String,
        log: SALog
    ) {
        self.seedProvider = seedProvider
        self.cachedProvider = cachedProvider
        self.remoteProvider = remoteProvider
        self.publicKey = publicKey
        self.projectId = projectId
        self.log = log
    }

    // MARK: - Bootstrap

    /// 启动期：用 cached > seed 立即给出一个 policy。验签 + project 校验失败一律拒绝。
    func bootstrap() async throws -> SmartAccessPolicy {
        if let env = await cachedProvider.load() {
            if let p = try? acceptIfValid(envelope: env) {
                currentPolicy = p
                currentEnvelope = env
                log.info("policy.bootstrap source=cache version=\(p.version)")
                return p
            } else {
                log.warn("policy.bootstrap cached_invalid")
            }
        }
        if let env = await seedProvider.loadEnvelope() {
            if let p = try? acceptIfValid(envelope: env) {
                currentPolicy = p
                currentEnvelope = env
                log.info("policy.bootstrap source=seed version=\(p.version)")
                return p
            } else {
                log.warn("policy.bootstrap seed_invalid")
            }
        }
        throw SmartAccessError.policyNotAvailable
    }

    // MARK: - Refresh from remote

    /// 后台刷新：拉一份 remote policy，校验通过则替换 current 并写入缓存。
    /// - Returns: 新版本号（若发生更新），nil 表示未更新。
    @discardableResult
    func refreshFromRemote() async -> Int? {
        let sources = currentPolicy?.configSources ?? []
        guard !sources.isEmpty else {
            log.debug("policy.refresh skipped: no config_sources")
            return nil
        }
        do {
            let (envelope, raw) = try await remoteProvider.fetch(from: sources)
            let incoming = try acceptIfValid(envelope: envelope, mustBeNewerThan: currentPolicy?.version)
            try await cachedProvider.save(rawSignedBytes: raw)
            currentPolicy = incoming
            currentEnvelope = envelope
            log.info("policy.refresh updated version=\(incoming.version)")
            return incoming.version
        } catch {
            log.warn("policy.refresh failed: \(error)")
            return nil
        }
    }

    // MARK: - Validation pipeline

    private func acceptIfValid(envelope: PolicyEnvelope, mustBeNewerThan minVersion: Int? = nil) throws -> SmartAccessPolicy {
        // 1. signature
        guard SignatureVerifier.verifyEd25519(
            data: envelope.canonicalPolicyBytes,
            signature: envelope.signature,
            publicKey: publicKey
        ) else {
            throw SmartAccessError.policySignatureInvalid
        }
        // 2. project id
        guard envelope.policy.projectId == projectId else {
            throw SmartAccessError.policyProjectIdMismatch
        }
        // 3. version monotonic
        if let mv = minVersion, envelope.policy.version <= mv {
            throw SmartAccessError.policyVersionRegressed(current: mv, incoming: envelope.policy.version)
        }
        // 4. expiration
        if envelope.policy.expiresAt < Date() {
            // 注意：bootstrap 时即使过期也可能允许使用（让 ConnectivityEngine 决定 grace），
            // 但 refresh 不能接受过期 policy。这里保持严格：过期一律拒绝。
            throw SmartAccessError.policyExpired
        }
        return envelope.policy
    }
}
