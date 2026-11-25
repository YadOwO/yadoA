import Foundation
import Testing
@testable import yadoA

/// 注销前验证身份流程的状态流转：选验证方式、密码 / 邮箱验证码 / 重新登录三种验证、票据有效期、作废后回到验证这一步；
/// 用假的 Account API 和假的 hub，不发网络请求。
@Suite("注销前验证身份流程")
@MainActor
struct AccountDeletionVerificationFlowTests {
    /// 绑定了邮箱的账号。
    private static let emailAccount = AccountSecurityInfo(
        userID: "user-1",
        primaryEmail: "yado@example.com",
        hasPrimaryEmail: true,
        hasPassword: true,
        hasSecurityVerificationMethod: true
    )

    /// 有密码、没有邮箱的账号。
    private static let passwordAccount = AccountSecurityInfo(
        userID: "user-1",
        hasPrimaryEmail: false,
        hasPassword: true,
        hasSecurityVerificationMethod: true
    )

    /// 只用 Apple 登录的账号。
    private static let appleOnlyAccount = AccountSecurityInfo(
        userID: "user-1",
        hasPrimaryEmail: false,
        hasPassword: false,
        hasSecurityVerificationMethod: false,
        socialTargets: ["apple"]
    )

    /// 有验证方式但 App 用不上（如只有手机号）的账号：`select(for:)` 会返回 `.unavailable`。
    private static let phoneOnlyAccount = AccountSecurityInfo(
        userID: "user-1",
        hasPrimaryEmail: false,
        hasPassword: false,
        hasSecurityVerificationMethod: true
    )

    /// 一次测试用到的流程和它的假依赖。
    private struct Setup {
        let flow: AccountDeletionVerificationFlow
        let account: FakeDeletionAccountService
        let hub: FakeAccountDeletionHub
        let clock: DeletionTestClock
    }

    // MARK: - 选验证方式

    @Test("注销时的验证方式：select 返回 unavailable 改用 step-up，其余照 select 的顺序")
    func methodMapsUnavailableToStepUp() {
        #expect(AccountDeletionVerificationFlow.method(for: Self.emailAccount) == .currentEmailCode("yado@example.com"))
        #expect(AccountDeletionVerificationFlow.method(for: Self.passwordAccount) == .password)
        #expect(AccountDeletionVerificationFlow.method(for: Self.appleOnlyAccount) == .stepUp)
        #expect(AccountIdentityVerificationMethod.select(for: Self.phoneOnlyAccount) == .unavailable)
        #expect(AccountDeletionVerificationFlow.method(for: Self.phoneOnlyAccount) == .stepUp)
    }

    @Test("准备：读账号信息后选出验证方式；读取失败时没有方式、有提示，再读一次可以恢复")
    func prepareSelectsMethodAndRecoversFromFailure() async {
        let setup = makeSetup(account: Self.passwordAccount)
        #expect(setup.flow.method == nil)
        setup.account.fetchErrors = [.network]

        await setup.flow.prepare()
        #expect(setup.flow.method == nil)
        #expect(setup.flow.messageKey == "profile.edit.error.network")

        await setup.flow.prepare()
        #expect(setup.flow.method == .password)
        #expect(setup.flow.messageKey == nil)
        #expect(setup.account.fetchCount == 2)
    }

    @Test("准备：登录已失效时提示重新登录；其他读取错误提示暂时无法验证")
    func prepareFailureMessages() async {
        let setup = makeSetup(account: Self.passwordAccount)

        setup.account.fetchErrors = [.reauthenticationRequired]
        await setup.flow.prepare()
        #expect(setup.flow.messageKey == "account.delete.failed.session")

        setup.account.fetchErrors = [.unknown("boom")]
        await setup.flow.prepare()
        #expect(setup.flow.messageKey == "account.email.identity.unavailable")
    }

    // MARK: - 密码

    @Test("密码验证通过：拿到票据，密码清空，弹出已验证提示")
    func passwordVerificationStoresTicket() async {
        let setup = makeSetup(account: Self.passwordAccount)
        await setup.flow.prepare()
        #expect(setup.flow.validTicket() == nil)

        setup.flow.password = "secret"
        await setup.flow.submitPassword()

        #expect(setup.hub.calls == [.verify(.password("secret"))])
        #expect(setup.flow.validTicket() == "ticket-1")
        #expect(setup.flow.verification?.recordID == "ticket-1")
        #expect(setup.flow.password.isEmpty)
        #expect(setup.flow.notice?.kind == .identityVerified)
        #expect(setup.flow.messageKey == nil)
        #expect(!setup.flow.isWorking)
    }

