import Foundation
import os

/// 日志级别。
public enum SALogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info  = 1
    case warn  = 2
    case error = 3

    public static func < (lhs: SALogLevel, rhs: SALogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 日志协议。客户可在 `SmartAccessConfig` 注入自定义 logger。
public protocol SALogger: Sendable {
    func log(level: SALogLevel, message: @autoclosure () -> String, file: StaticString, line: UInt)
}

/// 默认 logger，写到 `os.Logger`。
public struct OSLoggerSink: SALogger {
    private let logger: os.Logger
    private let minLevel: SALogLevel

    public init(subsystem: String = "ai.smartaccess", category: String = "core", minLevel: SALogLevel = .info) {
        self.logger = os.Logger(subsystem: subsystem, category: category)
        self.minLevel = minLevel
    }

    public func log(level: SALogLevel, message: @autoclosure () -> String, file: StaticString, line: UInt) {
        guard level >= minLevel else { return }
        let msg = message()
        switch level {
        case .debug: logger.debug("\(msg, privacy: .public)")
        case .info:  logger.info("\(msg, privacy: .public)")
        case .warn:  logger.warning("\(msg, privacy: .public)")
        case .error: logger.error("\(msg, privacy: .public)")
        }
    }
}

/// 内部短手日志器。
struct SALog {
    private let sink: SALogger
    init(_ sink: SALogger) { self.sink = sink }

    func debug(_ m: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
        sink.log(level: .debug, message: m(), file: file, line: line)
    }
    func info(_ m: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
        sink.log(level: .info, message: m(), file: file, line: line)
    }
    func warn(_ m: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
        sink.log(level: .warn, message: m(), file: file, line: line)
    }
    func error(_ m: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
        sink.log(level: .error, message: m(), file: file, line: line)
    }
}
