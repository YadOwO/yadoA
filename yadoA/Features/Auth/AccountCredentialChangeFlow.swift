import Foundation
import Observation

/// 修改登录方式（绑定 / 更换邮箱、设置 / 修改密码、关联 Apple）的流程状态：先验证身份，再输入新邮箱、新密码，
/// 或打开 Apple 授权页，保存。
///
/// 身份验证方式由 `AccountIdentityVerificationMethod.select(for:)` 选出：当前邮箱验证码 → 密码 → step-up。
/// 例外：没有任何验证方式（只有 Apple 等第三方登录）的账号设置密码、关联第三方账号时，Logto 不要求验证身份，直接进入下一步。
/// 通过后得到的身份验证记录只存在内存里，10 分钟后过期（`AccountIdentityVerification`）：密码从验证通过时算，
/// 当前邮箱验证码按发码接口返回的 `expiresAt` 算（记录在发码时就已创建）；
/// 过期或保存时 Logto 返回 `verification_record.permission_denied`，都回到验证身份这一步。
/// 由「账号与安全」页创建，每次打开弹层新建一个。
@MainActor
@Observable
final class AccountCredentialChangeFlow: Identifiable {
    /// 要修改的登录凭证。
    enum Target: Equatable {
        /// 绑定或更换邮箱。
        case email
        /// 设置或修改密码。
        case password
        /// 关联 Apple（只在还没关联时打开）。
        case apple
    }

    /// 流程所处的步骤。
    enum Step: Equatable {
        /// 验证身份，附带验证方式。
        case identity(AccountIdentityVerificationMethod)

        /// 输入新邮箱、收验证码并保存。
        case newEmail

        /// 输入并确认新密码，保存。
        case newPassword

        /// 打开 Apple 授权页完成关联。
        case linkApple

        /// 已保存。改邮箱时附带新邮箱地址（step-up 时在 Logto 托管页里设置、读不到地址时为 nil）；改密码、关联 Apple 时为 nil。
        case finished(String?)

        /// step-up 时在托管页里登录了另一个账号，已退出登录，流程结束。
        case accountSwitched
    }

    /// 新邮箱校验通过的验证记录；保存失败（如身份验证过期）后重试时直接复用，不用再输一次验证码。
    private struct VerifiedEmail: Equatable {
        /// 校验时的邮箱地址。
        let email: String
        /// 校验通过的记录 ID。
        let recordID: String
    }

    /// 要修改的登录凭证。
    let target: Target

    /// 本次是更换 / 修改（原来已绑定邮箱、已设置密码），还是第一次绑定 / 设置。
    let isChanging: Bool

    /// 最新的账号信息；step-up 回来后会刷新。
    private(set) var account: AccountSecurityInfo

    /// 当前步骤。
    private(set) var step: Step

    /// 验证身份时输入的密码；验证通过后立即清空。
    var password = ""

    /// 发到当前邮箱的验证码输入。
    var identityCode = ""

    /// 上次给当前邮箱发验证码的时刻，用于重发倒计时；没发过时为 nil。
    private(set) var identityCodeSentAt: Date?

    /// 新邮箱输入。
    var newEmail = ""

    /// 发到新邮箱的验证码输入。
    var newEmailCode = ""

    /// 新密码输入；保存成功后清空。
    var newPassword = ""

    /// 再次输入的新密码，必须和 `newPassword` 一致；保存成功后清空。
    var confirmPassword = ""

    /// 新邮箱的验证码发到了哪个地址；没发过、或之后改了输入时为 nil。
    private(set) var codeSentEmail: String?

    /// 上次给新邮箱发验证码的时刻，用于重发倒计时；没发过时为 nil。
    private(set) var newEmailCodeSentAt: Date?

    /// 是否正在请求，界面据此禁用按钮、显示转圈。
    private(set) var isWorking = false

    /// 要显示的提示文案键（错误或说明）；没有时为 nil。
    private(set) var messageKey: String?

    /// 当前邮箱验证码的记录（ID 和失效时刻）。
    private var identityCodeRecord: EmailVerificationCodeRecord?

    /// 给当前邮箱发码的请求发出时刻；发码接口没返回 `expiresAt` 时，身份验证从这里起算 10 分钟。
    private var identityCodeRequestedAt: Date?

