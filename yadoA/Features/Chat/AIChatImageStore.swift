import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 对话图片的本机文件：发送时压缩好的 JPEG，只存在这台设备上，不进云同步、备份和系统 iCloud 备份。
nonisolated struct AIChatImageStore: Sendable {
    /// 图片文件所在目录。
    let directory: URL

    /// 生产环境使用的目录，放在 Application Support 下账本文件的旁边。
    static let production = AIChatImageStore(
        directory: URL.applicationSupportDirectory
            .appending(path: "yadoA", directoryHint: .isDirectory)
            .appending(path: "ChatImages", directoryHint: .isDirectory)
    )

    /// 图片文件的地址。
    ///
    /// - Parameter fileName: 记录里保存的文件名。
    /// - Returns: 文件地址。
    func url(for fileName: String) -> URL {
        directory.appending(path: fileName)
    }

    /// 保存一张压缩好的图片。
    ///
    /// - Parameter data: JPEG 数据。
    /// - Returns: 生成的文件名。
    /// - Throws: 目录或文件写入失败时抛出。
    func save(_ data: Data) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(values)
        let fileName = "\(UUID().uuidString).jpg"
        try data.write(to: url(for: fileName), options: .atomic)
        return fileName
    }

    /// 读取图片内容。
    ///
    /// - Parameter fileName: 记录里保存的文件名。
    /// - Returns: 图片内容；文件不存在时为 `nil`。
    func data(for fileName: String) -> Data? {
        try? Data(contentsOf: url(for: fileName))
    }

    /// 删除全部图片。
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 删除没有被引用的图片。
    ///
    /// - Parameter kept: 仍被记录引用的文件名。
    func removeFiles(notIn kept: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for file in files where !kept.contains(file) {
            try? FileManager.default.removeItem(at: url(for: file))
        }
    }
}

/// 把用户选的图片压缩成可以发给 AI 服务的 JPEG。
nonisolated enum AIChatImageProcessor {
    /// 压缩后的最长边（pt 按像素计）；账单截图和小票在这个尺寸下足够清晰。
    static let maxPixelSize = 1600

    /// 依次尝试的 JPEG 质量。
    private static let qualities: [CGFloat] = [0.75, 0.6, 0.45, 0.3]

    /// 压缩图片；HEIC、PNG 等都转成 JPEG，并按方向信息转正。
    ///
    /// - Parameter data: 原始图片数据。
    /// - Returns: 不超过 `VoiceSessionLimits.maxImageBytes` 的 JPEG；图片无法解码或压不到上限内时为 `nil`。
    static func compressedJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        for quality in qualities {
            if let jpeg = encodeJPEG(image, quality: quality), jpeg.count <= VoiceSessionLimits.maxImageBytes {
                return jpeg
            }
        }
        return nil
    }

    /// 把解码后的图片编码成 JPEG。
    private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
