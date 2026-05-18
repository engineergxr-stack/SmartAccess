import Foundation

/// 一次性 adapt：把 URLRequest 的 URL 改写成当前 path 的 baseURL。
///
/// 客户也可以直接在自己的网络层取 `SmartAccess.shared.currentBaseURL()`，
/// 不一定要用这个 adapter。两者等价，看团队偏好。
public struct SmartAccessURLRequestAdapter: Sendable {

    private let baseURLProvider: @Sendable () -> URL?

    public init(baseURLProvider: @Sendable @escaping () -> URL?) {
        self.baseURLProvider = baseURLProvider
    }

    public func adapt(_ request: URLRequest) -> URLRequest {
        guard let original = request.url,
              let newBase = baseURLProvider()
        else { return request }
        var newRequest = request
        newRequest.url = SmartAccessURLRewriter.rewrite(original, withBase: newBase)
        return newRequest
    }
}
