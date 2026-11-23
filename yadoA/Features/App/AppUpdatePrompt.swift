import Observation
import SwiftUI

/// 「需要更新」提示的全局状态：联网接口返回 426（App 版本低于服务端要求）时，由各 API 客户端通知它。
///
/// - 每次启动最多弹一次：状态只存在内存里、不持久化，下次启动再遇到 426 会再弹；
///   同一次启动里别的页面再收到 426，只显示各自行内的「需要更新 App 后才能使用」。
/// - 只拦联网功能（同步、AI、点数、意见反馈），本机记账照常可用，不清本机数据、不退出登录。
/// - 用系统 alert 展示，颜色、字体由系统处理，浅色、深色外观自动适配。
@MainActor
@Observable
final class AppUpdatePrompt {
    /// 应用内唯一的提示通道。
    static let shared = AppUpdatePrompt()

    /// 服务端要求升级时返回的 HTTP 状态码。
    nonisolated static let upgradeRequiredStatusCode = 426

    /// App 的 App Store 数字 ID；上架后填 App Store 的数字 ID。
    ///
    /// 为 nil 时改用 `AppUpdateNotice` 查到的产品页地址；也没查到过时提示里只有文字和「知道了」按钮，没有跳转按钮。
    nonisolated static let appStoreID: String? = nil

    /// App 在 App Store 上的产品页地址：优先用配置的数字 ID，没配置时用「发现新版本」查 App Store 时存下的地址；
    /// 两者都没有时为 nil，提示里就不显示跳转按钮。
    static var appStoreURL: URL? {
        AppStoreLink.productURL(id: appStoreID) ?? AppUpdateNotice.shared.storeURL
    }

    /// 是否正在显示提示，供 alert 绑定。
    var isPresented = false

    /// 本次启动是否已经弹过；弹过之后不再弹第二次。
    private(set) var hasPrompted = false

    /// 弹出「需要更新」提示；本次启动已经弹过时什么也不做。
    func present() {
        guard !hasPrompted else { return }
        hasPrompted = true
        isPresented = true
    }

    /// 通知全局弹出升级提示；可以从任意线程调用，内部切回主线程。
    nonisolated static func reportUpgradeRequired() {
        Task { @MainActor in
            AppUpdatePrompt.shared.present()
        }
    }

    /// 检查响应是否表示 App 版本过低；是的话通知全局弹出升级提示。
    ///
    /// - Parameter response: 接口返回的 HTTP 响应。
    /// - Returns: 状态码是 426 时为 true，调用方据此抛出各自的 `.upgradeRequired`；否则为 false。
    nonisolated static func checkUpgradeRequired(_ response: HTTPURLResponse) -> Bool {
        guard response.statusCode == upgradeRequiredStatusCode else { return false }
        reportUpgradeRequired()
        return true
    }
}

/// 在应用根视图上挂「需要更新」系统 alert。
///
/// 只拦联网功能，本机记账照常可用；有 App Store 地址时给「前往 App Store」和「稍后」，没有时只给「知道了」。
/// 用系统 alert 和系统按钮样式，浅色、深色外观自动适配。
struct AppUpdatePromptModifier: ViewModifier {
    /// 全局提示状态。
    @State private var prompt = AppUpdatePrompt.shared

    /// 应用当前语言环境，用于取文案。
    @Environment(\.locale) private var locale

    /// 打开 App Store 页面。
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.alert(text("appUpdate.title"), isPresented: $prompt.isPresented) {
            if let url = AppUpdatePrompt.appStoreURL {
                Button(text("appUpdate.openAppStore")) {
                    openURL(url)
                }
                Button(text("appUpdate.later"), role: .cancel) {}
            } else {
                Button(text("appUpdate.ok"), role: .cancel) {}
            }
        } message: {
            Text(text("appUpdate.message"))
        }
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
