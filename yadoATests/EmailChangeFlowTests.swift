import Foundation
import Testing
@testable import yadoA

/// 绑定 / 更换邮箱流程的状态流转：验证身份、发码、保存、身份验证过期和 step-up；用假的 Account API，不发网络请求。
@Suite("绑定邮箱流程")
@MainActor
struct EmailChangeFlowTests {
    /// 有密码、没有邮箱的账号。
    private static let passwordAccount = AccountSecurityInfo(
        userID: "user-1",
        hasPrimaryEmail: false,
        hasPassword: true,
        hasSecurityVerificationMethod: true
    )

    /// 没有密码、只有邮箱的账号。
    private static let emailAccount = AccountSecurityInfo(
        userID: "user-1",
        primaryEmail: "old@example.com",
        hasPrimaryEmail: true,
        hasPassword: false,
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

    @Test("密码验证后绑定：保存时带上身份验证记录和新邮箱的验证记录")
    func bindsWithPassword() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        let flow = makeFlow(account: Self.passwordAccount, service: service)
        #expect(flow.step == .identity(.password))
        #expect(!flow.isChanging)

        flow.password = "secret"
        await flow.submitPassword()
        #expect(flow.step == .newEmail)
        #expect(flow.password.isEmpty)

        flow.newEmail = " New@Example.com "
        flow.newEmailDidChange()
        await flow.sendNewEmailCode()
        #expect(flow.isNewEmailCodeSent)

        flow.newEmailCode = "123 456"
        await flow.saveNewEmail()

        #expect(flow.step == .finished("New@Example.com"))
        #expect(service.calls == [
            .verifyPassword("secret"),
            .sendEmailCode("New@Example.com", .newEmail),
            .verifyEmailCode(code: "123456", email: "New@Example.com", verificationID: "code-1"),
            .setPrimaryEmail(email: "New@Example.com", newEmailVerificationID: "verified-1", identityVerificationID: "identity-1"),
        ])
    }

    @Test("没有密码时给当前邮箱发码验证身份，模板为 UserPermissionValidation")
    func verifiesWithCurrentEmailCode() async {
        let service = FakeAccountSecurityService(account: Self.emailAccount)
        let flow = makeFlow(account: Self.emailAccount, service: service)
        #expect(flow.step == .identity(.currentEmailCode("old@example.com")))
        #expect(flow.isChanging)

        await flow.sendIdentityCode()
        #expect(flow.isIdentityCodeSent)
        // 冷却中再点不会重发
        await flow.sendIdentityCode()

        flow.identityCode = "654321"
        await flow.submitIdentityCode()

        #expect(flow.step == .newEmail)
        #expect(service.calls == [
            .sendEmailCode("old@example.com", .identityVerification),
            .verifyEmailCode(code: "654321", email: "old@example.com", verificationID: "code-1"),
        ])
    }

    @Test("新邮箱和当前邮箱相同或格式不对时不发验证码")
    func rejectsInvalidNewEmail() async {
        let service = FakeAccountSecurityService(account: Self.emailAccount)
        let flow = makeFlow(account: Self.emailAccount, service: service)
        await flow.sendIdentityCode()
        flow.identityCode = "1"
        await flow.submitIdentityCode()
        let callCount = service.calls.count

        flow.newEmail = "OLD@example.com"
        await flow.sendNewEmailCode()
        #expect(flow.messageKey == "account.email.error.same_as_current")

        flow.newEmail = "not-an-email"
        await flow.sendNewEmailCode()
        #expect(flow.messageKey == "account.email.error.invalid_format")

        #expect(service.calls.count == callCount)
        #expect(!flow.isNewEmailCodeSent)
    }

    @Test("身份验证超过有效期：回到验证身份这一步，不再发请求")
    func expiredIdentityReturnsToVerification() async {
        let clock = TestClock()
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        let flow = makeFlow(account: Self.passwordAccount, service: service, clock: clock)
        flow.password = "secret"
        await flow.submitPassword()

        clock.advance(by: AccountIdentityVerification.lifetime)
        flow.newEmail = "new@example.com"
        await flow.sendNewEmailCode()

        #expect(flow.step == .identity(.password))
        #expect(flow.messageKey == "account.email.error.verification_required")
        #expect(service.calls == [.verifyPassword("secret")])
    }

    @Test("保存时 Logto 返回 permission_denied：回到验证身份，重新验证后直接保存，不用再输验证码")
    func permissionDeniedReturnsToVerification() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        service.setPrimaryEmailErrors = [.verificationRequired]
        let flow = makeFlow(account: Self.passwordAccount, service: service)
        flow.password = "secret"
        await flow.submitPassword()
        flow.newEmail = "new@example.com"
        await flow.sendNewEmailCode()
        flow.newEmailCode = "123456"

        await flow.saveNewEmail()
        #expect(flow.step == .identity(.password))
        #expect(flow.messageKey == "account.email.error.verification_required")

        flow.password = "secret"
        await flow.submitPassword()
        #expect(flow.step == .newEmail)
        #expect(flow.isNewEmailCodeSent)
        await flow.saveNewEmail()

        #expect(flow.step == .finished("new@example.com"))
        // 新邮箱的验证码只校验了一次，第二次保存复用校验通过的记录，换上新的身份验证记录
        let verifyCount = service.calls.filter { call in
            if case .verifyEmailCode = call { return true }
            return false
        }.count
        #expect(verifyCount == 1)
        #expect(service.calls.last == .setPrimaryEmail(
            email: "new@example.com",
            newEmailVerificationID: "verified-1",
            identityVerificationID: "identity-2"
        ))
    }

    @Test("新邮箱的验证记录无效：作废验证码，可以立即重新获取")
    func invalidNewEmailRecordResetsCode() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        service.setPrimaryEmailErrors = [.newEmailVerificationInvalid]
        let flow = makeFlow(account: Self.passwordAccount, service: service)
        flow.password = "secret"
        await flow.submitPassword()
        flow.newEmail = "new@example.com"
        await flow.sendNewEmailCode()
        flow.newEmailCode = "123456"

        await flow.saveNewEmail()

        #expect(flow.step == .newEmail)
        #expect(flow.messageKey == "account.email.error.code_invalid")
        #expect(!flow.isNewEmailCodeSent)
        #expect(flow.newEmailCodeSentAt == nil)
    }

    @Test("邮箱已被占用：停在新邮箱这一步并提示")
    func emailInUseShowsMessage() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        service.setPrimaryEmailErrors = [.emailInUse]
        let flow = makeFlow(account: Self.passwordAccount, service: service)
        flow.password = "secret"
        await flow.submitPassword()
        flow.newEmail = "taken@example.com"
        await flow.sendNewEmailCode()
        flow.newEmailCode = "123456"

        await flow.saveNewEmail()

        #expect(flow.step == .newEmail)
        #expect(flow.messageKey == "account.email.error.in_use")
    }

    @Test("发完验证码又改了新邮箱：作废之前的验证码，不会用旧验证码保存")
    func changingNewEmailInvalidatesCode() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        let flow = makeFlow(account: Self.passwordAccount, service: service)
        flow.password = "secret"
        await flow.submitPassword()
        flow.newEmail = "a@example.com"
        await flow.sendNewEmailCode()
        flow.newEmailCode = "123456"

        flow.newEmail = "b@example.com"
        flow.newEmailDidChange()
        #expect(!flow.isNewEmailCodeSent)
        #expect(flow.newEmailCode.isEmpty)

        let callCount = service.calls.count
        await flow.saveNewEmail()
        #expect(service.calls.count == callCount)
    }

    @Test("密码错误：停在验证身份这一步并提示")
    func wrongPasswordShowsMessage() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        service.passwordError = .wrongPassword
        let flow = makeFlow(account: Self.passwordAccount, service: service)
        flow.password = "wrong"

        await flow.submitPassword()

        #expect(flow.step == .identity(.password))
        #expect(flow.messageKey == AccountProfileError.wrongPassword.localizationKey)
    }

    @Test("当前邮箱验证码：身份验证按发码返回的 expiresAt 过期，而不是从校验通过时算")
    func identityCodeExpiresAtSendTimeRecord() async {
        let clock = TestClock()
        let service = FakeAccountSecurityService(account: Self.emailAccount)
        service.codeExpiresAt = clock.now.addingTimeInterval(120)
        let flow = makeFlow(account: Self.emailAccount, service: service, clock: clock)
        await flow.sendIdentityCode()
        flow.identityCode = "654321"
        await flow.submitIdentityCode()

        // 发码后 60 秒：还在有效期内（120 秒减 30 秒余量）
        clock.advance(by: 60)
        flow.newEmail = "new@example.com"
        await flow.sendNewEmailCode()
        #expect(flow.isNewEmailCodeSent)

        // 发码后 100 秒：已过期，保存前回到验证身份，不发保存请求
        clock.advance(by: 40)
        flow.newEmailCode = "123456"
        await flow.saveNewEmail()
        #expect(flow.step == .identity(.currentEmailCode("old@example.com")))
        #expect(flow.messageKey == "account.email.error.verification_required")
        let didSave = service.calls.contains { call in
            if case .setPrimaryEmail = call { return true }
            return false
        }
        #expect(!didSave)
    }

    @Test("当前邮箱验证码：发码没返回 expiresAt 时从发码时刻起算 10 分钟")
    func identityCodeFallsBackToRequestTime() async {
        let clock = TestClock()
        let service = FakeAccountSecurityService(account: Self.emailAccount)
        let flow = makeFlow(account: Self.emailAccount, service: service, clock: clock)
        await flow.sendIdentityCode()

        // 发码 5 分钟后才校验；若从校验时算，再过 280 秒仍有效
        clock.advance(by: 300)
        flow.identityCode = "654321"
        await flow.submitIdentityCode()
        #expect(flow.step == .newEmail)

        clock.advance(by: 280)
        flow.newEmail = "new@example.com"
        await flow.sendNewEmailCode()
        #expect(flow.step == .identity(.currentEmailCode("old@example.com")))
        #expect(!flow.isNewEmailCodeSent)
    }

    @Test("只有 Apple：step-up 时托管页登了另一个账号，流程结束，不再读账号信息")
    func stepUpSwitchedAccountEndsFlow() async {
        let service = FakeAccountSecurityService(account: Self.appleOnlyAccount)
        let flow = makeFlow(account: Self.appleOnlyAccount, service: service) { .switchedAccount }
        #expect(flow.step == .identity(.stepUp))

        await flow.startStepUp()

        #expect(flow.step == .accountSwitched)
        #expect(service.calls.isEmpty)
    }

    @Test("只有 Apple：step-up 回来已在托管页设置邮箱，直接完成")
    func stepUpWithEmailFinishes() async {
        let service = FakeAccountSecurityService(account: AccountSecurityInfo(
            userID: "user-1",
            primaryEmail: "set@example.com",
            hasPrimaryEmail: true,
            hasPassword: false,
            hasSecurityVerificationMethod: true,
            socialTargets: ["apple"]
        ))
        let flow = makeFlow(account: Self.appleOnlyAccount, service: service) { .succeeded }

        await flow.startStepUp()

        #expect(flow.step == .finished("set@example.com"))
        #expect(service.calls == [.fetchAccount])
    }

    @Test("只有 Apple：step-up 回来设置了密码，改用密码验证身份")
    func stepUpWithPasswordSwitchesToPassword() async {
        let service = FakeAccountSecurityService(account: AccountSecurityInfo(
            userID: "user-1",
            hasPrimaryEmail: false,
            hasPassword: true,
            hasSecurityVerificationMethod: true,
            socialTargets: ["apple"]
        ))
        let flow = makeFlow(account: Self.appleOnlyAccount, service: service) { .succeeded }

        await flow.startStepUp()

        #expect(flow.step == .identity(.password))
        #expect(flow.messageKey == nil)
    }

    @Test("只有 Apple：step-up 回来仍没有任何方式时提示，停在 step-up")
    func stepUpWithoutMethodShowsMessage() async {
        let service = FakeAccountSecurityService(account: Self.appleOnlyAccount)
        let flow = makeFlow(account: Self.appleOnlyAccount, service: service) { .succeeded }

        await flow.startStepUp()

        #expect(flow.step == .identity(.stepUp))
        #expect(flow.messageKey == "account.email.step_up.incomplete")
    }

    @Test("只有 Apple：关掉托管页按取消处理，没有提示")
    func stepUpCancelledDoesNothing() async {
        let service = FakeAccountSecurityService(account: Self.appleOnlyAccount)
        let flow = makeFlow(account: Self.appleOnlyAccount, service: service) { .cancelled }

        await flow.startStepUp()

        #expect(flow.step == .identity(.stepUp))
        #expect(flow.messageKey == nil)
        #expect(service.calls.isEmpty)
    }

    // MARK: - 工具

    /// 创建流程。
    ///
    /// - Parameters:
    ///   - account: 打开弹层时的账号信息。
    ///   - service: 假的 Account API。
    ///   - clock: 可拨动的时钟；nil 时用固定时刻。
    ///   - reauthenticate: step-up 的结果。
    private func makeFlow(
        account: AccountSecurityInfo,
        service: FakeAccountSecurityService,
        clock: TestClock? = nil,
        reauthenticate: @escaping () -> AccountReauthenticationResult = { .cancelled }
    ) -> EmailChangeFlow {
        let clock = clock ?? TestClock()
        return EmailChangeFlow(
            account: account,
            service: service,
            reauthenticate: { reauthenticate() },
            now: { clock.now }
        )
    }
}

