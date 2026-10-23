import Foundation

/// 同步失败和生命周期错误对应的界面文案键。
enum SyncMessages {
    /// 接口错误对应的说明文案键。
    ///
    /// - Parameter error: 同步接口错误。
    /// - Returns: `Localizable.xcstrings` 中的文案键。
    static func localizationKey(for error: SyncAPIError) -> String {
        switch error {
        case .notSignedIn, .sessionExpired, .unauthorized:
            "sync.error.signIn"
        case .epochMismatch:
            "sync.error.epochMismatch"
        case .serviceUnavailable:
            "sync.error.serviceUnavailable"
        case .timeout, .network:
            "sync.error.network"
        case .invalidContract:
            "sync.error.invalidContract"
        }
    }

    /// 一轮同步失败的原因对应的文案键。
    ///
    /// - Parameter failure: 同步引擎报告的失败原因。
    /// - Returns: `Localizable.xcstrings` 中的文案键。
    static func localizationKey(for failure: SyncFailure) -> String {
        switch failure {
        case let .api(error):
            localizationKey(for: error)
        case .storage:
            "sync.error.storage"
        }
    }

    /// 生命周期操作（开启、清空、删除云端数据等）失败对应的文案键。
    ///
    /// - Parameter error: 操作抛出的错误；不是 `SyncLifecycleError` 时按读写本机数据失败处理。
    /// - Returns: `Localizable.xcstrings` 中的文案键。
    static func localizationKey(forLifecycleError error: Error) -> String {
        switch error as? SyncLifecycleError {
        case .boundToAnotherAccount:
            "sync.error.boundToAnotherAccount"
        case .notBound:
            "sync.error.notBound"
        case let .api(apiError):
            localizationKey(for: apiError)
        case .storage, nil:
            "sync.error.storage"
        }
    }
}