    @Test("密码为空或还没读到验证方式时不提交")
    func passwordSubmitNeedsInput() async {
        let setup = makeSetup(account: Self.passwordAccount)
        setup.flow.password = "secret"
        await setup.flow.submitPassword()
        #expect(setup.hub.calls.isEmpty)

        await setup.flow.prepare()
        setup.flow.password = ""
        await setup.flow.submitPassword()
        #expect(setup.hub.calls.isEmpty)
    }

    @Test("密码不对：提示原因，输入保留，没有票据")
    func wrongPasswordKeepsInput() async {
        let setup = makeSetup(account: Self.passwordAccount)
        await setup.flow.prepare()
        setup.hub.verifyErrors = [.wrongPassword]

        setup.flow.password = "oops"
        await setup.flow.submitPassword()

        #expect(setup.flow.messageKey == "profile.edit.error.wrong_password")
        #expect(setup.flow.password == "oops")
        #expect(setup.flow.verification == nil)
        #expect(setup.flow.notice == nil)
    }

    // MARK: - 票据有效期

    @Test("票据 10 分钟有效：期间可用，到期后（含本地提前量）返回 nil，并回到验证这一步提示已过期")
    func ticketExpires() async {
        let setup = makeSetup(account: Self.passwordAccount)
        await setup.flow.prepare()
        setup.flow.password = "secret"
        await setup.flow.submitPassword()

        setup.clock.advance(by: 5 * 60)
        #expect(setup.flow.validTicket() == "ticket-1")

        setup.clock.advance(by: 5 * 60)
        #expect(setup.flow.validTicket() == nil)
        #expect(setup.flow.verification == nil)
        #expect(setup.flow.messageKey == "account.email.error.verification_required")
        #expect(setup.flow.method == .password)
    }

    @Test("从发请求的时刻起算有效期：验证请求耗时不会让本地比 hub 晚过期")
    func ticketLifetimeStartsAtRequest() async {
        let setup = makeSetup(account: Self.passwordAccount)
        await setup.flow.prepare()
        setup.hub.onVerify = { setup.clock.advance(by: 20) }
        setup.flow.password = "secret"
        await setup.flow.submitPassword()

        #expect(setup.flow.verification == AccountIdentityVerification(
            recordID: "ticket-1",
            verifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
    }

    @Test("没验证过时 validTicket 返回 nil，也不提示过期")
    func noTicketBeforeVerification() async {
        let setup = makeSetup(account: Self.passwordAccount)
        await setup.flow.prepare()

        #expect(setup.flow.validTicket() == nil)
        #expect(setup.flow.messageKey == nil)
    }

    @Test("invalidate：清掉票据、密码和验证码，验证方式不变，提示身份验证已过期")
    func invalidateKeepsMethod() async {
        let setup = makeSetup(account: Self.passwordAccount)
        await setup.flow.prepare()
        setup.flow.password = "secret"
        await setup.flow.submitPassword()
        #expect(setup.flow.verification != nil)

        setup.flow.password = "again"
        setup.flow.invalidate()

        #expect(setup.flow.verification == nil)
        #expect(setup.flow.password.isEmpty)
        #expect(setup.flow.identityCode.isEmpty)
        #expect(setup.flow.method == .password)
        #expect(setup.flow.messageKey == "account.email.error.verification_required")
        #expect(setup.flow.validTicket() == nil)
        // 方式不变，不用重新读账号信息
        #expect(setup.account.fetchCount == 1)
    }

    // MARK: - 邮箱验证码

    @Test("邮箱验证码：发码后输入 6 位提交，通过后拿到票据；输入里的空格和非数字会被去掉")
    func emailCodeVerification() async {
        let setup = makeSetup(account: Self.emailAccount)
        await setup.flow.prepare()
        #expect(setup.flow.method == .currentEmailCode("yado@example.com"))
        #expect(!setup.flow.isIdentityCodeSent)

        await setup.flow.sendIdentityCode()
        #expect(setup.flow.isIdentityCodeSent)
        #expect(setup.flow.identityCodeSentAt == setup.clock.now)
        #expect(setup.flow.notice?.kind == .codeSent)

        setup.flow.identityCode = "123 456"
        #expect(setup.flow.isIdentityCodeComplete)
        await setup.flow.submitIdentityCode()

        #expect(setup.hub.calls == [.sendEmailCode, .verify(.emailCode("123456"))])
        #expect(setup.flow.validTicket() == "ticket-1")
        #expect(setup.flow.identityCode.isEmpty)
        #expect(!setup.flow.isIdentityCodeSent)
        #expect(setup.flow.notice?.kind == .identityVerified)
    }

