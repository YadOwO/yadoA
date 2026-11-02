import AppIntents
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import yadoA

@Suite("截图快捷指令交接")
@MainActor
struct ScreenshotBookkeepingTests {
    @Test("无效和过大文件不生成录入请求")
    func invalidInputDoesNotOpenEntry() {
        let router = ScreenshotBookkeepingRouter()
        #expect(throws: ScreenshotBookkeepingError.invalidImage) {
            try router.receive(Data("not an image".utf8))
        }
        #expect(throws: ScreenshotBookkeepingError.invalidImage) {
            try router.receive(Data())
        }
        #expect(throws: ScreenshotBookkeepingError.imageTooLarge) {
            try router.receive(Data(count: 20 * 1_024 * 1_024 + 1))
        }
        #expect(router.request == nil)
    }

    @Test("重复触发不能覆盖未完成录入，关闭后允许下一张截图")
    func repeatedInvocationPreservesCurrentEntry() throws {
        let router = ScreenshotBookkeepingRouter()
        try router.receive(imageData())
        let firstID = try #require(router.request?.id)
        #expect(throws: ScreenshotBookkeepingError.alreadyEditing) {
            try router.receive(imageData())
        }
        #expect(router.request?.id == firstID)

        router.request = nil
        try router.receive(imageData())
        #expect(router.request?.id != firstID)
    }

    @Test("真实 Intent 的图片参数交给根路由，视图挂载前不丢失请求")
    func intentHandsOffImageBeforeViewMounts() async throws {
        let router = ScreenshotBookkeepingRouter.shared
        router.request = nil
        defer { router.request = nil }
        let intent = ScreenshotBookkeepingIntent()
        intent.screenshot = IntentFile(data: imageData(), filename: "screenshot.png", type: .png)

        _ = try await intent.perform()

        let request = try #require(router.request)
        #expect(request.image.size.width == 40)
        #expect(request.image.size.height == 80)
    }

    @Test("大分辨率图片按比例缩小到预览上限")
    func imageIsDownsampled() throws {
        let request = try ScreenshotBookkeepingRequest(data: imageData(size: CGSize(width: 1_500, height: 3_000)))
        #expect(request.image.size.width == 1_024)
        #expect(request.image.size.height == 2_048)
    }

    /// 生成无账单信息的测试图，验证实际解码和参数传递。
    private func imageData(size: CGSize = CGSize(width: 40, height: 80)) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
