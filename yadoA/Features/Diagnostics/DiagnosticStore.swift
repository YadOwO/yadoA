import Foundation

/// 本机的诊断存储：每份诊断一个 JSON 文件，最多保留 `maxStoredCount` 份。
nonisolated final class DiagnosticStore: @unchecked Sendable {
    /// 默认存储，目录在 Application Support/MetricKitDiagnostics。
    static let shared = DiagnosticStore(directory: defaultDirectory)

    /// 最多保留的份数。
    static let maxStoredCount = 20

    /// 默认目录。
    private static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MetricKitDiagnostics", isDirectory: true)
    }

    /// 存放诊断文件的目录。
    private let directory: URL

    /// 保护文件读写的锁。
    private let lock = NSLock()

    /// 创建存储。
    ///
    /// - Parameter directory: 存放目录，测试可注入临时目录。
    init(directory: URL) {
        self.directory = directory
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 保存诊断并清理超出上限的旧文件。
    ///
    /// - Parameter reports: 要保存的诊断。
    /// - Throws: 目录创建或文件写入失败。
    func save(_ reports: [DiagnosticReport]) throws {
        guard !reports.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        for report in reports {
            let name = "\(formatter.string(from: report.timestamp))-\(report.kind.rawValue)-\(report.id.uuidString.prefix(8)).json"
            try encoder.encode(report).write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        prune()
    }

    /// 最近的诊断，从新到旧。
    ///
    /// - Parameter limit: 最多取几份。
    /// - Returns: 诊断列表；坏文件跳过。
    func recent(limit: Int) -> [DiagnosticReport] {
        lock.lock()
        defer { lock.unlock() }
        let sorted = entries().compactMap { entry in entry.report.map { ($0, entry.date) } }
            .sorted { $0.1 > $1.1 }
        return Array(sorted.prefix(max(limit, 0)).map(\.0))
    }

    /// 本机是否有诊断。
    func hasReports() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries().contains { $0.report != nil }
    }

    /// 读取目录下全部 JSON 文件；排序时间优先用文件里的 timestamp，读不了的用修改时间。
    private func entries() -> [(url: URL, report: DiagnosticReport?, date: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return urls.filter { $0.pathExtension == "json" }.map { url in
            let report = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(DiagnosticReport.self, from: $0) }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (url, report, report?.timestamp ?? modified ?? .distantPast)
        }
    }

    /// 只留最近 `maxStoredCount` 份，调用方需已持锁。
    private func prune() {
        let sorted = entries().sorted { $0.date > $1.date }
        for entry in sorted.dropFirst(Self.maxStoredCount) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }
}
