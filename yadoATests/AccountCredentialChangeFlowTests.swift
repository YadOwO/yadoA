import Foundation
import Testing
@testable import yadoA

/// 改邮箱、改密码、关联 Apple 流程的状态流转：验证身份、发码、保存、身份验证过期、step-up 和 Apple 授权回程；
/// 用假的 Account API 和假的浏览器，不发网络请求。
@Suite("改邮箱、改密码、关联 Apple 流程")
@MainActor
struct AccountCredentialChangeFlowTests {
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

    /// 既有密码又绑定了邮箱的账号。
    private static let passwordAndEmailAccount = AccountSecurityInfo(
        userID: "user-1",
        primaryEmail: "old@example.com",
        hasPrimaryEmail: true,
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
        flow.identityCode = "654321"
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

    @Test("验证码输入只留半角数字，最多 6 位")
    func sanitizesCodeInput() {
        #expect(AccountCredentialChangeFlow.codeLength == 6)
        #expect(AccountCredentialChangeFlow.sanitizedCode("123 456") == "123456")
        #expect(AccountCredentialChangeFlow.sanitizedCode("12345678") == "123456")
        #expect(AccountCredentialChangeFlow.sanitizedCode("验证码：96-62 07。") == "966207")
        #expect(AccountCredentialChangeFlow.sanitizedCode("１２３abc") == "")
        #expect(AccountCredentialChangeFlow.sanitizedCode("") == "")
    }

    @Test("验证码不足 6 位：不能提交，也不发校验请求")
    func incompleteCodeIsNotSubmitted() async {
        let service = FakeAccountSecurityService(account: Self.emailAccount)
        let flow = makeFlow(account: Self.emailAccount, service: service)
        await flow.sendIdentityCode()
        flow.identityCode = "65432"
        #expect(!flow.isIdentityCodeComplete)

        let callCount = service.calls.count
        await flow.submitIdentityCode()
        #expect(service.calls.count == callCount)
        #expect(flow.step == .identity(.currentEmailCode("old@example.com")))

        flow.identityCode = "654321"
        #expect(flow.isIdentityCodeComplete)
        await flow.submitIdentityCode()
        #expect(flow.step == .newEmail)
        #expect(!flow.isNewEmailCodeComplete)
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
        // 验证没通过，不弹「身份已验证」
        #expect(flow.notice == nil)
    }

    // MARK: - 轻提示

    @Test("密码验证通过后给出「身份已验证」的轻提示，再发新邮箱验证码时换成「验证码已发送」")
    func noticesAfterPasswordVerifiedAndCodeSent() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        let flow = makeFlow(account: Self.passwordAccount, service: service)
        #expect(flow.notice == nil)

        flow.password = "secret"
        await flow.submitPassword()
        #expect(flow.notice?.kind == .identityVerified)
        #expect(flow.notice?.localizationKey == "account.toast.identity_verified")

        flow.newEmail = "new@example.com"
        await flow.sendNewEmailCode()
        #expect(flow.notice?.kind == .codeSent)
        #expect(flow.notice?.localizationKey == "account.toast.code_sent")
    }

    @Test("当前邮箱验证码：每次发出都换一条新的轻提示，冷却中点重发不提示，验证通过后提示已验证")
    func noticesForIdentityCode() async throws {
        let clock = TestClock()
        let service = FakeAccountSecurityService(account: Self.emailAccount)
        let flow = makeFlow(account: Self.emailAccount, service: service, clock: clock)

        await flow.sendIdentityCode()
        let first = try #require(flow.notice)
        #expect(first.kind == .codeSent)

        // 冷却中不发，也不换提示
        await flow.sendIdentityCode()
        #expect(flow.notice == first)

        // 冷却结束后重发：同样是「验证码已发送」，但是新的一条，界面会再弹一次
        clock.advance(by: 60)
        await flow.sendIdentityCode()
        let second = try #require(flow.notice)
        #expect(second.kind == .codeSent)
        #expect(second != first)

        flow.identityCode = "654321"
        await flow.submitIdentityCode()
        #expect(flow.notice?.kind == .identityVerified)
    }