    @Test("邮箱验证码：没发过码或不足 6 位时不提交")
    func emailCodeSubmitNeedsCompleteCode() async {
        let setup = makeSetup(account: Self.emailAccount)
        await setup.flow.prepare()

        setup.flow.identityCode = "123456"
        await setup.flow.submitIdentityCode()
        #expect(setup.hub.calls.isEmpty)

        await setup.flow.sendIdentityCode()
        setup.flow.identityCode = "12345"
        #expect(!setup.flow.isIdentityCodeComplete)
        await setup.flow.submitIdentityCode()
        #expect(setup.hub.calls == [.sendEmailCode])
    }

    @Test("发码有 60 秒冷却：冷却期间不重复发，冷却结束后可以重发")
    func sendCodeCooldown() async {
        let setup = makeSetup(account: Self.emailAccount)
        await setup.flow.prepare()

        await setup.flow.sendIdentityCode()
        await setup.flow.sendIdentityCode()
        #expect(setup.hub.calls == [.sendEmailCode])

        setup.clock.advance(by: EmailCodeCooldown.duration - 1)
        await setup.flow.sendIdentityCode()
        #expect(setup.hub.calls == [.sendEmailCode])

        setup.clock.advance(by: 1)
        await setup.flow.sendIdentityCode()
        #expect(setup.hub.calls == [.sendEmailCode, .sendEmailCode])
    }

    @Test("发码失败：不记发码时刻，不算已发；没有主邮箱和限流各有提示")
    func sendCodeFailure() async {
        let setup = makeSetup(account: Self.emailAccount)
        await setup.flow.prepare()

        setup.hub.sendCodeErrors = [.emailUnavailable, .rateLimited]
        await setup.flow.sendIdentityCode()
        #expect(setup.flow.messageKey == "account.email.identity.unavailable")
        #expect(!setup.flow.isIdentityCodeSent)
        #expect(setup.flow.identityCodeSentAt == nil)
        #expect(setup.flow.notice == nil)

        await setup.flow.sendIdentityCode()
        #expect(setup.flow.messageKey == "account.delete.verify.error.rate_limited")
    }

    @Test("验证码不对：清空输入，已发的码还能用；验证码失效：作废已发的码，可以立即重发")
    func codeErrors() async {
        let setup = makeSetup(account: Self.emailAccount)
        await setup.flow.prepare()
        await setup.flow.sendIdentityCode()

        setup.hub.verifyErrors = [.codeMismatch]
        setup.flow.identityCode = "111111"
        await setup.flow.submitIdentityCode()
        #expect(setup.flow.identityCode.isEmpty)
        #expect(setup.flow.isIdentityCodeSent)
        #expect(setup.flow.messageKey == "account.email.error.code_mismatch")
        #expect(setup.flow.verification == nil)

        setup.hub.verifyErrors = [.codeInvalid]
        setup.flow.identityCode = "222222"
        await setup.flow.submitIdentityCode()
        #expect(setup.flow.identityCode.isEmpty)
        #expect(!setup.flow.isIdentityCodeSent)
        #expect(setup.flow.identityCodeSentAt == nil)
        #expect(setup.flow.messageKey == "account.email.error.code_invalid")

        // 冷却记录已作废，不用等 60 秒
        await setup.flow.sendIdentityCode()
        #expect(setup.hub.calls.filter { $0 == .sendEmailCode }.count == 2)
        #expect(setup.flow.isIdentityCodeSent)
    }

    @Test("其他错误只设提示：登录失效、要升级、网络不可用")
    func otherErrorsOnlySetMessage() async {
        let setup = makeSetup(account: Self.passwordAccount)
        await setup.flow.prepare()
        setup.flow.password = "secret"

        let cases: [(AccountDeletionVerificationError, String)] = [
            (.sessionExpired, "account.delete.failed.session"),
            (.upgradeRequired, "account.delete.failed.upgrade"),
            (.network, "profile.edit.error.network"),
            (.serviceUnavailable, "account.email.identity.unavailable"),
        ]
        for (error, key) in cases {
            setup.hub.verifyErrors = [error]
            await setup.flow.submitPassword()
            #expect(setup.flow.messageKey == key)
            #expect(setup.flow.password == "secret")
            #expect(setup.flow.verification == nil)
        }
    }

