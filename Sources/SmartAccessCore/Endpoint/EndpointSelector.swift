import Foundation

/// 在「单一 endpoint 候选集合」上做选择的小工具。
///
/// `PathSelector` 在做整体 path 选择时会调用这个工具来过滤被熔断的 endpoint。
struct EndpointSelector {

    static func availableEndpoints(_ endpoints: [SAEndpoint], states: [String: SAEndpointState]) -> [SAEndpoint] {
        endpoints
            .filter { $0.enabled }
            .filter { !(states[$0.id]?.isBreakerOpen ?? false) }
    }
}
