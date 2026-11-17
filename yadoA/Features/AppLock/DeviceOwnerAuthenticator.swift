import Foundation
import LocalAuthentication

/// 用系统 LocalAuthentication 做设备主人验证：面容 ID、触控 ID，失败时退回设备密码。
///
/// 一律用 `.deviceOwnerAuthentication`，而不是 `.deviceOwnerAuthenticationWithBiometrics`：
/// 生物识别失败、被锁定或被移除时，系统会自动退回设备密码，用户不会被锁在 App 外面。
/// 验证完全由系统在本机完成，App 拿不到面容或指纹数据，只知道通过与否。
struct DeviceOwnerAuthenticator: AppLockAuthenticating {
    /// 设备能不能做设备主人验证。
    ///
    /// 每次都新建 `LAContext`：同一个上下文验证成功后会缓存结果，复用会让之后的验证被直接放行。
    ///
    /// - Returns: 可以验证、设备没设置密码，或其他原因暂时不能验证。
    func availability() -> AppLockAvailability {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            return .available
        }
        if let error, error.domain == LAError.errorDomain, error.code == LAError.Code.passcodeNotSet.rawValue {
            return .passcodeNotSet
        }
        return .unavailable
    }

    /// 弹出系统验证界面。
    ///
    /// 每次都新建 `LAContext`，理由同 `availability()`。
    ///
    /// - Parameter localizedReason: 展示在系统验证界面上的原因说明。
    /// - Returns: 验证结果；用户取消、App 或系统取消都算 `.cancelled`，设备没设置密码为 `.passcodeNotSet`，其余错误都算 `.failed`。
    func authenticate(localizedReason: String) async -> AppLockAuthenticationResult {
        let context = LAContext()
        do {
            let isSuccess = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: localizedReason)
            return isSuccess ? .success : .failed
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                return .cancelled
            case .passcodeNotSet:
                return .passcodeNotSet
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }
}
