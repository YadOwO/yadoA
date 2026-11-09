import Foundation
import Testing
@testable import yadoA

/// 验证本机诊断存储：数量上限、排序与坏文件。
@Suite("诊断存储")
struct DiagnosticStoreTests {
    /// 创建临时目录里的存储。
    private static func makeStore() -> (DiagnosticStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (DiagnosticStore(directory: directory), directory)
    }

    private static func report(second: Int) -> DiagnosticReport {
        DiagnosticReport(
            id: UUID(),
            kind: .hang,
            timestamp: Date(timeIntervalSince1970: 1_793_000_000 + Double(second)),
            osVersion: "iOS 27.1",
            appVersion: "1.0",
            buildVersion: "1",
            callStackTree: "{}"
        )
    }

    @Test("存 25 份后只剩最近 20 份")
    func keepsLatestTwenty() throws {
        let (store, directory) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save((0..<25).map { Self.report(second: $0) })
        let all = store.recent(limit: 100)
        #expect(all.count == DiagnosticStore.maxStoredCount)
        #expect(all.last?.timestamp == Date(timeIntervalSince1970: 1_793_000_005))
    }

    @Test("recent 从新到旧")
    func recentIsNewestFirst() throws {
        let (store, directory) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save((0..<8).map { Self.report(second: $0) })
        let recent = store.recent(limit: 5)
        #expect(recent.count == 5)
        #expect(recent.map(\.timestamp) == recent.map(\.timestamp).sorted(by: >))
        #expect(recent.first?.timestamp == Date(timeIntervalSince1970: 1_793_000_007))
    }

    @Test("坏文件跳过")
    func skipsCorruptFiles() throws {
        let (store, directory) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!store.hasReports())
        try store.save([Self.report(second: 1)])
        try Data("not json".utf8).write(to: directory.appendingPathComponent("bad.json"))
        #expect(store.recent(limit: 5).count == 1)
        #expect(store.hasReports())
    }
}