    // MARK: - step-up

    @Test("step-up：用户关掉托管页什么都不做")
    func stepUpCancelled() async {
        let setup = makeSetup(account: Self.appleOnlyAccount, reauthenticate: .cancelled, idToken: "a.b.c")
        await setup.flow.prepare()
        #expect(setup.flow.method == .stepUp)

        await setup.flow.startStepUp()

        #expect(setup.hub.calls.isEmpty)
        #expect(setup.flow.messageKey == nil)
        #expect(!setup.flow.isAccountSwitched)
        #expect(setup.flow.verification == nil)
        #expect(!setup.flow.isWorking)
    }

    @Test("step-up：托管页里登了另一个账号，标记换了账号，不换票据")
    func stepUpSwitchedAccount() async {
        let setup = makeSetup(account: Self.appleOnlyAccount, reauthenticate: .switchedAccount, idToken: "a.b.c")
        await setup.flow.prepare()

        await setup.flow.startStepUp()

        #expect(setup.flow.isAccountSwitched)
        #expect(setup.hub.calls.isEmpty)
        #expect(setup.flow.verification == nil)
    }

    @Test("step-up：托管页失败提示没有完成验证")
    func stepUpFailed() async {
        let setup = makeSetup(account: Self.appleOnlyAccount, reauthenticate: .failed("boom"), idToken: "a.b.c")
        await setup.flow.prepare()

        await setup.flow.startStepUp()

        #expect(setup.flow.messageKey == "account.email.step_up.failed")
        #expect(setup.hub.calls.isEmpty)
    }

    @Test("step-up：重新登录成功但取不到 ID token，按没有完成重新登录提示")
    func stepUpSucceededWithoutIDToken() async {
        let setup = makeSetup(account: Self.appleOnlyAccount, reauthenticate: .succeeded, idToken: nil)
        await setup.flow.prepare()

        await setup.flow.startStepUp()

        #expect(setup.flow.messageKey == "account.delete.verify.error.login_not_recent")
        #expect(setup.hub.calls.isEmpty)
        #expect(setup.flow.verification == nil)
    }

    @Test("step-up：重新登录成功且有 ID token，交给 hub 换票据")
    func stepUpSucceededWithIDToken() async {
        let setup = makeSetup(account: Self.appleOnlyAccount, reauthenticate: .succeeded, idToken: "a.b.c")
        await setup.flow.prepare()

        await setup.flow.startStepUp()

        #expect(setup.hub.calls == [.verify(.idToken("a.b.c"))])
        #expect(setup.flow.validTicket() == "ticket-1")
        #expect(setup.flow.notice?.kind == .identityVerified)
        #expect(!setup.flow.isWorking)
    }

    @Test("step-up：hub 说登录时间不够新，提示重新登录没完成，可以再试")
    func stepUpLoginNotRecent() async {
        let setup = makeSetup(account: Self.appleOnlyAccount, reauthenticate: .succeeded, idToken: "a.b.c")
        await setup.flow.prepare()
        setup.hub.verifyErrors = [.loginNotRecent]

        await setup.flow.startStepUp()
        #expect(setup.flow.messageKey == "account.delete.verify.error.login_not_recent")
        #expect(setup.flow.verification == nil)

        await setup.flow.startStepUp()
        #expect(setup.flow.validTicket() == "ticket-1")
    }

    @Test("只有手机号等 App 用不上的验证方式时，注销也走 step-up")
    func unavailableMethodUsesStepUp() async {
        let setup = makeSetup(account: Self.phoneOnlyAccount, reauthenticate: .succeeded, idToken: "a.b.c")
        await setup.flow.prepare()
        #expect(setup.flow.method == .stepUp)

        await setup.flow.startStepUp()

        #expect(setup.hub.calls == [.verify(.idToken("a.b.c"))])
    }

    // MARK: - 工具

