import Foundation
import SwiftUI
import Testing
@testable import yadoA

/// 假的系统验证器：验证结果按队列依次给出，队列用完后一律通过，并记录验证被调用了几次。
@MainActor
private final class FakeAuthenticator: AppLockAuthenticating {
    /// `availability()` 返回的值。
    var availabilityValue: AppLockAvailability = .available
    /// 每次 `authenticate` 依次给出的结果；用完后一律 `.success`。
    var results: [AppLockAuthenticationResult]
    /// `authenticate` 被调用的次数。
    private(set) var authenticateCount = 0
    /// 每次 `authenticate` 开始时的回调，用来观察「验证中」的状态。
    var onAuthenticate: (() -> Void)?

    init(results: [AppLockAuthenticationResult] = []) {
        self.results = results
    }

    func availability() -> AppLockAvailability {
        availabilityValue
    }

    func authenticate(localizedReason: String) async -> AppLockAuthenticationResult {
        authenticateCount += 1
        onAuthenticate?()
        return results.isEmpty ? .success : results.removeFirst()
    }
}

/// 可手动拨动的时钟，注入控制器的 `now`。
private final class MutableClock {
    /// 当前时间。
    var current = Date(timeIntervalSince1970: 0)

    /// 把时间往后拨（负数为往回调）。
    func advance(_ seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

@Suite("应用锁", .serialized)
@MainActor
struct AppLockControllerTests {
    /// 每个用例一份隔离的本机存储。
    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let suiteName = "AppLockControllerTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// 创建控制器；除测自动验证的用例外都关闭自动验证，免得后台任务干扰断言。
    ///
    /// `authenticator` 不能写成 `FakeAuthenticator()` 默认参数：默认参数在非隔离上下文求值，而它的初始化方法在 MainActor 上，
    /// 所以默认传 `nil`，到方法体（MainActor）里再创建。
    private func makeController(
        defaults: UserDefaults,
        authenticator: FakeAuthenticator? = nil,
        clock: MutableClock = MutableClock(),
        autoAuthenticates: Bool = false
    ) -> AppLockController {
        let authenticator = authenticator ?? FakeAuthenticator()
        return AppLockController(
            defaults: defaults,
            authenticator: authenticator,
            now: { clock.current },
            autoAuthenticates: autoAuthenticates,
            localizedReason: { "Unlock" }
        )
    }

    /// 预先写好「已开锁」的存储，冷启动后验证通过一次，得到一个处于「已解锁」状态的控制器。
    private func makeUnlockedController(
        defaults: UserDefaults,
        timeout: AppLockTimeout,
        authenticator: FakeAuthenticator? = nil,
        clock: MutableClock = MutableClock()
    ) async -> AppLockController {
        let authenticator = authenticator ?? FakeAuthenticator()
        defaults.set(true, forKey: AppLockController.isEnabledKey)
        defaults.set(timeout.rawValue, forKey: AppLockTimeout.storageKey)
        let controller = makeController(defaults: defaults, authenticator: authenticator, clock: clock)
        await controller.unlock()
        return controller
    }

    /// 让控制器里用 `Task` 发起的自动验证跑完。
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    @Test("默认关闭：渲染主界面、不上锁、不遮挡，上锁时长默认「立即」")
    func defaultsToDisabled() throws {
        let controller = makeController(defaults: try makeDefaults("default-off"))

        #expect(!controller.isEnabled)
        #expect(!controller.isLocked)
        #expect(controller.shouldRenderContent)
        #expect(controller.timeout == .immediately)

        for phase in [ScenePhase.inactive, .background] {
            controller.handleScenePhase(phase)
            #expect(!controller.isPrivacyCoverVisible)
            #expect(!controller.isOverlayVisible)
        }
    }

    @Test("打开时设备没设密码：提示先设置密码，不发起验证，也不写入存储")
    func enableWithoutPasscode() async throws {
        for availability in [AppLockAvailability.passcodeNotSet, .unavailable] {
            let defaults = try makeDefaults("enable-no-passcode")
            let authenticator = FakeAuthenticator()
            authenticator.availabilityValue = availability
            let controller = makeController(defaults: defaults, authenticator: authenticator)

            let result = await controller.enable()

            #expect(result == .passcodeNotSet)
            #expect(authenticator.authenticateCount == 0)
            #expect(!controller.isEnabled)
            #expect(defaults.object(forKey: AppLockController.isEnabledKey) == nil)
        }
    }

    @Test("打开时验证被取消或失败：开关保持关闭，不写入存储")
    func enableWhenNotAuthenticated() async throws {
        let defaults = try makeDefaults("enable-cancelled")
        let authenticator = FakeAuthenticator(results: [.cancelled, .failed])
        let controller = makeController(defaults: defaults, authenticator: authenticator)

        #expect(await controller.enable() == .notAuthenticated)
        #expect(await controller.enable() == .notAuthenticated)

        #expect(authenticator.authenticateCount == 2)
        #expect(!controller.isEnabled)
        #expect(!controller.isAuthenticating)
        #expect(defaults.object(forKey: AppLockController.isEnabledKey) == nil)
    }

    @Test("打开时验证通过：写入存储、开启，当前不上锁")
    func enableAfterSuccessfulAuthentication() async throws {
        let defaults = try makeDefaults("enable-success")
        let authenticator = FakeAuthenticator(results: [.success])
        let controller = makeController(defaults: defaults, authenticator: authenticator)

        #expect(await controller.enable() == .enabled)

        #expect(authenticator.authenticateCount == 1)
        #expect(controller.isEnabled)
        #expect(!controller.isLocked)
        #expect(controller.shouldRenderContent)
        #expect(defaults.bool(forKey: AppLockController.isEnabledKey))
        // 开启后离开前台就要遮挡
        controller.handleScenePhase(.inactive)
        #expect(controller.isPrivacyCoverVisible)
    }

    @Test("开着锁冷启动：先上锁、不渲染主界面；验证失败仍锁着，通过后解锁")
    func coldStartWhenEnabled() async throws {
        let defaults = try makeDefaults("cold-start")
        defaults.set(true, forKey: AppLockController.isEnabledKey)
        let authenticator = FakeAuthenticator(results: [.failed, .success])
        let controller = makeController(defaults: defaults, authenticator: authenticator)

        #expect(controller.isEnabled)
        #expect(controller.isLocked)
        #expect(!controller.shouldRenderContent)
        #expect(controller.isOverlayVisible)

        await controller.unlock()
        #expect(controller.isLocked)
        #expect(!controller.shouldRenderContent)
        #expect(!controller.isAuthenticating)

        await controller.unlock()
        #expect(!controller.isLocked)
        #expect(controller.shouldRenderContent)
        #expect(!controller.isOverlayVisible)
        #expect(authenticator.authenticateCount == 2)
    }

    @Test("没锁的时候 unlock 什么都不做")
    func unlockWhenNotLockedDoesNothing() async throws {
        let authenticator = FakeAuthenticator()
        let controller = makeController(defaults: try makeDefaults("unlock-noop"), authenticator: authenticator)

        await controller.unlock()

        #expect(authenticator.authenticateCount == 0)
    }

    @Test("立即：进后台再回到前台就上锁")
    func immediateTimeoutLocksAfterBackground() async throws {
        let controller = await makeUnlockedController(defaults: try makeDefaults("immediate"), timeout: .immediately)
        #expect(!controller.isLocked)

        controller.handleScenePhase(.background)
        controller.handleScenePhase(.active)

        #expect(controller.isLocked)
        #expect(controller.isOverlayVisible)
        // 主界面已经挂载过，重新上锁不卸载
        #expect(controller.shouldRenderContent)
    }

    @Test("1 分钟：30 秒回来不锁，超过 1 分钟回来才锁")
    func oneMinuteTimeout() async throws {
        let clock = MutableClock()
        let controller = await makeUnlockedController(
            defaults: try makeDefaults("one-minute"),
            timeout: .oneMinute,
            clock: clock
        )

        controller.handleScenePhase(.background)
        clock.advance(30)
        controller.handleScenePhase(.active)
        #expect(!controller.isLocked)

        controller.handleScenePhase(.background)
        clock.advance(61)
        controller.handleScenePhase(.active)
        #expect(controller.isLocked)
    }

    @Test("5 分钟：299 秒回来不锁，满 300 秒就锁")
    func fiveMinutesTimeout() async throws {
        let clock = MutableClock()
        let controller = await makeUnlockedController(
            defaults: try makeDefaults("five-minutes"),
            timeout: .fiveMinutes,
            clock: clock
        )

        controller.handleScenePhase(.background)
        clock.advance(299)
        controller.handleScenePhase(.active)
        #expect(!controller.isLocked)

        controller.handleScenePhase(.background)
        clock.advance(300)
        controller.handleScenePhase(.active)
        #expect(controller.isLocked)
    }

    @Test("系统时钟被往回调（离开时长为负）也按超时上锁")
    func negativeElapsedLocks() async throws {
        let clock = MutableClock()
        let controller = await makeUnlockedController(
            defaults: try makeDefaults("clock-backwards"),
            timeout: .fiveMinutes,
            clock: clock
        )

        controller.handleScenePhase(.background)
        clock.advance(-10)
        controller.handleScenePhase(.active)

        #expect(controller.isLocked)
    }

    @Test("只到非活跃、没进过后台，不会重新上锁")
    func inactiveWithoutBackgroundDoesNotRelock() async throws {
        let controller = await makeUnlockedController(defaults: try makeDefaults("inactive-only"), timeout: .immediately)

        controller.handleScenePhase(.inactive)
        controller.handleScenePhase(.active)

        #expect(!controller.isLocked)
    }

    @Test("遮挡：开了锁且已解锁时，非活跃或后台显示，回到前台隐藏")
    func privacyCoverFollowsScenePhase() async throws {
        let controller = await makeUnlockedController(defaults: try makeDefaults("cover"), timeout: .fiveMinutes)

        #expect(!controller.isPrivacyCoverVisible)
        controller.handleScenePhase(.inactive)
        #expect(controller.isPrivacyCoverVisible)
        #expect(controller.isOverlayVisible)

        controller.handleScenePhase(.active)
        #expect(!controller.isPrivacyCoverVisible)
        #expect(!controller.isOverlayVisible)

        controller.handleScenePhase(.background)
        #expect(controller.isPrivacyCoverVisible)

        // 5 分钟内回来：不上锁，遮挡随回到前台隐藏
        controller.handleScenePhase(.active)
        #expect(!controller.isLocked)
        #expect(!controller.isPrivacyCoverVisible)
    }

    @Test("验证期间不显示遮挡（系统验证界面会让 App 变成非活跃），验证结束后仍不在前台才遮挡")
    func privacyCoverHiddenWhileAuthenticating() async throws {
        let defaults = try makeDefaults("cover-authenticating")
        defaults.set(true, forKey: AppLockController.isEnabledKey)
        let authenticator = FakeAuthenticator()
        let controller = makeController(defaults: defaults, authenticator: authenticator)
        controller.handleScenePhase(.inactive)

        var isAuthenticating = false
        var isCoverVisibleDuringAuthentication = true
        var isOverlayVisibleDuringAuthentication = false
        authenticator.onAuthenticate = {
            isAuthenticating = controller.isAuthenticating
            isCoverVisibleDuringAuthentication = controller.isPrivacyCoverVisible
            isOverlayVisibleDuringAuthentication = controller.isOverlayVisible
        }
        await controller.unlock()

        #expect(isAuthenticating)
        #expect(!isCoverVisibleDuringAuthentication)
        // 验证期间仍由锁屏盖着
        #expect(isOverlayVisibleDuringAuthentication)
        #expect(!controller.isLocked)
        #expect(controller.isPrivacyCoverVisible)
    }

    @Test("设备密码被移除：解锁时自动关闭应用锁并放行，不发起验证")
    func passcodeRemovedBeforeUnlock() async throws {
        let defaults = try makeDefaults("passcode-removed")
        defaults.set(true, forKey: AppLockController.isEnabledKey)
        let authenticator = FakeAuthenticator()
        authenticator.availabilityValue = .passcodeNotSet
        let controller = makeController(defaults: defaults, authenticator: authenticator)
        #expect(controller.isLocked)

        await controller.unlock()

        #expect(authenticator.authenticateCount == 0)
        #expect(!controller.isEnabled)
        #expect(!controller.isLocked)
        #expect(controller.shouldRenderContent)
        #expect(!defaults.bool(forKey: AppLockController.isEnabledKey))
    }

    @Test("验证时才发现设备没设密码：同样关闭应用锁并放行")
    func passcodeRemovedDuringAuthentication() async throws {
        let defaults = try makeDefaults("passcode-removed-during")
        defaults.set(true, forKey: AppLockController.isEnabledKey)
        let authenticator = FakeAuthenticator(results: [.passcodeNotSet])
        let controller = makeController(defaults: defaults, authenticator: authenticator)

        await controller.unlock()

        #expect(authenticator.authenticateCount == 1)
        #expect(!controller.isEnabled)
        #expect(!controller.isLocked)
        #expect(controller.shouldRenderContent)
        #expect(!defaults.bool(forKey: AppLockController.isEnabledKey))
    }

    @Test("自动验证：锁定后第一次进入前台自动发起一次，再次进入前台不重复；重新上锁后再来一次")
    func autoAuthenticatesOncePerLock() async throws {
        let defaults = try makeDefaults("auto-authenticate")
        defaults.set(true, forKey: AppLockController.isEnabledKey)
        let authenticator = FakeAuthenticator(results: [.cancelled])
        let controller = makeController(defaults: defaults, authenticator: authenticator, autoAuthenticates: true)

        controller.handleScenePhase(.active)
        await settle()
        #expect(authenticator.authenticateCount == 1)
        // 取消后停在锁屏，等用户点按钮
        #expect(controller.isLocked)

        controller.handleScenePhase(.inactive)
        controller.handleScenePhase(.active)
        await settle()
        #expect(authenticator.authenticateCount == 1)

        // 用户点「解锁」重试，通过
        await controller.unlock()
        #expect(!controller.isLocked)
        #expect(authenticator.authenticateCount == 2)

        // 「立即」：进后台回来重新上锁，又会自动验证一次
        controller.handleScenePhase(.background)
        controller.handleScenePhase(.active)
        await settle()
        #expect(authenticator.authenticateCount == 3)
        #expect(!controller.isLocked)
    }

    @Test("关闭自动验证时，进入前台不会自动发起验证")
    func doesNotAutoAuthenticateWhenDisabled() async throws {
        let defaults = try makeDefaults("no-auto-authenticate")
        defaults.set(true, forKey: AppLockController.isEnabledKey)
        let authenticator = FakeAuthenticator()
        let controller = makeController(defaults: defaults, authenticator: authenticator, autoAuthenticates: false)

        controller.handleScenePhase(.active)
        await settle()

        #expect(authenticator.authenticateCount == 0)
        #expect(controller.isLocked)
    }

    @Test("关闭应用锁：立即解锁、不再遮挡，并写入存储")
    func disableUnlocksAndStopsCovering() async throws {
        let defaults = try makeDefaults("disable")
        let controller = await makeUnlockedController(defaults: defaults, timeout: .immediately)

        controller.disable()

        #expect(!controller.isEnabled)
        #expect(!controller.isLocked)
        #expect(defaults.object(forKey: AppLockController.isEnabledKey) as? Bool == false)
        controller.handleScenePhase(.inactive)
        #expect(!controller.isPrivacyCoverVisible)
        controller.handleScenePhase(.background)
        controller.handleScenePhase(.active)
        #expect(!controller.isLocked)
    }

    @Test("锁着的时候关闭应用锁：直接放行并渲染主界面")
    func disableWhileLockedLetsContentRender() throws {
        let defaults = try makeDefaults("disable-locked")
        defaults.set(true, forKey: AppLockController.isEnabledKey)
        let controller = makeController(defaults: defaults)
        #expect(!controller.shouldRenderContent)

        controller.disable()

        #expect(!controller.isLocked)
        #expect(controller.shouldRenderContent)
    }

    @Test("上锁时长改动后写入存储，新建的控制器能读回；读不到或无法识别时为「立即」")
    func timeoutPersists() throws {
        let defaults = try makeDefaults("timeout")
        let controller = makeController(defaults: defaults)

        controller.timeout = .fiveMinutes

        #expect(defaults.integer(forKey: AppLockTimeout.storageKey) == 300)
        #expect(makeController(defaults: defaults).timeout == .fiveMinutes)

        defaults.set(42, forKey: AppLockTimeout.storageKey)
        #expect(makeController(defaults: defaults).timeout == .immediately)
        defaults.removeObject(forKey: AppLockTimeout.storageKey)
        #expect(makeController(defaults: defaults).timeout == .immediately)
    }

    @Test("上锁时长选项的秒数")
    func timeoutSeconds() {
        #expect(AppLockTimeout.immediately.seconds == 0)
        #expect(AppLockTimeout.oneMinute.seconds == 60)
        #expect(AppLockTimeout.fiveMinutes.seconds == 300)
    }

    @Test("应用锁的文案在中英文下都有翻译")
    func localizationKeysAreTranslated() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")
        let keys = [
            "settings.section.security",
            "settings.app_lock.title",
            "settings.app_lock.timeout.title",
            "settings.app_lock.passcode_required.title",
            "settings.app_lock.passcode_required.message",
            "app_lock.reason",
            "app_lock.locked.title",
            "app_lock.unlock",
            "app_lock.privacy_cover.label",
        ] + AppLockTimeout.allCases.map { $0.titleLocalizationKey }

        for key in keys {
            #expect(AccountLocalization.string(key, locale: english) != key)
            #expect(AccountLocalization.string(key, locale: simplifiedChinese) != key)
        }
    }
}
