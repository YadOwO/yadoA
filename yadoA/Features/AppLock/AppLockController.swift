import Foundation
import Observation
import SwiftUI

/// 应用锁的「离开多久后上锁」选项；只在本机 UserDefaults 里保存。
enum AppLockTimeout: Int, CaseIterable, Identifiable, Hashable {
    /// 一离开 App（进入后台）再回来就上锁；默认值。
    case immediately = 0
    /// 离开满 1 分钟后再回来才上锁。
    case oneMinute = 60
    /// 离开满 5 分钟后再回来才上锁。
    case fiveMinutes = 300

    /// 在本机保存的上锁时长偏好键，存的是 `rawValue`（秒）。
    static let storageKey = "app.lock.timeout"

    /// 选择项的稳定标识。
    var id: Int { rawValue }

    /// 离开多少秒后再回来就要重新上锁。
    var seconds: TimeInterval { TimeInterval(rawValue) }

    /// 选择项标题的本地化资源键，供设置页的选择行使用。
    var titleLocalizationKey: String {
        switch self {
        case .immediately: "settings.app_lock.timeout.immediately"
        case .oneMinute: "settings.app_lock.timeout.one_minute"
        case .fiveMinutes: "settings.app_lock.timeout.five_minutes"
        }
    }
}

/// 设备能不能做「设备主人验证」（面容 ID、触控 ID 或设备密码）。
enum AppLockAvailability {
    /// 可以验证。
    case available
    /// 设备没设置密码，系统无法做设备主人验证。
    case passcodeNotSet
    /// 其他原因暂时不能验证（例如系统拒绝了这次评估）；按「需要设备密码」处理。
    case unavailable
}

/// 一次系统验证的结果。
enum AppLockAuthenticationResult {
    /// 验证通过。
    case success
    /// 用户或系统取消了验证界面。
    case cancelled
    /// 验证没有通过（失败次数过多、被锁定等系统返回的其他错误）。
    case failed
    /// 验证时发现设备没有设置密码。
    case passcodeNotSet
}

/// 系统设备主人验证的抽象，方便单测和 UI 自动化注入假验证器。
@MainActor
protocol AppLockAuthenticating {
    /// 当前设备能不能做设备主人验证；只查询，不弹任何界面。
    func availability() -> AppLockAvailability

    /// 弹出系统验证界面，等待用户完成。
    ///
    /// - Parameter localizedReason: 展示在系统验证界面上的原因说明。
    /// - Returns: 这次验证的结果。
    func authenticate(localizedReason: String) async -> AppLockAuthenticationResult
}

/// 打开应用锁这一步的结果。
enum AppLockEnableResult {
    /// 验证通过，应用锁已开启。
    case enabled
    /// 设备没设置密码（或系统暂时不能验证），应用锁没有开启，需要提示用户先去系统设置里设置密码。
    case passcodeNotSet
    /// 用户取消或验证失败，应用锁没有开启。
    case notAuthenticated
}

/// 应用锁的状态机：开关、上锁时长、冷启动与回前台时的上锁判断、切换器遮挡和自动验证。
///
/// 验证器、时钟和 UserDefaults 都由外部注入，单测不用真的弹系统界面，也不用真的等时间。
/// 锁屏和遮挡由 `AppLockGate` 放到独立窗口里显示，本类只负责决定「该不该显示」。
///
/// 首次解锁之后 `ContentView` 一直留在视图树里：重新上锁只用独立窗口盖住，不卸载、不重建，
/// 这样本地数据引导、同步引擎和正在填写的表单都不受影响。
@MainActor
@Observable
final class AppLockController {
    /// 应用锁开关在本机的存储键。
    static let isEnabledKey = "app.lock.isEnabled"

    /// 应用锁是否开启；只能通过 `enable()` 和 `disable()` 改变。
    private(set) var isEnabled: Bool

    /// 离开多久后上锁；修改后立即写回本机。
    var timeout: AppLockTimeout {
        didSet { defaults.set(timeout.rawValue, forKey: AppLockTimeout.storageKey) }
    }

    /// 当前是否处于锁定状态；冷启动时开了锁就是锁着。
    private(set) var isLocked: Bool

    /// 这次启动以来是否解锁（或关闭应用锁）过；为 true 之后 `ContentView` 不会再被卸载。
    private(set) var hasUnlockedThisLaunch = false

    /// 是否正在等系统验证结果。系统验证界面会让 App 进入 `.inactive`，所以验证期间不叠加遮挡。
    private(set) var isAuthenticating = false

    /// 最近一次收到的场景阶段，决定要不要显示遮挡。
    private var scenePhase: ScenePhase = .active

    /// 进入后台的时刻；只在开了锁时记录，回到前台算完离开时长后清掉。
    private var backgroundedAt: Date?

    /// 这一轮锁定是否已经自动发起过验证；用户取消后不再自动弹，改由「解锁」按钮重试。
    private var hasAutoPromptedForCurrentLock = false

    /// 保存开关和上锁时长的本机存储。
    private let defaults: UserDefaults

    /// 系统设备主人验证。
    private let authenticator: any AppLockAuthenticating

    /// 当前时间；用墙上时间计算离开时长，测试注入可控的时钟。
    private let now: () -> Date

    /// 锁屏出现且 App 进入 active 后，是否自动发起一次验证；UI 自动化关闭它，靠点按钮解锁。
    private let autoAuthenticates: Bool

