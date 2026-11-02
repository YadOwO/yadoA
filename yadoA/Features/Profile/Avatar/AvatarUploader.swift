import Foundation
import UIKit

/// 头像上传失败的原因，界面按类型展示本地化文案。
enum AvatarUploadError: Error, Equatable {
    /// 本地未配置上传凭证（Release 构建或缺少 Secrets.xcconfig）。
    case notConfigured
    /// 选中的文件无法解析为图片。
    case invalidImage
    /// 拿不到当前登录用户的 ID，通常是登录已失效。
    case notSignedIn
    /// 网络不可用或请求超时。
    case network
    /// OSS 拒绝了上传，附带 HTTP 状态码与 OSS 错误码便于排查。
    case rejected(status: Int, code: String?)

    /// 对应的 `Localizable.xcstrings` 键。
    var localizationKey: String {
        switch self {
        case .notConfigured: "profile.avatar.error.not_configured"
        case .invalidImage: "profile.avatar.error.invalid_image"
        case .notSignedIn: "profile.avatar.error.not_signed_in"
        case .network: "profile.edit.error.network"
        case .rejected: "profile.avatar.error.upload_failed"
        }
    }
}

/// 把头像图片直传到 OSS，返回公开访问地址。
struct AvatarUploader {
    /// 凭证来源。
    let credentialProvider: OSSCredentialProviding

    /// 发送请求的会话，测试时可替换。
    var session: URLSession = .shared

    /// 上传一张已处理好的头像。
    ///
    /// - Parameters:
    ///   - jpegData: 已裁剪压缩的 JPEG 数据，见 `AvatarImageProcessor`。
    ///   - userID: Logto 用户 ID，决定对象所在目录。
    /// - Returns: 头像的公开访问地址，可直接写入 Logto 资料。
    /// - Throws: `AvatarUploadError`。
    func upload(jpegData: Data, userID: String) async throws -> URL {
        let credentials = try await credentialProvider.credentials()
        let key = AvatarUploadConfig.objectKey(userID: userID)
        let signer = OSSRequestSigner(credentials: credentials, region: AvatarUploadConfig.region)
        let request = signer.signedPutRequest(
            host: AvatarUploadConfig.uploadHost,
            bucket: AvatarUploadConfig.bucket,
            objectKey: key,
            contentType: "image/jpeg",
            body: jpegData
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AvatarUploadError.network
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AvatarUploadError.rejected(status: status, code: Self.ossErrorCode(in: data))
        }
        return AvatarUploadConfig.publicURL(forObjectKey: key)
    }

    /// 从 OSS 的 XML 错误响应中取出 `<Code>` 的值，如 `AccessDenied`、`SignatureDoesNotMatch`。
    static func ossErrorCode(in data: Data) -> String? {
        guard
            let xml = String(data: data, encoding: .utf8),
            let start = xml.range(of: "<Code>"),
            let end = xml.range(of: "</Code>", range: start.upperBound..<xml.endIndex)
        else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}

/// 把用户选中的图片处理成适合做头像的 JPEG：居中裁成正方形、缩到固定边长、压缩。
enum AvatarImageProcessor {
    /// 输出头像的边长（像素），满足 3x 屏上 112pt 头像的清晰度。
    static let outputSide: CGFloat = 512

    /// JPEG 压缩质量。
    static let compressionQuality: CGFloat = 0.82

    /// 处理原始图片数据。
    ///
    /// - Parameter data: 相册导出的原始数据（HEIC、JPEG、PNG 等）。
    /// - Returns: 正方形 JPEG 数据。
    /// - Throws: 无法解析为图片时抛出 `AvatarUploadError.invalidImage`。
    static func process(_ data: Data) throws -> Data {
        guard let image = UIImage(data: data) else {
            throw AvatarUploadError.invalidImage
        }
        return try process(image)
    }

    /// 处理已解码的图片，会按 `imageOrientation` 摆正方向。
    static func process(_ image: UIImage) throws -> Data {
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            throw AvatarUploadError.invalidImage
        }

        let side = min(outputSide, min(size.width, size.height) * image.scale)
        // 按短边缩放铺满正方形画布，超出部分居中裁掉
        let scale = side / min(size.width, size.height)
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let jpeg = renderer.jpegData(withCompressionQuality: compressionQuality) { context in
            // 透明 PNG 转 JPEG 时用白底，避免透明区域变黑
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        guard !jpeg.isEmpty else {
            throw AvatarUploadError.invalidImage
        }
        return jpeg
    }
}
