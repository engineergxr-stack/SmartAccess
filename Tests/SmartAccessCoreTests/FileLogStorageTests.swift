import XCTest
@testable import SmartAccessCore

final class FileLogStorageTests: XCTestCase {

    func testAppendAndReadRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sa-test-\(UUID().uuidString)", isDirectory: true)
        let storage = FileLogStorage(directory: dir, rotatingMaxBytes: 1_000_000, maxFiles: 3)

        for i in 0..<5 {
            await storage.append(SADiagnosticLog(
                severity: .info,
                event: "test.event",
                fields: ["seq": String(i)]
            ))
        }
        let all = await storage.readAll()
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all.map { $0.fields["seq"] }, ["0", "1", "2", "3", "4"])
    }

    func testRotation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sa-test-\(UUID().uuidString)", isDirectory: true)
        let storage = FileLogStorage(directory: dir, rotatingMaxBytes: 512, maxFiles: 3)

        // 写够触发轮转
        for i in 0..<200 {
            await storage.append(SADiagnosticLog(
                severity: .info,
                event: "test.event",
                fields: ["seq": String(i), "padding": String(repeating: "x", count: 30)]
            ))
        }
        let all = await storage.readAll()
        // 我们不保证 readAll 拿到全部 200 条（最老的被轮转删了），但顺序必须从老到新
        let seqs = all.compactMap { $0.fields["seq"].flatMap(Int.init) }
        XCTAssertFalse(seqs.isEmpty)
        XCTAssertTrue(seqs == seqs.sorted(), "log order broken after rotation")
    }
}
