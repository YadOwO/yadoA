import Foundation
import Observation

/// 隐私政策同意状态：中国大陆地区首次启动时要用户先同意，同意之前 App 不发任何网络请求。
///
/// 只对系统地区是中国大陆的用户生效（港澳台和其他地区不弹同意卡，联网不受限制）。
/// 同意的是哪一版政策存在 UserDefaults 里，政策有大改时把 `currentVersion` 加 1，同意过旧版本的用户会再看到同意卡；
/// 点「不同意」只记一个标记，App 进入完全离线的本地记账模式，之后启动不再弹卡，可以从「我的」页重新查看并同意。
@Observable
final class PrivacyAgreementStore {
    /// 当前隐私政策的版本号；政策有大改时加 1，已同意的版本低于它时视为没同意，会再弹一次同意卡。
    static let currentVersion = 1

    /// 已同意的政策版本号的存储键。
    static let agreedVersionKey = "privacy.agreement.agreedVersion"

    /// 「不同意」标记的存储键。
    static let declinedKey = "privacy.agreement.declined"

    /// 该地区是否需要先同意隐私政策：只有中国大陆需要，港澳台和其他地区都不需要。
    ///
    /// 按系统地区判断；App 内选的语言只影响界面语言，不影响这里。
    ///
    /// - Parameter region: 系统地区，通常取 `Locale.current.region`。
    static func requiresAgreement(region: Locale.Region?) -> Bool {
        region == .chinaMainland
    }

    /// 清除同意状态和「不同意」标记，UI 自动化用来模拟首次启动。
    ///
    /// - Parameter defaults: 保存同意状态的存储。
    static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: agreedVersionKey)
        defaults.removeObject(forKey: declinedKey)
    }

    /// 已同意的政策版本号；没同意过为 0。
    private(set) var agreedVersion: Int

    /// 用户是否点过「不同意」。
    private(set) var isDeclined: Bool

    /// 离线模式下用户点了「查看并同意隐私政策」，同意卡正在重新展示。
    private(set) var isReviewPresented = false

    /// 当前地区是否需要先同意隐私政策。
    private let requiresAgreement: Bool

    /// 保存同意状态的存储。
    private let defaults: UserDefaults

    /// 创建同意状态，并读出上次保存的选择。
    ///
    /// - Parameters:
    ///   - defaults: 保存同意状态的存储，测试传入隔离实例。
    ///   - requiresAgreement: 当前是否需要同意，默认按系统地区判断。
    init(
        defaults: UserDefaults = .standard,
        requiresAgreement: Bool = PrivacyAgreementStore.requiresAgreement(region: Locale.current.region)
    ) {
        self.defaults = defaults
        self.requiresAgreement = requiresAgreement
        agreedVersion = defaults.integer(forKey: Self.agreedVersionKey)
        isDeclined = defaults.bool(forKey: Self.declinedKey)
    }

    /// 是否已经同意当前版本的隐私政策。
    var hasAgreedCurrentVersion: Bool {
        agreedVersion >= Self.currentVersion
    }

    /// 是否允许联网：不需要同意的地区总是允许，需要同意的地区要先同意当前版本。
    var allowsNetwork: Bool {
        !requiresAgreement || hasAgreedCurrentVersion
    }

    /// 是否还要用户做选择：需要同意、没同意当前版本，而且没点过「不同意」。
    var needsDecision: Bool {
        requiresAgreement && !hasAgreedCurrentVersion && !isDeclined
    }

    /// 是否处于离线模式：不允许联网时 App 只做本地记账。
    var isOfflineMode: Bool {
        !allowsNetwork
    }

    /// 同意卡是否要盖在界面上：首次需要选择，或离线模式下用户主动重新查看。
    var isCardPresented: Bool {
        needsDecision || isReviewPresented
    }

    /// 同意当前版本：记下版本号、清除「不同意」标记并关掉同意卡，联网功能随即恢复。
    func agree() {
        defaults.set(Self.currentVersion, forKey: Self.agreedVersionKey)
        defaults.removeObject(forKey: Self.declinedKey)
        agreedVersion = Self.currentVersion
        isDeclined = false
        isReviewPresented = false
    }

    /// 不同意：记下「不同意」标记并关掉同意卡，App 保持离线模式；不碰已同意的版本号。
    func decline() {
        defaults.set(true, forKey: Self.declinedKey)
        isDeclined = true
        isReviewPresented = false
    }

    /// 离线模式下重新弹出同意卡；已经允许联网时什么都不做。
    func reviewAgain() {
        guard isOfflineMode else { return }
        isReviewPresented = true
    }
}
