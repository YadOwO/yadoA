import Foundation

/// 登录页上的第三方登录方式，每一种对应 Logto 里的一个社交连接器。
///
/// 点击后通过 Logto 的 direct sign-in 跳过方式选择页，直接进入该连接器的授权流程；
/// 账号密码登录不在此列，它始终显示在登录页按钮区的最后一个。
enum AuthSocialProvider: String, CaseIterable, Identifiable {
    /// 通过 Apple 登录。
    ///
    /// 走 Logto 的 Apple 网页连接器（Services ID + 密钥），授权页由 SDK 用 `ASWebAuthenticationSession` 打开，
    /// 因此 App 本身无需开启 Sign in with Apple capability。Apple 账号整个 Logto 租户共用，
    /// 同一 Apple ID 在 yado 各产品里登录得到的是同一个 Logto 用户（同一个 `sub`）。
    /// 注意：Apple 只在首次授权时返回邮箱和姓名，用户可能选择隐藏邮箱，也可能没有昵称，界面需容忍资料为空。
    case apple

    var id: String { rawValue }

    /// 登录页上显示的第三方登录方式，按显示顺序排列。
    static let displayed: [AuthSocialProvider] = [.apple]

    /// 是否已在 Logto 接通。
    ///
    /// 未接通时按钮只作占位，点击提示“即将上线”；在 Logto Console 配置好对应连接器、
    /// 并在“登录体验”中启用后，再把这里改为 `true`。
    var isConnected: Bool {
        switch self {
        case .apple: true
        }
    }

    /// Logto 社交连接器的 target，须与 Console 中该连接器的 target 字段一致。
    var connectorTarget: String {
        rawValue
    }

    /// 按钮文案的本地化 key。
    var titleLocalizationKey: String {
        switch self {
        case .apple: "auth.sign_in.social.apple"
        }
    }

    /// 按钮左侧的系统图标。
    var systemImage: String {
        switch self {
        case .apple: "apple.logo"
        }
    }
}