/// 可手动拨动的时钟。
@MainActor
private final class TestClock {
    /// 当前时刻。
    private(set) var now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 往后拨。
    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

/// 假的 Account API：记下调用，按预设返回递增的记录 ID 或错误。
@MainActor
private final class FakeAccountSecurityService: AccountSecurityServing {
    /// 一次调用。
    enum Call: Equatable {
        case fetchAccount
        case verifyPassword(String)
        case sendEmailCode(String, EmailVerificationPurpose)
        case verifyEmailCode(code: String, email: String, verificationID: String)
        case setPrimaryEmail(email: String, newEmailVerificationID: String, identityVerificationID: String)
    }

    /// 按顺序记下的调用。
    private(set) var calls: [Call] = []

    /// `fetchAccount` 返回的账号信息。
    var account: AccountSecurityInfo

    /// 验证密码时抛出的错误；nil 时成功。
    var passwordError: AccountProfileError?

    /// 设置主邮箱时依次抛出的错误，用完后成功。
    var setPrimaryEmailErrors: [AccountProfileError] = []

    /// 发码接口返回的失效时刻；nil 模拟没返回或解析失败。
    var codeExpiresAt: Date?

    /// 已发出的身份验证记录数。
    private var identityCount = 0
    /// 已发出的验证码记录数。
    private var codeCount = 0
    /// 已校验通过的记录数。
    private var verifiedCount = 0

