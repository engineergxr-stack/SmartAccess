import Foundation

/// 把 NSError / URLError / POSIXError / TLS error 映射到 `ConnectivityStage` + 稳定 errorCode。
///
/// 这是 SDK 的核心 IP 之一：客户日志聚合时，看到的是稳定字符串，而不是 NSError 描述。
enum ErrorClassifier {

    static func classify(_ error: Error) -> (stage: ConnectivityStage, code: String) {

        if let urlError = error as? URLError {
            return classify(urlError: urlError)
        }
        if let posix = error as? POSIXError {
            return classify(posix: posix.code)
        }

        let nsError = error as NSError

        // URLError domain
        if nsError.domain == NSURLErrorDomain,
           let code = URLError.Code(rawValue: nsError.code).map(URLError.init) {
            return classify(urlError: code)
        }

        // POSIX domain
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return classify(posix: code)
        }

        // OSStatus TLS errors（kCFStreamErrorDomainSSL）
        if nsError.domain == "kCFStreamErrorDomainSSL" {
            return (.tls, "tls.osstatus_\(nsError.code)")
        }

        return (.unknown, "unknown.\(nsError.domain).\(nsError.code)")
    }

    private static func classify(urlError: URLError) -> (ConnectivityStage, String) {
        switch urlError.code {
        case .cannotFindHost,
             .dnsLookupFailed:
            return (.dns, "dns.lookup_failed")

        case .timedOut:
            return (.http, "http.timeout")

        case .cannotConnectToHost,
             .networkConnectionLost,
             .notConnectedToInternet:
            return (.tcp, "tcp.connect_failed")

        case .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return (.tls, "tls.handshake_failed")

        case .badServerResponse,
             .cannotParseResponse,
             .zeroByteResource:
            return (.http, "http.bad_response")

        case .cancelled:
            return (.unknown, "cancelled")

        default:
            return (.http, "http.urlerror_\(urlError.code.rawValue)")
        }
    }

    private static func classify(posix code: POSIXErrorCode) -> (ConnectivityStage, String) {
        switch code {
        case .ECONNREFUSED: return (.tcp, "tcp.connection_refused")
        case .ECONNRESET:   return (.tcp, "tcp.connection_reset")
        case .EHOSTUNREACH: return (.tcp, "tcp.host_unreachable")
        case .ENETUNREACH:  return (.tcp, "tcp.net_unreachable")
        case .ETIMEDOUT:    return (.tcp, "tcp.timeout")
        case .ENOTCONN:     return (.tcp, "tcp.not_connected")
        default:            return (.unknown, "posix.\(code.rawValue)")
        }
    }
}
