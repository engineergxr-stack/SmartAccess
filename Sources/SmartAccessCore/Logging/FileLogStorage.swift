import Foundation

/// 基于文件的环形日志存储。
///
/// 文件结构：
///   <directory>/smartaccess.log.current   ← 当前正在写的文件
///   <directory>/smartaccess.log.1
///   <directory>/smartaccess.log.2
///   ...
///   <directory>/smartaccess.log.N         ← N = maxFiles - 1
///
/// 写入策略：
/// - 每条日志一行 JSON（newline-delimited JSON, NDJSON）
/// - 当前文件超过 `rotatingMaxBytes` 后轮转：current → .1，原 .1 → .2，原 .N 删除
/// - 写入失败（盘满 / 权限）静默丢弃，不抛错（日志系统不能让业务崩）
///
/// 并发：actor 隔离，所有 append / readAll / export 串行。
public actor FileLogStorage: SALogStorage {

    public let directory: URL
    public let rotatingMaxBytes: Int
    public let maxFiles: Int

    private let fm = FileManager.default
    private var currentBytes: Int = 0
    private let currentFileName = "smartaccess.log.current"

    public init(directory: URL, rotatingMaxBytes: Int = 5 * 1024 * 1024, maxFiles: Int = 3) {
        self.directory = directory
        self.rotatingMaxBytes = max(64 * 1024, rotatingMaxBytes)
        self.maxFiles = max(1, maxFiles)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        self.currentBytes = (try? fm.attributesOfItem(atPath: currentFile.path)[.size] as? Int) ?? 0
    }

    private var currentFile: URL { directory.appendingPathComponent(currentFileName) }

    private func rotatedFile(index: Int) -> URL {
        directory.appendingPathComponent("smartaccess.log.\(index)")
    }

    public func append(_ log: SADiagnosticLog) async {
        let line = log.toJSONLine()
        do {
            try writeAppend(line)
            currentBytes += line.count
            if currentBytes >= rotatingMaxBytes {
                try rotate()
                currentBytes = 0
            }
        } catch {
            // 静默丢弃
        }
    }

    public func readAll() async -> [SADiagnosticLog] {
        var all: [SADiagnosticLog] = []
        // 从最老到最新：N → 1 → current
        for i in stride(from: maxFiles - 1, through: 1, by: -1) {
            let url = rotatedFile(index: i)
            if let logs = try? readFile(at: url) {
                all.append(contentsOf: logs)
            }
        }
        if let logs = try? readFile(at: currentFile) {
            all.append(contentsOf: logs)
        }
        return all
    }

    public func purge() async {
        for i in 1..<maxFiles {
            try? fm.removeItem(at: rotatedFile(index: i))
        }
        try? fm.removeItem(at: currentFile)
        currentBytes = 0
    }

    public func export(to directory: URL) async throws -> [URL] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var exported: [URL] = []
        // 拷贝顺序：先老后新
        for i in stride(from: maxFiles - 1, through: 1, by: -1) {
            let src = rotatedFile(index: i)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = directory.appendingPathComponent("logs.\(i).ndjson")
            try fm.copyItem(at: src, to: dst)
            exported.append(dst)
        }
        if fm.fileExists(atPath: currentFile.path) {
            let dst = directory.appendingPathComponent("logs.current.ndjson")
            try fm.copyItem(at: currentFile, to: dst)
            exported.append(dst)
        }
        return exported
    }

    // MARK: - Private

    private func writeAppend(_ data: Data) throws {
        if !fm.fileExists(atPath: currentFile.path) {
            fm.createFile(atPath: currentFile.path, contents: data, attributes: [.posixPermissions: 0o600])
            return
        }
        let handle = try FileHandle(forWritingTo: currentFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func rotate() throws {
        // 删除最老的
        try? fm.removeItem(at: rotatedFile(index: maxFiles - 1))
        // i ← i-1 倒序移动
        for i in stride(from: maxFiles - 2, through: 1, by: -1) {
            let src = rotatedFile(index: i)
            let dst = rotatedFile(index: i + 1)
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
        // current → .1
        if fm.fileExists(atPath: currentFile.path) {
            let dst = rotatedFile(index: 1)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: currentFile, to: dst)
        }
    }

    private func readFile(at url: URL) throws -> [SADiagnosticLog] {
        let data = try Data(contentsOf: url)
        var out: [SADiagnosticLog] = []
        var start = data.startIndex
        for i in data.indices {
            if data[i] == 0x0A {
                let line = data.subdata(in: start..<i)
                if !line.isEmpty, let log = SADiagnosticLog.parse(line) {
                    out.append(log)
                }
                start = data.index(after: i)
            }
        }
        if start < data.endIndex {
            let line = data.subdata(in: start..<data.endIndex)
            if let log = SADiagnosticLog.parse(line) {
                out.append(log)
            }
        }
        return out
    }
}