    init(account: AccountSecurityInfo) {
        self.account = account
    }

    func fetchAccount() async throws -> AccountSecurityInfo {
        calls.append(.fetchAccount)
        return account
    }

    func verifyPassword(_ password: String) async throws -> String {
        calls.append(.verifyPassword(password))
        if let passwordError { throw passwordError }
        identityCount += 1
        return "identity-\(identityCount)"
    }

    func sendEmailCode(to email: String, purpose: EmailVerificationPurpose) async throws -> EmailVerificationCodeRecord {
        calls.append(.sendEmailCode(email, purpose))
        codeCount += 1
        return EmailVerificationCodeRecord(recordID: "code-\(codeCount)", expiresAt: codeExpiresAt)
    }

    func verifyEmailCode(_ code: String, email: String, verificationID: String) async throws -> String {
        calls.append(.verifyEmailCode(code: code, email: email, verificationID: verificationID))
        verifiedCount += 1
        return "verified-\(verifiedCount)"
    }

    func setPrimaryEmail(_ email: String, newEmailVerificationID: String, identityVerificationID: String) async throws {
        calls.append(.setPrimaryEmail(
            email: email,
            newEmailVerificationID: newEmailVerificationID,
            identityVerificationID: identityVerificationID
        ))
        if !setPrimaryEmailErrors.isEmpty {
            throw setPrimaryEmailErrors.removeFirst()
        }
    }
}
