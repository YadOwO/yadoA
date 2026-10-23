import Foundation
import Observation
import os

/// 最近若干句语音记账的耗时记录，保存在本机缓存目录，供「我的 → 开发 → 语音耗时」翻看和导出。
///
/// 只保存耗时、数量与标识，不保存用户说的话；缓存被系统清理也不影响任何功能。
@MainActor
@Observable
final class VoiceTimingStore {
    /// App 共用的记录。
    static let shared = VoiceTimingStore(fileURL: defaultFileURL)

    /// 最多保留的句数，超出时丢弃最早的。
    static let maxRecords = 50

    /// 记录，按时间先后排列。
    private(set) var records: [VoiceTurnTiming]

    /// 保存位置；为空时只保存在内存中（测试使用）。
    private let fileURL: URL?

    /// 默认保存位置：缓存目录，不进 iCloud 备份。
    private static var defaultFileURL: URL {
        URL.cachesDirectory.appending(path: "VoiceTiming/records.json")
    }

    /// 创建记录并读取已保存的内容。
    ///
    /// - Parameter fileURL: 保存位置；为空时只保存在内存中。
    init(fileURL: URL?) {
        self.fileURL = fileURL
        records = fileURL.flatMap(Self.load) ?? []
    }

    /// 追加一句的耗时。
    ///
    /// - Parameter record: 一句话的耗时。
    func append(_ record: VoiceTurnTiming) {
        records.append(record)
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }
        save()
    }

    /// 清空全部记录。
    func clear() {
        records = []
        save()
    }

    private static func load(from url: URL) -> [VoiceTurnTiming]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([VoiceTurnTiming].self, from: data)
    }

    /// 写入文件；失败时只记日志，记录仍保留在内存中。
    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
        } catch {
            VoiceTimingLog.logger.error("保存耗时记录失败：\(String(describing: error), privacy: .public)")
        }
    }
}
