import Foundation

/// 本地日志存储接口。客户可注入自己的实现（写到 Sentry breadcrumb / Datadog session 等）。
public protocol SALogStorage: Sendable {
    func append(_ log: SADiagnosticLog) async
    func readAll() async -> [SADiagnosticLog]
    func purge() async
    /// 导出日志到指定目录（用于 DiagnosticBundle）。返回写入的文件列表。
    func export(to directory: URL) async throws -> [URL]
}

/// 永远丢弃的实现（不开启本地日志时使用）。
public struct NullLogStorage: SALogStorage {
    public init() {}
    public func append(_ log: SADiagnosticLog) async {}
    public func readAll() async -> [SADiagnosticLog] { [] }
    public func purge() async {}
    public func export(to directory: URL) async throws -> [URL] { [] }
}