    /// 已通过的身份验证。
    private var identityVerification: AccountIdentityVerification?

    /// 新邮箱验证码的记录 ID。
    private var newEmailCodeRecordID: String?

    /// 新邮箱已校验通过的记录。
    private var verifiedNewEmail: VerifiedEmail?

    /// 调用 Logto Account API。
    private let service: any AccountSecurityServing

    /// 发起 step-up（重新走一遍 Logto 托管页），通常是 `AuthStore.reauthenticate(requiringStepUp: true)`。
    private let reauthenticate: () async -> AccountReauthenticationResult

    /// 当前时间，测试时可注入。
    private let now: () -> Date

    /// Logto 里 Apple 连接器的 ID；nil 时不能关联 Apple。
    private let appleConnectorID: String?

    /// Logto 服务地址，用来拼关联 Apple 的回程地址。
    private let logtoEndpoint: String

    /// - Parameters:
    ///   - target: 要修改邮箱还是密码。
    ///   - account: 打开弹层时的账号信息。
    ///   - service: Account API。
    ///   - reauthenticate: 发起 step-up 的动作。
    ///   - now: 当前时间。
    ///   - appleConnectorID: Logto 里 Apple 连接器的 ID，默认取当前环境的 `AuthConfig.appleSocialConnectorID`。
    ///   - logtoEndpoint: Logto 服务地址，默认取当前环境的 `AuthConfig.endpoint`。
    init(
        target: Target,
        account: AccountSecurityInfo,
        service: any AccountSecurityServing,
        reauthenticate: @escaping () async -> AccountReauthenticationResult,
        now: @escaping () -> Date = { Date() },
        appleConnectorID: String? = AuthConfig.appleSocialConnectorID,
        logtoEndpoint: String = AuthConfig.endpoint
    ) {
        self.target = target
        self.account = account
        self.service = service
        self.reauthenticate = reauthenticate
        self.now = now
        self.appleConnectorID = appleConnectorID
        self.logtoEndpoint = logtoEndpoint
        switch target {
        case .email: isChanging = account.isEmailBound == true
        case .password: isChanging = account.hasPassword == true
        case .apple: isChanging = false
        }
        step = Self.entryStep(target: target, account: account)
    }

    // MARK: - 状态

    /// 去掉首尾空白后的新邮箱。
    var normalizedNewEmail: String {
        AccountEmail.normalized(newEmail)
    }

    /// 是否已经给当前输入的新邮箱发过验证码。
    var isNewEmailCodeSent: Bool {
        codeSentEmail != nil && codeSentEmail == normalizedNewEmail
    }

    /// 是否已经给当前邮箱发过验证码。
    var isIdentityCodeSent: Bool {
        identityCodeRecord != nil
    }

    /// 当前邮箱的验证码是否已填满 `codeLength` 位，没填满时不能提交。
    var isIdentityCodeComplete: Bool {
        Self.sanitizedCode(identityCode).count == Self.codeLength
    }

    /// 新邮箱的验证码是否已填满 `codeLength` 位，没填满时不能提交。
    var isNewEmailCodeComplete: Bool {
        Self.sanitizedCode(newEmailCode).count == Self.codeLength
    }

    /// 两次输入的新密码都填了且一致，可以保存。
    var isNewPasswordReady: Bool {
        !newPassword.isEmpty && newPassword == confirmPassword
    }

    /// 已经输入了确认密码，但和新密码不一致；界面据此在输入框下方提示。
    var isConfirmPasswordMismatched: Bool {
        !confirmPassword.isEmpty && newPassword != confirmPassword
    }

    // MARK: - 验证码输入

    /// Logto 邮箱验证码的位数：固定为 6 位数字。
    static let codeLength = 6

    /// 整理验证码输入：只留半角数字，最多 `codeLength` 位。
    ///
    /// 输入框每次变化都用它过滤，粘贴「123 456」或带说明文字的整段内容时只取前 6 位数字；提交前也再过一遍。
    /// - Parameter input: 输入框里的原始文本。
    /// - Returns: 不超过 `codeLength` 位的数字串。
    static func sanitizedCode(_ input: String) -> String {
        String(input.filter { $0.isASCII && $0.isNumber }.prefix(codeLength))
    }

