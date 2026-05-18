import Foundation

/// 只替换 scheme/host/port，保留 path/query/fragment。
public enum SmartAccessURLRewriter {

    public static func rewrite(_ url: URL, withBase newBase: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let baseComps = URLComponents(url: newBase, resolvingAgainstBaseURL: false)
        else {
            return url
        }
        comps.scheme = baseComps.scheme
        comps.host   = baseComps.host
        comps.port   = baseComps.port
        // 不改 user/password/path/query/fragment
        return comps.url ?? url
    }
}
