import Foundation
import Observation

/// 注销芽豆账号前验证身份的流程状态：选一种验证方式，通过后从 yado_hub 换到一张注销票据。
///
/// 验证方式沿用 `AccountIdentityVerificationMethod.select(for:)` 的顺序：当前邮箱验证码 → 密码 → step-up；
/// 选出 `.unavailable`（有验证方式但 App 用不上）时注销也改走 step-up，也就是重新登录 Logto 托管页。
/// 和改邮箱、改密码（`AccountCredentialChangeFlow`）不同，这里不直接调 Logto 校验：
/// 密码、邮箱验证码和重新登录后的 ID token 都交给 hub，由 hub 在服务端校验、签发票据，`DELETE /v1/account` 必须带这张票据。
///
/// 票据只存在内存里，10 分钟后过期（`AccountIdentityVerification`，从发请求的时刻起算，不会比 hub 的有效期长）；
/// 过期或 hub 说票据无效时回到验证这一步（`invalidate()`），弹层里用户已选的本机账本处理方式不受影响。
/// 由注销弹层在第一次需要验证身份时创建，之后一直保留到弹层关闭。
@MainActor
@Observable
final class AccountDeletionVerificationFlow {
    /// 操作成功后的轻提示，和改邮箱流程用同一套（`AccountCredentialChangeFlow.Notice`）。
    typealias Notice = AccountCredentialChangeFlow.Notice

    /// 当前用的验证方式；nil 表示还在读账号信息（或读取失败，`messageKey` 里有原因）。
    private(set) var method: AccountIdentityVerificationMethod?

    /// 验证身份时输入的密码；验证通过后立即清空。
    var password = ""

    /// 发到当前邮箱的验证码输入。
    var identityCode = ""

    /// 上次给当前邮箱发验证码的时刻，用于重发倒计时；没发过或验证码已作废时为 nil。
    private(set) var identityCodeSentAt: Date?

    /// 是否已经给当前邮箱发过验证码（还没作废）。
    private(set) var isIdentityCodeSent = false

    /// 是否正在请求，界面据此禁用按钮、显示转圈，弹层也不能关闭。
    private(set) var isWorking = false

    /// 要显示的提示文案键（错误或说明）；没有时为 nil。
    private(set) var messageKey: String?

    /// 最近一次操作成功的轻提示；还没有过时为 nil。出错时不清空，界面只在它换成新的一条时弹出。
    private(set) var notice: Notice?

    /// 已通过的验证：`recordID` 是 hub 签发的注销票据。
    private(set) var verification: AccountIdentityVerification?

    /// step-up 时在托管页里登录了另一个账号，已退出登录，流程结束。
    private(set) var isAccountSwitched = false

    /// 是否正在读账号信息，避免重复读取。
    private var isPreparing = false

    /// 读取账号信息（只用 `fetchAccount` 选验证方式）。
    private let account: any AccountSecurityServing

    /// 调 yado_hub 发验证码、换票据。
    private let hub: any AccountDeletionVerifying

    /// 发起重新登录（`max_age=0` 的托管页），通常是 `AuthStore.reauthenticate(requiringStepUp: false, requiringFreshLogin: true)`。
    private let reauthenticate: () async -> AccountReauthenticationResult

    /// 取当前登录的 ID token，通常是 `AuthStore.currentIDToken`。
    private let currentIDToken: () -> String?

    /// 当前时间，测试时可注入。
    private let now: () -> Date

    /// - Parameters:
    ///   - account: 读账号信息的 Account API。
    ///   - hub: 发验证码、换票据的 hub 接口。
    ///   - reauthenticate: 发起重新登录的动作。
    ///   - currentIDToken: 取当前 ID token 的动作。
    ///   - now: 当前时间。
    init(
        account: any AccountSecurityServing,
        hub: any AccountDeletionVerifying,
        reauthenticate: @escaping () async -> AccountReauthenticationResult,
        currentIDToken: @escaping () -> String?,
        now: @escaping () -> Date = { Date() }
    ) {
        self.account = account
        self.hub = hub
        self.reauthenticate = reauthenticate
        self.currentIDToken = currentIDToken
        self.now = now
    }

    // MARK: - 状态

    /// 当前邮箱的验证码是否已填满 `AccountCredentialChangeFlow.codeLength` 位，没填满时不能提交。
    var isIdentityCodeComplete: Bool {
        AccountCredentialChangeFlow.sanitizedCode(identityCode).count == AccountCredentialChangeFlow.codeLength
    }

    /// 当前是不是用邮箱验证码验证。
    private var usesEmailCode: Bool {
        if case .currentEmailCode? = method { return true }
        return false
    }

    /// 注销时用哪种方式验证身份：按 `select(for:)` 选，选出 `.unavailable` 时改用 step-up。
    ///
    /// - Parameter info: 最新的账号信息。
    static func method(for info: AccountSecurityInfo) -> AccountIdentityVerificationMethod {
        let selected = AccountIdentityVerificationMethod.select(for: info)
        return selected == .unavailable ? .stepUp : selected
    }