    // MARK: - 验证身份

    /// 用密码验证身份，通过后进入下一步。
    func submitPassword() async {
        guard step == .identity(.password), !password.isEmpty else { return }
        let password = password
        await run {
            let recordID = try await service.verifyPassword(password)
            identityVerified(AccountIdentityVerification(recordID: recordID, verifiedAt: now()))
        }
    }

    /// 给当前邮箱发验证码（模板 `UserPermissionValidation`）；冷却中不发。
    func sendIdentityCode() async {
        guard case let .identity(.currentEmailCode(email)) = step,
              EmailCodeCooldown.remainingSeconds(sentAt: identityCodeSentAt, now: now()) == 0
        else { return }
        let requestedAt = now()
        await run {
            identityCodeRecord = try await service.sendEmailCode(to: email, purpose: .identityVerification)
            identityCodeRequestedAt = requestedAt
            identityCodeSentAt = now()
            identityCode = ""
        }
    }

    /// 校验当前邮箱收到的验证码，通过后进入下一步；身份验证的有效期按发码时的记录算。
    func submitIdentityCode() async {
        let code = Self.normalizedCode(identityCode)
        guard case let .identity(.currentEmailCode(email)) = step,
              let codeRecord = identityCodeRecord,
              let requestedAt = identityCodeRequestedAt,
              !code.isEmpty
        else { return }
        await run {
            let verifiedID = try await service.verifyEmailCode(code, email: email, verificationID: codeRecord.recordID)
            identityVerified(.emailCode(recordID: verifiedID, code: codeRecord, requestedAt: requestedAt))
        }
    }

    /// 只有 Apple 的账号：重新走一遍 Logto 托管页做 step-up，回来后刷新账号信息。
    ///
    /// 改邮箱时用到（改密码时只有 Apple 的账号不用验证身份，不会走到这里）：托管页里设置了邮箱时直接完成；
    /// 设置了密码时转为用密码验证身份；登了另一个账号时流程结束。
    func startStepUp() async {
        guard step == .identity(.stepUp), !isWorking else { return }
        isWorking = true
        messageKey = nil
        defer { isWorking = false }

        switch await reauthenticate() {
        case .cancelled:
            return
        case .switchedAccount:
            step = .accountSwitched
            return
        case .failed:
            messageKey = "account.email.step_up.failed"
            return
        case .succeeded:
            break
        }

        do {
            let refreshed = try await service.fetchAccount()
            account = refreshed
            if target == .email, refreshed.isEmailBound == true {
                step = .finished(refreshed.trimmedPrimaryEmail)
                return
            }
            step = Self.entryStep(target: target, account: refreshed)
            if step == .identity(.stepUp) {
                messageKey = "account.email.step_up.incomplete"
            }
        } catch {
            messageKey = Self.accountError(error).localizationKey
        }
    }

    // MARK: - 新邮箱

    /// 新邮箱输入变化：和已发验证码的地址不一样时，作废之前的验证码，可以立即给新地址发。
    func newEmailDidChange() {
        guard let codeSentEmail, codeSentEmail != normalizedNewEmail else { return }
        resetNewEmailCode()
        messageKey = nil
    }

    /// 给新邮箱发验证码；地址不合法、和当前邮箱相同、身份验证已过期或冷却中时不发。
    func sendNewEmailCode() async {
        guard step == .newEmail else { return }
        let email = normalizedNewEmail
        guard validateNewEmail(email), validIdentityVerification() != nil else { return }
        if codeSentEmail == email,
           EmailCodeCooldown.remainingSeconds(sentAt: newEmailCodeSentAt, now: now()) > 0 {
            return
        }
        await run {
            newEmailCodeRecordID = try await service.sendEmailCode(to: email, purpose: .newEmail).recordID
            codeSentEmail = email
            newEmailCodeSentAt = now()
            newEmailCode = ""
            verifiedNewEmail = nil
        }
    }

