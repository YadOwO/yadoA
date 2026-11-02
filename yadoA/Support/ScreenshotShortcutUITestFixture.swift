#if DEBUG
import AppIntents
import UIKit
import UniformTypeIdentifiers

/// 仅在隔离 UI 测试参数下使用的图片夹具，不访问相册或真实账单。
enum ScreenshotShortcutUITestFixture {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing-in-memory")
            && arguments.contains("--ui-testing-screenshot-shortcut")
    }

    /// 生成可辨识的本地图片，用来验证输入、预览和取消生命周期。
    static func imageData() -> Data {
        let size = CGSize(width: 240, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemGroupedBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            NSString(string: "yadoA\nScreenshot preview\n12.50").draw(
                in: CGRect(x: 24, y: 60, width: 192, height: 220),
                withAttributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.label]
            )
        }
    }

    /// 热启动测试直接调用生产 Intent，测试错误必须显式失败。
    static func invoke() async {
        do {
            let intent = ScreenshotBookkeepingIntent()
            intent.screenshot = IntentFile(data: imageData(), filename: "fixture.png", type: .png)
            _ = try await intent.perform()
        } catch {
            fatalError("Unable to invoke screenshot test intent: \(error)")
        }
    }
}
#endif
