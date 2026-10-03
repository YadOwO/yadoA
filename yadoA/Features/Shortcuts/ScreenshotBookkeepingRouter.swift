import ImageIO
import Observation
import UIKit

/// 一次截图录入会话；图片仅保留在内存中，不写入账本或照片库。
struct ScreenshotBookkeepingRequest: Identifiable {
    let id = UUID()
    let image: UIImage

    /// 对输入限制大小并按方向解码，避免超大图片造成全尺寸解码开销。
    init(data: Data) throws {
        guard !data.isEmpty else { throw ScreenshotBookkeepingError.invalidImage }
        guard data.count <= 20 * 1_024 * 1_024 else {
            throw ScreenshotBookkeepingError.imageTooLarge
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary)
        else { throw ScreenshotBookkeepingError.invalidImage }
        image = UIImage(cgImage: thumbnail)
    }
}

/// 快捷指令与应用界面共用的单一交接入口，避免重复触发覆盖正在填写的内容。
@MainActor
@Observable
final class ScreenshotBookkeepingRouter {
    static let shared = ScreenshotBookkeepingRouter()

    /// 保留请求直到录入页面完成关闭，再由展示容器释放图片。
    var request: ScreenshotBookkeepingRequest?

    /// 接收失败不改变已有会话，也不会写入任何流水。
    func receive(_ data: Data) throws {
        guard request == nil else { throw ScreenshotBookkeepingError.alreadyEditing }
        request = try ScreenshotBookkeepingRequest(data: data)
    }
}

/// 直接交由快捷指令显示的可恢复输入错误。
enum ScreenshotBookkeepingError: Error, LocalizedError {
    case invalidImage
    case imageTooLarge
    case alreadyEditing

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            String(localized: "shortcut.screenshot.error.invalid")
        case .imageTooLarge:
            String(localized: "shortcut.screenshot.error.large")
        case .alreadyEditing:
            String(localized: "shortcut.screenshot.error.busy")
        }
    }
}