    // MARK: - 准备

    /// 读取账号信息并选出验证方式；读取失败时 `method` 仍为 nil，`messageKey` 说明原因，界面可以再调一次。
    func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        messageKey = nil
        defer { isPreparing = false }
        do {
            let info = try await account.fetchAccount()
            method = Self.method(for: info)
        } catch {
            messageKey = Self.loadFailureKey(error)
        }
    }

    // MARK: - 验证身份

    /// 用密码验证身份，通过后保存注销票据。
    func submitPassword() async {
        guard method == .password, !password.isEmpty else { return }
        let password = password
        await run {
            try await verified(.password(password))
        }
    }

    /// 给当前邮箱发验证码（由 hub 发到 Logto 里的主邮箱）；冷却中不发。
    func sendIdentityCode() async {
        guard usesEmailCode,
              EmailCodeCooldown.remainingSeconds(sentAt: identityCodeSentAt, now: now()) == 0
        else { return }
        await run {
            try await hub.sendEmailCode()
            identityCodeSentAt = now()
            isIdentityCodeSent = true
            identityCode = ""
            notice = Notice(kind: .codeSent)
        }
    }

    /// 校验当前邮箱收到的验证码，通过后保存注销票据；不足位数时不提交。
    func submitIdentityCode() async {
        let code = AccountCredentialChangeFlow.sanitizedCode(identityCode)
        guard usesEmailCode,
              isIdentityCodeSent,
              code.count == AccountCredentialChangeFlow.codeLength
        else { return }
        await run {
            try await verified(.emailCode(code))
        }
    }

    /// 重新登录验证：打开 Logto 托管页（`max_age=0`），回来后把新的 ID token 交给 hub 换票据。
    ///
    /// 用户关掉托管页时什么都不做；登了另一个账号时已退出登录，`isAccountSwitched` 变为 true。
    func startStepUp() async {
        guard method == .stepUp, !isWorking else { return }
        isWorking = true
        messageKey = nil
        defer { isWorking = false }

        switch await reauthenticate() {
        case .cancelled:
            return
        case .switchedAccount:
            isAccountSwitched = true
            return
        case .failed:
            messageKey = "account.email.step_up.failed"
            return
        case .succeeded:
            break
        }

        guard let idToken = currentIDToken() else {
            messageKey = AccountDeletionVerificationError.loginNotRecent.localizationKey
            return
        }
        do {
            try await verified(.idToken(idToken))
        } catch {
            handle(error)
        }
    }

    /// 仍有效的注销票据；已过期或没有时返回 nil。
    ///
    /// 验证过但已过期时顺带 `invalidate()`，界面回到验证这一步并提示「身份验证已过期，请重新验证」。
    func validTicket() -> String? {
        guard let verification else { return nil }
        if verification.isValid(at: now()) {
            return verification.recordID
        }
        invalidate()
        return nil
    }

    /// 票据作废（hub 说票据无效或已过期，或本地已过期）：清掉票据、密码和验证码，回到验证这一步。
    ///
    /// 验证方式不变，不用重新读账号信息；提示「身份验证已过期，请重新验证」。
    func invalidate() {
        verification = nil
        password = ""
        resetIdentityCode()
        messageKey = "account.email.error.verification_required"
    }

    // MARK: - 私有方法

    /// 向 hub 提交身份凭据，通过后保存票据、清空输入并提示已验证。
    ///
    /// 有效期从请求发出的时刻起算，比 hub 签发票据的时刻早，所以本地一定先于 hub 过期。
    ///
    /// - Parameter proof: 身份凭据。
    private func verified(_ proof: AccountDeletionProof) async throws {
        let requestedAt = now()
        let ticket = try await hub.verify(proof)
        verification = AccountIdentityVerification(recordID: ticket, verifiedAt: requestedAt)
        password = ""
        resetIdentityCode()
        notice = Notice(kind: .identityVerified)
    }

    /// 执行一次请求：期间标记为忙，失败时按错误类型处理。
    private func run(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        messageKey = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            handle(error)
        }
    }

    /// 按错误类型更新状态和提示。
    ///
    /// 验证码不对时清空输入、可以接着输；验证码失效时作废已发的码，可以立即重新获取。
    private func handle(_ error: Error) {
        let error = (error as? AccountDeletionVerificationError) ?? .serviceUnavailable
        switch error {
        case .codeMismatch:
            identityCode = ""
        case .codeInvalid:
            resetIdentityCode()
        default:
            break
        }
        messageKey = error.localizationKey
    }

    /// 作废当前邮箱的验证码。
    private func resetIdentityCode() {
        isIdentityCodeSent = false
        identityCodeSentAt = nil
        identityCode = ""
    }

    /// 读取账号信息失败时的提示文案键。
    private static func loadFailureKey(_ error: Error) -> String {
        switch error as? AccountProfileError {
        case .network?: "profile.edit.error.network"
        case .reauthenticationRequired?: "account.delete.failed.session"
        default: "account.email.identity.unavailable"
        }
    }
}
