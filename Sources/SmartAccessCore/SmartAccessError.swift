import Foundation

/// SmartAccess SDK 公共错误模型。
///
/// 设计原则：
/// - 任何对外抛出的错误，必须落到 `SmartAccessError` 的某个 case，禁止裸 `NSError` 透出。
/// - `noReachablePath` 必须携带 `ReachabilityReport`，让客户日志/运维能定位每条路径死在哪一阶段。
/// - License / Policy 失败必须区分原因（签名、过期、版本回退、bundleId 不匹配），便于客户定位运维问题。
public enum SmartAccessError: Error, Equatable {

    // MARK: - License
    case licenseFileMissing
    case licenseDecodeFailed(reason: String)
    case licenseSignatureInvalid
    case licenseBundleMismatch(expected: String, actual: String)
    case licensePlatformMismatch
    case licenseExpired
    case licenseGracePeriodExceeded
    case licenseSDKVersionUnsupported
    case featureNotLicensed(feature: String)

    // MARK: - Policy
    case policyNotAvailable
    case policyDecodeFailed(reason: String)
    case policySignatureInvalid
    case policyProjectIdMismatch
    case policyExpired
    case policyVersionRegressed(current: Int, incoming: Int)
    case policyAllSourcesUnreachable

    // MARK: - Engine / Lifecycle
    case notStarted
    case alreadyStarted
    case startupTimeout

    // MARK: - Connectivity
    case noReachablePath(report: ReachabilityReport)
    case probeCancelled
    case invalidEndpoint(reason: String)
}

extension SmartAccessError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .licenseFileMissing:                  return "license.file_missing"
        case .licenseDecodeFailed(let r):          return "license.decode_failed: \(r)"
        case .licenseSignatureInvalid:             return "license.signature_invalid"
        case .licenseBundleMismatch(let e, let a): return "license.bundle_mismatch expected=\(e) actual=\(a)"
        case .licensePlatformMismatch:             return "license.platform_mismatch"
        case .licenseExpired:                      return "license.expired"
        case .licenseGracePeriodExceeded:          return "license.grace_exceeded"
        case .licenseSDKVersionUnsupported:        return "license.sdk_version_unsupported"
        case .featureNotLicensed(let f):           return "license.feature_not_licensed: \(f)"
        case .policyNotAvailable:                  return "policy.not_available"
        case .policyDecodeFailed(let r):           return "policy.decode_failed: \(r)"
        case .policySignatureInvalid:              return "policy.signature_invalid"
        case .policyProjectIdMismatch:             return "policy.project_id_mismatch"
        case .policyExpired:                       return "policy.expired"
        case .policyVersionRegressed(let c, let i): return "policy.version_regressed current=\(c) incoming=\(i)"
        case .policyAllSourcesUnreachable:         return "policy.all_sources_unreachable"
        case .notStarted:                          return "engine.not_started"
        case .alreadyStarted:                      return "engine.already_started"
        case .startupTimeout:                      return "engine.startup_timeout"
        case .noReachablePath:                     return "connectivity.no_reachable_path"
        case .probeCancelled:                      return "connectivity.probe_cancelled"
        case .invalidEndpoint(let r):              return "connectivity.invalid_endpoint: \(r)"
        }
    }
}