    /// 系统验证界面上的原因说明，每次验证时现取，语言跟随 App 当前设置。
    private let localizedReason: () -> String

    /// 创建应用锁状态机，并读出上次保存的开关和上锁时长。
    ///
    /// - Parameters:
    ///   - defaults: 保存开关和上锁时长的本机存储，测试传入隔离实例。
    ///   - authenticator: 系统设备主人验证，测试和 UI 自动化传入假验证器。
    ///   - now: 当前时间；用来计算离开时长，测试传入可控的时钟。
    ///   - autoAuthenticates: 锁屏出现且 App 进入 active 后是否自动发起一次验证。
    ///   - localizedReason: 系统验证界面上的原因说明。
    init(
        defaults: UserDefaults = .standard,
        authenticator: any AppLockAuthenticating,
        now: @escaping () -> Date = { .now },
        autoAuthenticates: Bool = true,
        localizedReason: @escaping () -> String
    ) {
        self.defaults = defaults
        self.authenticator = authenticator
        self.now = now
        self.autoAuthenticates = autoAuthenticates
        self.localizedReason = localizedReason
        let isEnabled = defaults.bool(forKey: Self.isEnabledKey)
        self.isEnabled = isEnabled
        // 读不到或值无法识别时按「立即」处理
        timeout = AppLockTimeout(rawValue: defaults.integer(forKey: AppLockTimeout.storageKey)) ?? .immediately
        isLocked = isEnabled
    }

    /// 是否应该渲染主界面：没开锁，或者这次启动已经解锁过。
    ///
    /// 冷启动开了锁时为 false，验证通过前不挂载 `ContentView`，本地数据引导也不会启动。
    var shouldRenderContent: Bool {
        !isEnabled || hasUnlockedThisLaunch
    }

    /// 是否显示切换器遮挡：只有开了锁、没有锁屏、没在验证、且 App 不在前台活跃时才盖。
    var isPrivacyCoverVisible: Bool {
        isEnabled && !isLocked && !isAuthenticating && scenePhase != .active
    }

    /// 独立窗口是否要显示：锁屏或遮挡任一出现就显示。
    var isOverlayVisible: Bool {
        isLocked || isPrivacyCoverVisible
    }

    /// 处理 App 场景阶段的变化：记录进入后台的时刻，回前台时判断要不要重新上锁，并在需要时自动发起验证。
    ///
    /// 超时只按「进入 `.background` 的时刻」计算，只到 `.inactive`（下拉通知中心、系统验证界面）不算离开，
    /// 否则验证本身就会触发重新上锁，形成死循环。
    ///
    /// - Parameter phase: 新的场景阶段。
    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .background, isEnabled {
            backgroundedAt = now()
        }
        if phase != .background, let backgroundedAt {
            let elapsed = now().timeIntervalSince(backgroundedAt)
            // 系统时钟被往回调时 elapsed 为负，无法证明没超时，同样重新上锁
            if elapsed < 0 || elapsed >= timeout.seconds {
                lock()
            }
            self.backgroundedAt = nil
        }
        if phase == .active, isLocked, autoAuthenticates, !hasAutoPromptedForCurrentLock, !isAuthenticating {
            hasAutoPromptedForCurrentLock = true
            Task { await unlock() }
        }
        scenePhase = phase
    }

    /// 进入锁定状态，并允许这一轮锁定自动发起一次验证。
    private func lock() {
        isLocked = true
        hasAutoPromptedForCurrentLock = false
    }

    /// 发起系统验证来解锁；没锁或正在验证时什么都不做。
    ///
    /// 验证通过才解锁，取消或失败保持锁定，用户可以再点「解锁」重试。
    /// 如果设备密码后来被移除了，系统已经无法验证，这里直接关闭应用锁并放行，不把用户锁在自己的数据外面。
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        if authenticator.availability() == .passcodeNotSet {
            disable()
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let result = await authenticator.authenticate(localizedReason: localizedReason())
        switch result {
        case .success:
            isLocked = false
            hasUnlockedThisLaunch = true
        case .passcodeNotSet:
            disable()
        case .cancelled, .failed:
            break
        }
    }

    /// 打开应用锁：先验证一次设备主人，通过才算开启。
    ///
    /// 只有验证成功后才写入本机存储；取消或失败时开关保持关闭，不会先写再回滚。
    ///
    /// - Returns: 开启结果；设备没设密码（或系统暂时无法验证）时不会发起验证。
    func enable() async -> AppLockEnableResult {
        guard !isAuthenticating else { return .notAuthenticated }
        guard authenticator.availability() == .available else { return .passcodeNotSet }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let result = await authenticator.authenticate(localizedReason: localizedReason())
        switch result {
        case .success:
            isEnabled = true
            defaults.set(true, forKey: Self.isEnabledKey)
            // 刚验证过，不需要马上再锁一次
            isLocked = false
            hasUnlockedThisLaunch = true
            return .enabled
        case .passcodeNotSet:
            return .passcodeNotSet
        case .cancelled, .failed:
            return .notAuthenticated
        }
    }

    /// 关闭应用锁：不再验证一次，立即解锁并放行。
    ///
    /// 同时把「这次启动已解锁」置为 true，之后即使再次打开应用锁，主界面也不会被卸载重建。
    func disable() {
        isEnabled = false
        defaults.set(false, forKey: Self.isEnabledKey)
        isLocked = false
        hasUnlockedThisLaunch = true
        backgroundedAt = nil
    }
}