    /// 校验新邮箱的验证码并保存为主邮箱。
    func saveNewEmail() async {
        guard step == .newEmail, let identity = validIdentityVerification() else { return }
        let email = normalizedNewEmail
        let code = Self.normalizedCode(newEmailCode)
        let reusable = verifiedNewEmail?.email == email ? verifiedNewEmail : nil
        guard codeSentEmail == email,
              let codeRecordID = newEmailCodeRecordID,
              reusable != nil || !code.isEmpty
        else { return }

        await run {
            let newEmailVerificationID: String
            if let reusable {
                newEmailVerificationID = reusable.recordID
            } else {
                newEmailVerificationID = try await service.verifyEmailCode(code, email: email, verificationID: codeRecordID)
                verifiedNewEmail = VerifiedEmail(email: email, recordID: newEmailVerificationID)
            }
            try await service.setPrimaryEmail(
                email,
                newEmailVerificationID: newEmailVerificationID,
                identityVerificationID: identity.recordID
            )
            step = .finished(email)
        }
    }

    // MARK: - 新密码

    /// 保存新密码：两次输入一致才提交；需要验证身份时带上仍有效的身份验证记录。
    ///
    /// 密码规则（长度、复杂度）只由 Logto 判断，不符合时提示 `password.rejected` 对应的文案，输入保留可以接着改。
    func saveNewPassword() async {
        guard step == .newPassword, !newPassword.isEmpty else { return }
        guard newPassword == confirmPassword else {
            messageKey = "account.password.error.mismatch"
            return
        }
        let identityRecordID: String?
        if requiresIdentityVerification {
            guard let identity = validIdentityVerification() else { return }
            identityRecordID = identity.recordID
        } else {
            identityRecordID = nil
        }
        let password = newPassword
        await run {
            try await service.setPassword(password, identityVerificationID: identityRecordID)
            newPassword = ""
            confirmPassword = ""
            step = .finished(nil)
        }
    }

    // MARK: - 关联 Apple

    /// 关联 Apple：创建 Logto 的社交验证记录，在浏览器里打开 Apple 授权页，回程交给 Logto 校验后关联到当前账号。
    ///
    /// 用户在浏览器或 Apple 页面上取消时不提示；回程的 `state` 对不上、授权失败时提示「没有完成关联」。
    /// 这个 Apple 账号已关联其他芽豆账号时提示换一个；身份验证过期时回到验证身份这一步。
    ///
    /// - Parameter authorize: 在浏览器里打开授权页并等回程，返回跳回 App 的地址；用户关掉浏览器时返回 nil。
    ///   界面用 `WebAuthenticationSession` 实现，测试时替换。
    func linkApple(authorize: @MainActor (URL) async throws -> URL?) async {
        guard step == .linkApple, let connectorID = appleConnectorID else { return }
        let identityRecordID: String?
        if requiresIdentityVerification {
            guard let identity = validIdentityVerification() else { return }
            identityRecordID = identity.recordID
        } else {
            identityRecordID = nil
        }
        let state = SocialLink.makeState()
        let redirectURI = SocialLink.redirectURI(endpoint: logtoEndpoint, connectorID: connectorID)
        await run {
            let start = try await service.startSocialVerification(
                connectorID: connectorID,
                state: state,
                redirectURI: redirectURI
            )
            guard let callbackURL = try await authorize(start.authorizationURL) else { return }
            switch SocialLink.parseCallback(callbackURL, expectedState: state) {
            case .cancelled:
                return
            case .invalid:
                messageKey = "account.apple.error.failed"
            case var .authorized(connectorData):
                // 与 Logto 自带账户中心的做法一致：回程参数原样带上，再加上回程地址
                connectorData["redirectUri"] = redirectURI
                let verifiedID = try await service.verifySocial(recordID: start.recordID, connectorData: connectorData)
                try await service.linkSocialIdentity(verificationRecordID: verifiedID, identityVerificationID: identityRecordID)
                step = .finished(nil)
            }
        }
    }

    // MARK: - 私有方法

    /// 保存前是否要先验证身份：改邮箱总要；改密码、关联 Apple 时只有账号有验证方式（密码、邮箱或手机号）才要，与 Logto 一致。
    private var requiresIdentityVerification: Bool {
        target == .email || account.hasSecurityVerificationMethod
    }