    /// 创建流程和它的假依赖。
    ///
    /// - Parameters:
    ///   - account: 账号信息。
    ///   - reauthenticate: step-up 的结果。
    ///   - idToken: 重新登录后取到的 ID token。
    private func makeSetup(
        account: AccountSecurityInfo,
        reauthenticate: AccountReauthenticationResult = .cancelled,
        idToken: String? = nil
    ) -> Setup {
        let accountService = FakeDeletionAccountService(account: account)
        let hub = FakeAccountDeletionHub()
        let clock = DeletionTestClock()
        let flow = AccountDeletionVerificationFlow(
            account: accountService,
            hub: hub,
            reauthenticate: { reauthenticate },
            currentIDToken: { idToken },
            now: { clock.now }
        )
        return Setup(flow: flow, account: accountService, hub: hub, clock: clock)
    }
}

/// 可手动拨动的时钟。
@MainActor
private final class DeletionTestClock {
    /// 当前时刻。
    private(set) var now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 往后拨。
    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

/// 假的 Account API：注销流程只用 `fetchAccount`，其余方法不应被调用。
@MainActor
private final class FakeDeletionAccountService: AccountSecurityServing {
    /// `fetchAccount` 返回的账号信息。
    var account: AccountSecurityInfo

    /// `fetchAccount` 依次抛出的错误，用完后成功。
    var fetchErrors: [AccountProfileError] = []

    /// `fetchAccount` 被调用的次数。
    private(set) var fetchCount = 0

    init(account: AccountSecurityInfo) {
        self.account = account
    }

    func fetchAccount() async throws -> AccountSecurityInfo {
        fetchCount += 1
        if !fetchErrors.isEmpty {
            throw fetchErrors.removeFirst()
        }
        return account
    }

    func verifyPassword(_ password: String) async throws -> String {
        throw AccountProfileError.unknown("unexpected verifyPassword")
    }

    func sendEmailCode(to email: String, purpose: EmailVerificationPurpose) async throws -> EmailVerificationCodeRecord {
        throw AccountProfileError.unknown("unexpected sendEmailCode")
    }

    func verifyEmailCode(_ code: String, email: String, verificationID: String) async throws -> String {
        throw AccountProfileError.unknown("unexpected verifyEmailCode")
    }

    func setPrimaryEmail(_ email: String, newEmailVerificationID: String, identityVerificationID: String) async throws {
        throw AccountProfileError.unknown("unexpected setPrimaryEmail")
    }

    func setPassword(_ password: String, identityVerificationID: String?) async throws {
        throw AccountProfileError.unknown("unexpected setPassword")
    }

    func startSocialVerification(connectorID: String, state: String, redirectURI: String) async throws -> SocialVerificationStart {
        throw AccountProfileError.unknown("unexpected startSocialVerification")
    }

    func verifySocial(recordID: String, connectorData: [String: String]) async throws -> String {
        throw AccountProfileError.unknown("unexpected verifySocial")
    }

    func linkSocialIdentity(verificationRecordID: String, identityVerificationID: String?) async throws {
        throw AccountProfileError.unknown("unexpected linkSocialIdentity")
    }
}

/// 假的 hub：记下调用，按预设返回票据或错误。
@MainActor
private final class FakeAccountDeletionHub: AccountDeletionVerifying {
    /// 一次调用。
    enum Call: Equatable {
        case sendEmailCode
        case verify(AccountDeletionProof)
        case fetchSummary
    }

    /// 按顺序记下的调用。
    private(set) var calls: [Call] = []

    /// 换票据时依次抛出的错误，用完后成功。
    var verifyErrors: [AccountDeletionVerificationError] = []

    /// 发验证码时依次抛出的错误，用完后成功。
    var sendCodeErrors: [AccountDeletionVerificationError] = []

    /// 换票据成功时返回的票据。
    var ticket = "ticket-1"

    /// 换票据请求进行中要做的事，用来模拟请求耗时。
    var onVerify: (() -> Void)?

    func sendEmailCode() async throws {
        calls.append(.sendEmailCode)
        if !sendCodeErrors.isEmpty {
            throw sendCodeErrors.removeFirst()
        }
    }

    func verify(_ proof: AccountDeletionProof) async throws -> String {
        calls.append(.verify(proof))
        onVerify?()
        if !verifyErrors.isEmpty {
            throw verifyErrors.removeFirst()
        }
        return ticket
    }

    func fetchSummary() async throws -> AccountDataSummary {
        calls.append(.fetchSummary)
        return AccountDataSummary(services: [])
    }
}