    @Test("只有 Apple 的账号设置密码不用验证身份，也就没有「身份已验证」的提示")
    func noNoticeWithoutIdentityVerification() async {
        let service = FakeAccountSecurityService(account: Self.appleOnlyAccount)
        let flow = makeFlow(target: .password, account: Self.appleOnlyAccount, service: service)
        #expect(flow.step == .newPassword)
        #expect(flow.notice == nil)
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

    // MARK: - 验证顺序与改密码

    @Test("绑定了邮箱时优先用邮箱验证码验证身份，即使也设置了密码；改邮箱、改密码都一样")
    func prefersEmailCodeOverPassword() {
        let service = FakeAccountSecurityService(account: Self.passwordAndEmailAccount)
        let emailFlow = makeFlow(target: .email, account: Self.passwordAndEmailAccount, service: service)
        #expect(emailFlow.step == .identity(.currentEmailCode("old@example.com")))

        let passwordFlow = makeFlow(target: .password, account: Self.passwordAndEmailAccount, service: service)
        #expect(passwordFlow.step == .identity(.currentEmailCode("old@example.com")))
        #expect(passwordFlow.isChanging)
    }

    @Test("改密码：邮箱验证码验证身份后输入新密码，保存时带上身份验证记录")
    func changesPasswordAfterEmailCode() async {
        let service = FakeAccountSecurityService(account: Self.passwordAndEmailAccount)
        let flow = makeFlow(target: .password, account: Self.passwordAndEmailAccount, service: service)
        await flow.sendIdentityCode()
        flow.identityCode = "654321"
        await flow.submitIdentityCode()
        #expect(flow.step == .newPassword)

        flow.newPassword = "new-secret"
        flow.confirmPassword = "new-secret"
        #expect(flow.isNewPasswordReady)
        await flow.saveNewPassword()

        #expect(flow.step == .finished(nil))
        #expect(flow.newPassword.isEmpty)
        #expect(flow.confirmPassword.isEmpty)
        #expect(service.calls == [
            .sendEmailCode("old@example.com", .identityVerification),
            .verifyEmailCode(code: "654321", email: "old@example.com", verificationID: "code-1"),
            .setPassword("new-secret", identityVerificationID: "verified-1"),
        ])
    }

    @Test("改密码：两次输入不一致时不能保存，也不发请求")
    func passwordMismatchIsNotSaved() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        let flow = makeFlow(target: .password, account: Self.passwordAccount, service: service)
        flow.password = "secret"
        await flow.submitPassword()
        #expect(flow.step == .newPassword)
        let callCount = service.calls.count

        flow.newPassword = "new-secret"
        flow.confirmPassword = "new-secre"
        #expect(!flow.isNewPasswordReady)
        #expect(flow.isConfirmPasswordMismatched)
        await flow.saveNewPassword()

        #expect(service.calls.count == callCount)
        #expect(flow.step == .newPassword)
        #expect(flow.messageKey == "account.password.error.mismatch")
    }

    @Test("只有 Apple 的账号设置密码：Logto 不要求验证身份，直接输入新密码，保存时不带身份验证记录")
    func appleOnlySetsPasswordWithoutVerification() async {
        let service = FakeAccountSecurityService(account: Self.appleOnlyAccount)
        let flow = makeFlow(target: .password, account: Self.appleOnlyAccount, service: service)
        #expect(flow.step == .newPassword)
        #expect(!flow.isChanging)

        flow.newPassword = "new-secret"
        flow.confirmPassword = "new-secret"
        await flow.saveNewPassword()

        #expect(flow.step == .finished(nil))
        #expect(service.calls == [.setPassword("new-secret", identityVerificationID: nil)])
    }

    @Test("改密码：不符合密码规则或和当前密码相同时提示，输入保留可以接着改")
    func passwordRejectionKeepsInput() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        service.setPasswordErrors = [.passwordRejected, .samePassword]
        let flow = makeFlow(target: .password, account: Self.passwordAccount, service: service)
        flow.password = "secret"
        await flow.submitPassword()

        flow.newPassword = "123"
        flow.confirmPassword = "123"
        await flow.saveNewPassword()
        #expect(flow.step == .newPassword)
        #expect(flow.messageKey == "account.password.error.rejected")
        #expect(flow.newPassword == "123")

        await flow.saveNewPassword()
        #expect(flow.messageKey == "account.password.error.same_as_current")

        await flow.saveNewPassword()
        #expect(flow.step == .finished(nil))
    }

    @Test("改密码：保存时身份验证被拒，回到验证身份；重新验证后新密码还在，直接保存")
    func passwordVerificationRequiredReturnsToIdentity() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        service.setPasswordErrors = [.verificationRequired]
        let flow = makeFlow(target: .password, account: Self.passwordAccount, service: service)
        flow.password = "secret"
        await flow.submitPassword()
        flow.newPassword = "new-secret"
        flow.confirmPassword = "new-secret"

        await flow.saveNewPassword()
        #expect(flow.step == .identity(.password))
        #expect(flow.messageKey == "account.email.error.verification_required")
        #expect(flow.newPassword == "new-secret")

        flow.password = "secret"
        await flow.submitPassword()
        #expect(flow.step == .newPassword)
        await flow.saveNewPassword()
        #expect(flow.step == .finished(nil))
        #expect(service.calls.last == .setPassword("new-secret", identityVerificationID: "identity-2"))
    }

    // MARK: - 关联 Apple

    @Test("关联 Apple：先用邮箱验证码验证身份，再打开授权页；回程交给 Logto 校验后带身份验证记录关联")
    func linksAppleAfterIdentityVerification() async throws {
        let service = FakeAccountSecurityService(account: Self.passwordAndEmailAccount)
        let flow = makeFlow(target: .apple, account: Self.passwordAndEmailAccount, service: service)
        #expect(flow.step == .identity(.currentEmailCode("old@example.com")))
        #expect(!flow.isChanging)
        await flow.sendIdentityCode()
        flow.identityCode = "654321"
        await flow.submitIdentityCode()
        #expect(flow.step == .linkApple)

        await flow.linkApple(authorize: fakeBrowser(service))

        #expect(flow.step == .finished(nil))
        #expect(flow.messageKey == nil)
        let state = try #require(service.lastSocialState)
        #expect(state.hasPrefix("yadoa_"))
        #expect(Array(service.calls.suffix(3)) == [
            .startSocialVerification(connectorID: "apple-connector", redirectURI: "https://logto.test/callback/apple-connector"),
            .verifySocial(recordID: "social-1", connectorData: [
                "state": state,
                "code": "c",
                "id_token": "jwt",
                "redirectUri": "https://logto.test/callback/apple-connector",
            ]),
            .linkSocialIdentity(verificationRecordID: "social-verified-1", identityVerificationID: "verified-1"),
        ])
    }

    @Test("关联 Apple：关掉浏览器或在 Apple 页面取消，不校验、不提示，停在这一步可以再试")
    func cancellingAppleAuthorizationIsQuiet() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        let flow = makeFlow(target: .apple, account: Self.passwordAccount, service: service)
        flow.password = "secret"
        await flow.submitPassword()

        await flow.linkApple(authorize: fakeBrowser(service, query: nil))
        #expect(flow.step == .linkApple)
        #expect(flow.messageKey == nil)

        await flow.linkApple(authorize: fakeBrowser(service, query: "error=user_cancelled_authorize"))
        #expect(flow.step == .linkApple)
        #expect(flow.messageKey == nil)
        #expect(!service.calls.contains { if case .verifySocial = $0 { true } else { false } })
    }

    @Test("关联 Apple：回程的 state 对不上，不交给 Logto，提示没有完成关联")
    func mismatchedStateIsRejected() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        let flow = makeFlow(target: .apple, account: Self.passwordAccount, service: service)
        flow.password = "secret"
        await flow.submitPassword()

        await flow.linkApple(authorize: fakeBrowser(service, state: "yadoa_other"))

        #expect(flow.step == .linkApple)
        #expect(flow.messageKey == "account.apple.error.failed")
        #expect(!service.calls.contains { if case .verifySocial = $0 { true } else { false } })
    }

    @Test("关联 Apple：这个 Apple 账号已关联其他芽豆账号时提示；身份验证被拒时回到验证身份")
    func appleLinkErrors() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        service.linkSocialErrors = [.socialIdentityInUse, .verificationRequired]
        let flow = makeFlow(target: .apple, account: Self.passwordAccount, service: service)
        flow.password = "secret"
        await flow.submitPassword()

        await flow.linkApple(authorize: fakeBrowser(service))
        #expect(flow.step == .linkApple)
        #expect(flow.messageKey == "account.apple.error.in_use")

        await flow.linkApple(authorize: fakeBrowser(service))
        #expect(flow.step == .identity(.password))
        #expect(flow.messageKey == "account.email.error.verification_required")
    }

    @Test("关联 Apple：当前环境没有连接器 ID 时什么都不做")
    func appleLinkUnavailableDoesNothing() async {
        let service = FakeAccountSecurityService(account: Self.passwordAccount)
        let flow = makeFlow(target: .apple, account: Self.passwordAccount, service: service, appleConnectorID: nil)
        flow.password = "secret"
        await flow.submitPassword()
        let callCount = service.calls.count

        await flow.linkApple(authorize: fakeBrowser(service))

        #expect(service.calls.count == callCount)
        #expect(flow.step == .linkApple)
    }

    // MARK: - 工具

    /// 创建流程。
    ///
    /// - Parameters:
    ///   - target: 改邮箱还是改密码，默认改邮箱。
    ///   - account: 打开弹层时的账号信息。
    ///   - service: 假的 Account API。
    ///   - clock: 可拨动的时钟；nil 时用固定时刻。
    ///   - reauthenticate: step-up 的结果。
    ///   - appleConnectorID: Apple 连接器 ID；nil 模拟当前环境不开放关联。
    private func makeFlow(
        target: AccountCredentialChangeFlow.Target = .email,
        account: AccountSecurityInfo,
        service: FakeAccountSecurityService,
        clock: TestClock? = nil,
        reauthenticate: @escaping () -> AccountReauthenticationResult = { .cancelled },
        appleConnectorID: String? = "apple-connector"
    ) -> AccountCredentialChangeFlow {
        let clock = clock ?? TestClock()
        return AccountCredentialChangeFlow(
            target: target,
            account: account,
            service: service,
            reauthenticate: { reauthenticate() },
            now: { clock.now },
            appleConnectorID: appleConnectorID,
            logtoEndpoint: "https://logto.test"
        )
    }

    /// 假的浏览器：按创建验证记录时的 state 拼一个跳回 App 的回程地址。
    ///
    /// - Parameters:
    ///   - service: 记下了 state 的假 Account API。
    ///   - query: 除 state 以外的查询参数；nil 表示用户关掉了浏览器。
    ///   - state: 覆盖回程里的 state，模拟对不上的情况。
    private func fakeBrowser(
        _ service: FakeAccountSecurityService,
        query: String? = "code=c&id_token=jwt",
        state: String? = nil
    ) -> @MainActor (URL) async throws -> URL? {
        { _ in
            guard let query else { return nil }
            let state = state ?? service.lastSocialState ?? ""
            return URL(string: "com.yado.yadoa.dev://apple-link?state=\(state)&\(query)")
        }
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
        case setPassword(String, identityVerificationID: String?)
        case startSocialVerification(connectorID: String, redirectURI: String)
        case verifySocial(recordID: String, connectorData: [String: String])
        case linkSocialIdentity(verificationRecordID: String, identityVerificationID: String?)
    }

    /// 按顺序记下的调用。
    private(set) var calls: [Call] = []

    /// `fetchAccount` 返回的账号信息。
    var account: AccountSecurityInfo

    /// 验证密码时抛出的错误；nil 时成功。
    var passwordError: AccountProfileError?

    /// 设置主邮箱时依次抛出的错误，用完后成功。
    var setPrimaryEmailErrors: [AccountProfileError] = []

    /// 设置密码时依次抛出的错误，用完后成功。
    var setPasswordErrors: [AccountProfileError] = []

    /// 关联社交账号时依次抛出的错误，用完后成功。
    var linkSocialErrors: [AccountProfileError] = []

    /// 最近一次创建社交验证记录时的 state（随机生成，调用里不记，单独存下来给假浏览器用）。
    private(set) var lastSocialState: String?

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

    func setPassword(_ password: String, identityVerificationID: String?) async throws {
        calls.append(.setPassword(password, identityVerificationID: identityVerificationID))
        if !setPasswordErrors.isEmpty {
            throw setPasswordErrors.removeFirst()
        }
    }

    func startSocialVerification(connectorID: String, state: String, redirectURI: String) async throws -> SocialVerificationStart {
        calls.append(.startSocialVerification(connectorID: connectorID, redirectURI: redirectURI))
        lastSocialState = state
        return SocialVerificationStart(recordID: "social-1", authorizationURL: URL(string: "https://appleid.apple.com/auth/authorize")!)
    }

    func verifySocial(recordID: String, connectorData: [String: String]) async throws -> String {
        calls.append(.verifySocial(recordID: recordID, connectorData: connectorData))
        return "social-verified-1"
    }

    func linkSocialIdentity(verificationRecordID: String, identityVerificationID: String?) async throws {
        calls.append(.linkSocialIdentity(verificationRecordID: verificationRecordID, identityVerificationID: identityVerificationID))
        if !linkSocialErrors.isEmpty {
            throw linkSocialErrors.removeFirst()
        }
    }
}
