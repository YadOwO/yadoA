import Foundation

/// 上传 OSS 使用的访问凭证。
///
/// 当前由本地配置提供长期 AccessKey；以后改为服务端签发 STS 时，`securityToken` 不为空，
/// 签名时会自动带上 `x-oss-security-token` 请求头。
struct OSSCredentials: Equatable {
    /// AccessKey ID。
    let accessKeyID: String
    /// AccessKey Secret，只用于本地签名，不随请求发送。
    let accessKeySecret: String
    /// STS 临时凭证的安全令牌；长期 AccessKey 时为 nil。
    var securityToken: String?
}

/// 头像上传凭证来源。
///
/// 页面与上传逻辑只依赖这个协议：现在用 `BundledOSSCredentialProvider` 读取本地密钥，
/// 以后接入服务端 STS 时新增一个实现替换即可，调用方不需要改动。
protocol OSSCredentialProviding {
    /// 返回一组可用于签名的凭证。
    ///
    /// - Throws: 凭证不可用时抛出 `AvatarUploadError.notConfigured`。
    func credentials() async throws -> OSSCredentials
}

/// 从 Info.plist 读取 Debug 构建注入的长期 AccessKey。
///
/// 密钥来自未入库的 `Config/Secrets.xcconfig`，仅 Debug 构建会引用；
/// Release 构建以及未配置密钥时视为不可用，头像更换入口会隐藏。
/// 该 AccessKey 对应的 RAM 用户只授予 `yado-avatars/yadoA/*` 的 `oss:PutObject` 权限。
struct BundledOSSCredentialProvider: OSSCredentialProviding {
    /// Info.plist 中保存 AccessKey ID 的键。
    static let accessKeyIDInfoKey = "OSSAvatarAccessKeyID"
    /// Info.plist 中保存 AccessKey Secret 的键。
    static let accessKeySecretInfoKey = "OSSAvatarAccessKeySecret"

    /// 读取配置的资源包，测试时可替换。
    var bundle: Bundle = .main

    /// 本地是否配置了完整的凭证；用于决定是否展示头像更换入口。
    var isAvailable: Bool {
        storedCredentials != nil
    }

    func credentials() async throws -> OSSCredentials {
        guard let storedCredentials else {
            throw AvatarUploadError.notConfigured
        }
        return storedCredentials
    }

    /// Info.plist 中的凭证；Release 构建、未配置或值为空时为 nil。
    private var storedCredentials: OSSCredentials? {
        #if DEBUG
        guard
            let id = Self.value(for: Self.accessKeyIDInfoKey, in: bundle),
            let secret = Self.value(for: Self.accessKeySecretInfoKey, in: bundle)
        else {
            return nil
        }
        return OSSCredentials(accessKeyID: id, accessKeySecret: secret)
        #else
        return nil
        #endif
    }

    /// 读取并清理 Info.plist 中的字符串；未替换的 `$(…)` 占位或空白值视为未配置。
    private static func value(for key: String, in bundle: Bundle) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else {
            return nil
        }
        return value
    }
}