    /// 打开弹层（或 step-up 回来）时的第一步：不用验证身份时直接进入下一步，否则按账号情况选验证方式。
    ///
    /// - Parameters:
    ///   - target: 要修改的登录方式。
    ///   - account: 最新的账号信息。
    private static func entryStep(target: Target, account: AccountSecurityInfo) -> Step {
        if target != .email, !account.hasSecurityVerificationMethod {
            return nextStep(after: target)
        }
        return .identity(AccountIdentityVerificationMethod.select(for: account))
    }

    /// 验证完身份之后的那一步。
    ///
    /// - Parameter target: 要修改的登录方式。
    private static func nextStep(after target: Target) -> Step {
        switch target {
        case .email: .newEmail
        case .password: .newPassword
        case .apple: .linkApple
        }
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
            handle(Self.accountError(error))
        }
    }

    /// 按错误类型更新状态和提示。
    private func handle(_ error: AccountProfileError) {
        if step == .linkApple {
            switch error {
            case .verificationRequired:
                returnToIdentityVerification()
            case .socialIdentityInUse, .network, .notAllowed, .reauthenticationRequired:
                messageKey = error.localizationKey
            default:
                // 校验回程失败（如 id_token 不对、验证记录过期）等，统一提示没有完成关联，可以再试一次
                messageKey = "account.apple.error.failed"
            }
            return
        }
        switch error {
        case .verificationRequired:
            returnToIdentityVerification()
        case .codeInvalid, .codeExpired, .codeTooManyAttempts, .newEmailVerificationInvalid:
            // 这个验证码记录不能再用了，作废后可以立即重新获取
            if step == .newEmail {
                resetNewEmailCode()
            } else {
                resetIdentityCode()
            }
            messageKey = error.localizationKey
        default:
            messageKey = error.localizationKey
        }
    }

    /// 身份验证通过：记下验证记录和失效时刻，进入下一步（输入新邮箱、新密码，或关联 Apple）。
    private func identityVerified(_ verification: AccountIdentityVerification) {
        identityVerification = verification
        password = ""
        resetIdentityCode()
        step = Self.nextStep(after: target)
    }

    /// 返回仍有效的身份验证；已过期或没有时回到验证身份这一步并返回 nil。
    private func validIdentityVerification() -> AccountIdentityVerification? {
        if let identityVerification, identityVerification.isValid(at: now()) {
            return identityVerification
        }
        returnToIdentityVerification()
        return nil
    }

    /// 回到验证身份这一步；已输入的新邮箱、新密码和已校验的新邮箱记录保留，验证完身份后可以直接保存。
    private func returnToIdentityVerification() {
        identityVerification = nil
        password = ""
        resetIdentityCode()
        step = .identity(AccountIdentityVerificationMethod.select(for: account))
        messageKey = "account.email.error.verification_required"
    }

    /// 本地检查新邮箱，不通过时设置提示。
    private func validateNewEmail(_ email: String) -> Bool {
        guard AccountEmail.isValid(email) else {
            messageKey = "account.email.error.invalid_format"
            return false
        }
        if let current = account.trimmedPrimaryEmail, AccountEmail.isSame(current, email) {
            messageKey = "account.email.error.same_as_current"
            return false
        }
        return true
    }

    /// 作废当前邮箱的验证码。
    private func resetIdentityCode() {
        identityCodeRecord = nil
        identityCodeRequestedAt = nil
        identityCodeSentAt = nil
        identityCode = ""
    }

    /// 作废新邮箱的验证码和已校验的记录。
    private func resetNewEmailCode() {
        newEmailCodeRecordID = nil
        codeSentEmail = nil
        newEmailCodeSentAt = nil
        newEmailCode = ""
        verifiedNewEmail = nil
    }

    /// 提交前整理验证码；不足 `codeLength` 位时返回空串，调用方据此不提交。
    private static func normalizedCode(_ code: String) -> String {
        let sanitized = sanitizedCode(code)
        return sanitized.count == codeLength ? sanitized : ""
    }

    /// 把错误统一成 `AccountProfileError`。
    private static func accountError(_ error: Error) -> AccountProfileError {
        (error as? AccountProfileError) ?? .unknown(nil)
    }
}
