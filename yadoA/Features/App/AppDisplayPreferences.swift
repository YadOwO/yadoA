import SwiftUI

/// 应用界面语言偏好；跟随系统时保留系统提供的语言与地区环境。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    /// 在本机保存的语言偏好键，不修改系统或其他应用的语言。
    static let storageKey = "app.display.language"

    /// 选择项的稳定标识。
    var id: String { rawValue }

    /// 选择项标题的本地化资源键。
    var titleLocalizationKey: String {
        switch self {
        case .system: "profile.preference.system"
        case .simplifiedChinese: "profile.language.simplified_chinese"
        case .english: "profile.language.english"
        }
    }

    /// 根据选择解析语言；系统选项直接使用上层环境，避免缓存旧语言。
    func resolvedLocale(systemLocale: Locale) -> Locale {
        self == .system ? systemLocale : Locale(identifier: rawValue)
    }
}

/// 应用亮暗色偏好；系统选项不强制指定外观。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// 在本机保存的外观偏好键。
    static let storageKey = "app.display.appearance"

    /// 选择项的稳定标识。
    var id: String { rawValue }

    /// 选择项标题的本地化资源键。
    var titleLocalizationKey: String {
        switch self {
        case .system: "profile.preference.system"
        case .light: "profile.appearance.light"
        case .dark: "profile.appearance.dark"
        }
    }

    /// 系统选项返回空值，让窗口随系统外观变化。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 应用启动后首先展示的一级页面偏好；决定冷启动落点，并让对应 Tab 排在底部导航第一位。
enum AppStartPage: String, CaseIterable, Identifiable {
    /// 启动后进入记账页。
    case home
    /// 启动后进入账户列表。
    case accounts

    /// 在本机保存的启动页面偏好键。
    static let storageKey = "app.display.startPage"

    /// 选择项的稳定标识。
    var id: String { rawValue }

    /// 启动页面对应的一级 Tab。
    var tab: AppTab {
        switch self {
        case .home: .home
        case .accounts: .accounts
        }
    }

    /// 选择项标题直接沿用对应 Tab 的本地化资源键，保证与底部导航文案一致。
    var titleLocalizationKey: String { tab.titleLocalizationKey }

    /// 读取已保存的启动页面；未设置或值无法识别时回退到记账页。
    ///
    /// - Parameter defaults: 保存偏好的本机存储，测试时可注入隔离实例。
    /// - Returns: 当前生效的启动页面。
    static func stored(in defaults: UserDefaults = .standard) -> AppStartPage {
        defaults.string(forKey: storageKey).flatMap(AppStartPage.init(rawValue:)) ?? .home
    }
}

/// 在窗口根部应用显示偏好，使各 Tab 与其弹层共享同一语言和外观。
struct AppDisplayPreferencesModifier: ViewModifier {
    @Environment(\.locale) private var systemLocale
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    func body(content: Content) -> some View {
        content
            .environment(\.locale, language.resolvedLocale(systemLocale: systemLocale))
            .preferredColorScheme(appearance.colorScheme)
    }
}
