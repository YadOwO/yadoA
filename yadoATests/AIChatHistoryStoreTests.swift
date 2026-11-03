import Foundation
import SwiftData
import Testing
import UIKit
@testable import yadoA

/// 对话记录的本机存储：分页读取、更新同一轮、保留期清理与清空。
@MainActor
struct AIChatHistoryStoreTests {
    /// 测试用的存储，图片放在独立的临时目录。
    private struct Fixture {
        let container: ModelContainer
        let images: AIChatImageStore
        let store: AIChatHistoryStore

        init() throws {
            container = try AccountDataContainer.inMemory().modelContainer
            images = AIChatImageStore(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
            store = AIChatHistoryStore(container: container, images: images)
        }

        /// 写入一轮已结束的对话。
        func save(_ text: String, at date: Date, imageFileNames: [String] = []) {
            var turn = VoiceSession.Turn(userText: text, imageFileNames: imageFileNames, createdAt: date, eventStartIndex: 0)
            turn.outcome = .reply("好")
            store.save(turn, locale: Locale(identifier: "zh-Hans"))
        }
    }

    @Test("处理中的一轮不写入")
    func skipsProcessingTurn() throws {
        let fixture = try Fixture()
        let turn = VoiceSession.Turn(userText: "午饭", eventStartIndex: 0)

        fixture.store.save(turn, locale: Locale(identifier: "zh-Hans"))
        fixture.store.loadLatest()

        #expect(fixture.store.turns.isEmpty)
    }

    @Test("同一轮再次写入时更新原记录，不新增")
    func updatesExistingTurn() throws {
        let fixture = try Fixture()
        var turn = VoiceSession.Turn(userText: "午饭", eventStartIndex: 0)
        turn.outcome = .reply("已记 1 笔")
        fixture.store.save(turn, locale: Locale(identifier: "zh-Hans"))

        turn.isUndone = true
        fixture.store.save(turn, locale: Locale(identifier: "zh-Hans"))
        fixture.store.loadLatest()

        #expect(fixture.store.turns.count == 1)
        #expect(fixture.store.turns.first?.isUndone == true)
    }

    @Test("查账结果随记录保存，重新读取后还在；再次写入同一轮时跟着更新")
    func persistsInsight() throws {
        let fixture = try Fixture()
        let insight = AIChatInsight(
            title: "10月 · 2 笔",
            formattedTotal: "¥63.00",
            formattedIncome: nil,
            comparison: .init(isLess: true, formattedDelta: "¥10.00"),
            buckets: [.init(id: 20261001, label: "10/1", value: 28, formattedValue: "¥28.00")]
        )
        var turn = VoiceSession.Turn(userText: "这个月花了多少", eventStartIndex: 0)
        turn.outcome = .reply("花了 ¥63")
        fixture.store.save(turn, locale: Locale(identifier: "zh-Hans"))

        turn.insights = [insight]
        fixture.store.save(turn, locale: Locale(identifier: "zh-Hans"))
        fixture.store.loadLatest()

        #expect(fixture.store.turns.first?.insight == insight)
    }

    @Test("分页读取：先读最近一页，再往前读，始终按时间正序")
    func loadsPages() throws {
        let fixture = try Fixture()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let total = AIChatHistoryStore.pageSize + 2
        for index in 0..<total {
            fixture.save("第 \(index) 句", at: start.addingTimeInterval(Double(index)))
        }

        fixture.store.loadLatest()
        #expect(fixture.store.turns.count == AIChatHistoryStore.pageSize)
        #expect(fixture.store.turns.first?.userText == "第 2 句")
        #expect(fixture.store.turns.last?.userText == "第 \(total - 1) 句")
        #expect(fixture.store.hasEarlier)

        fixture.store.loadEarlier()
        #expect(fixture.store.turns.count == total)
        #expect(fixture.store.turns.first?.userText == "第 0 句")
        #expect(!fixture.store.hasEarlier)
    }

    @Test("清理超过保留期的记录和没有记录引用的图片")
    func prunesExpiredTurnsAndOrphanImages() throws {
        let fixture = try Fixture()
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let expiredFile = try fixture.images.save(Data([1]))
        let keptFile = try fixture.images.save(Data([2]))
        let orphanFile = try fixture.images.save(Data([3]))
        fixture.save(
            "旧的",
            at: now.addingTimeInterval(-Double(AIChatHistoryStore.retentionDays + 1) * 86_400),
            imageFileNames: [expiredFile]
        )
        fixture.save("新的", at: now.addingTimeInterval(-60), imageFileNames: [keptFile])

        fixture.store.prune(now: now)
        fixture.store.loadLatest()

        #expect(fixture.store.turns.map(\.userText) == ["新的"])
        #expect(fixture.images.data(for: keptFile) != nil)
        #expect(fixture.images.data(for: expiredFile) == nil)
        #expect(fixture.images.data(for: orphanFile) == nil)
    }

    @Test("一次保存多张图片，文件名与输入顺序一致；按名删除只删指定的文件")
    func savesAllAndRemovesNamedFiles() throws {
        let fixture = try Fixture()
        let fileNames = try fixture.images.saveAll([Data([1]), Data([2])])

        #expect(fileNames.count == 2)
        #expect(fixture.images.data(for: fileNames[0]) == Data([1]))
        #expect(fixture.images.data(for: fileNames[1]) == Data([2]))

        fixture.images.removeFiles(named: [fileNames[0], "missing.jpg"])

        #expect(fixture.images.data(for: fileNames[0]) == nil)
        #expect(fixture.images.data(for: fileNames[1]) == Data([2]))
    }

    @Test("清空后记录和图片都没有了")
    func clearsEverything() throws {
        let fixture = try Fixture()
        #expect(!fixture.store.hasRecords())
        let file = try fixture.images.save(Data([1]))
        fixture.save("午饭", at: .now, imageFileNames: [file])
        #expect(fixture.store.hasRecords())

        try fixture.store.clearAll()
        fixture.store.loadLatest()

        #expect(fixture.store.turns.isEmpty)
        #expect(!fixture.store.hasRecords())
        #expect(fixture.images.data(for: file) == nil)
    }

    @Test("清空本机数据时对话记录一起清空")
    func erasedWithLocalData() throws {
        let fixture = try Fixture()
        fixture.save("午饭", at: .now)

        try LocalDataResetService(container: fixture.container).eraseAll()
        fixture.store.loadLatest()

        #expect(fixture.store.turns.isEmpty)
    }

    @Test("压缩后的图片不超过上传上限，且长边不超过上限")
    func compressesImages() throws {
        let source = try #require(UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }.pngData())

        let jpeg = try #require(AIChatImageProcessor.compressedJPEG(from: source))
        let image = try #require(UIImage(data: jpeg))

        #expect(jpeg.count <= VoiceSessionLimits.maxImageBytes)
        #expect(max(image.size.width * image.scale, image.size.height * image.scale) <= CGFloat(AIChatImageProcessor.maxPixelSize))
    }

    @Test("不是图片的数据压缩失败")
    func rejectsNonImageData() {
        #expect(AIChatImageProcessor.compressedJPEG(from: Data([1, 2, 3])) == nil)
    }
}
