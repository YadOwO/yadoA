#if DEBUG
import Foundation

/// 仅在隔离 UI 测试参数下使用的应用锁夹具：用假验证器代替系统的面容 ID 或密码界面，模拟器上不会弹出真的 `LAContext`。
enum AppLockUITestFixture {
    /// 是否要以「已开启应用锁」的状态启动：需要同时带隔离存储和应用锁两个启动参数。
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing-in-memory")
            && arguments.contains("--ui-testing-app-lock")
    }

    /// 准备本次自动化的应用锁设置。
    ///
    /// 先清掉上次自动化留下的开关和上锁时长，避免锁状态串进别的 UI 测试；
    /// 带 `--ui-testing-app-lock` 时再把锁打开，上锁时长默认「立即」，
    /// 额外带 `--ui-testing-app-lock-one-minute` 时为 1 分钟。
    ///
    /// - Parameter defaults: 保存应用锁设置的本机存储。
    static func prepare(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: AppLockController.isEnabledKey)
        defaults.removeObject(forKey: AppLockTimeout.storageKey)
        guard isEnabled else { return }
        defaults.set(true, forKey: AppLockController.isEnabledKey)
        let isOneMinute = ProcessInfo.processInfo.arguments.contains("--ui-testing-app-lock-one-minute")
        defaults.set((isOneMinute ? AppLockTimeout.oneMinute : .immediately).rawValue, forKey: AppLockTimeout.storageKey)
    }

    /// 假验证器：设备恒可验证、验证恒通过，不弹任何系统界面；解锁靠 UI 测试点「解锁」按钮触发。
    struct Authenticator: AppLockAuthenticating {
        func availability() -> AppLockAvailability { .available }

        func authenticate(localizedReason: String) async -> AppLockAuthenticationResult { .success }
    }
}
#endif
