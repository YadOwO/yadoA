import Foundation

/// 头像上传的固定配置：存储桶、地域、访问域名与对象路径规则。
///
/// 对象路径固定为 `{应用前缀}/{Logto 用户 ID}/{UUID}.jpg`，例如 `yadoA/abc123/5F0E….jpg`；
/// 用户 ID 取 Logto 的 `sub`，不会随改用户名而变化。每次更换头像都用新文件名，避免 CDN 旧缓存。
enum AvatarUploadConfig {
    /// OSS 存储桶名称。
    static let bucket = "yado-avatars"

    /// 存储桶所在地域，用于 V4 签名的 scope（不带 `oss-` 前缀）。
    static let region = "cn-guangzhou"

    /// 上传使用的虚拟主机风格域名：`{bucket}.oss-{region}.aliyuncs.com`。
    static let uploadHost = "\(bucket).oss-\(region).aliyuncs.com"

    /// 头像公开访问域名；桶本身私有，图片只通过该域名公开读取。
    static let publicBaseURL = URL(string: "https://avatar.yado1225.top")!

    /// 本应用在桶内的目录前缀，与 RAM 权限策略中的 `yado-avatars/yadoA/*` 对应。
    static let appPrefix = "yadoA"

    /// 生成一次上传的对象路径。
    ///
    /// - Parameters:
    ///   - userID: Logto 用户 ID（`sub`）。
    ///   - fileID: 文件随机 ID，默认新生成 UUID；测试时可传入固定值。
    /// - Returns: 不以 `/` 开头的对象路径。
    static func objectKey(userID: String, fileID: UUID = UUID()) -> String {
        "\(appPrefix)/\(userID)/\(fileID.uuidString.lowercased()).jpg"
    }

    /// 对象路径对应的公开访问地址。
    static func publicURL(forObjectKey key: String) -> URL {
        publicBaseURL.appending(path: key)
    }
}
