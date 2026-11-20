import Foundation
import Testing
@testable import yadoA

/// 覆盖「账号与安全」和改邮箱、改密码、关联 Apple 用到的 Logto Account API：请求构造、响应解码、错误码映射，以及邮箱打码、
/// 身份验证方式选择、验证记录有效期、重发倒计时、环境开关和登录参数；不发真实网络请求。
@Suite("账号与安全")
@MainActor
struct AccountSecurityTests {
    /// 只用来构造请求的 Logto 地址。
    private let endpoint = URL(string: "https://logto.example.invalid")!

    // MARK: - 请求构造

    @Test("读取账号信息：GET /api/my-account，带鉴权头，没有请求体")
    func buildsFetchAccountRequest() throws {
        let request = try LogtoAccountAPI(endpoint: endpoint).makeFetchAccountRequest(accessToken: "token")

        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://logto.example.invalid/api/my-account")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.httpBody == nil)
    }

    @Test("验证身份发码：发到当前邮箱，模板为 UserPermissionValidation")
    func buildsIdentityCodeRequest() throws {
        let request = try LogtoAccountAPI(endpoint: endpoint).makeSendEmailCodeRequest(
            email: "old@example.com",
            purpose: .identityVerification,
            accessToken: "token"
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://logto.example.invalid/api/verifications/verification-code")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try jsonObject(request.httpBody)
        #expect(body["identifier"] as? [String: String] == ["type": "email", "value": "old@example.com"])
        #expect(body["templateType"] as? String == "UserPermissionValidation")
    }

    @Test("新邮箱发码：不传模板类型，由 Logto 用 BindNewIdentifier")
    func buildsNewEmailCodeRequest() throws {
        let request = try LogtoAccountAPI(endpoint: endpoint).makeSendEmailCodeRequest(
            email: "new@example.com",
            purpose: .newEmail,
            accessToken: "token"
        )

        let body = try jsonObject(request.httpBody)
        #expect(body["identifier"] as? [String: String] == ["type": "email", "value": "new@example.com"])
        #expect(body["templateType"] == nil)
        #expect(body.count == 1)
    }

    @Test("校验验证码：POST verify，带标识、记录 ID 和验证码")
    func buildsVerifyCodeRequest() throws {
        let request = try LogtoAccountAPI(endpoint: endpoint).makeVerifyEmailCodeRequest(
            code: "123456",
            email: "new@example.com",
            verificationID: "code-record",
            accessToken: "token"
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://logto.example.invalid/api/verifications/verification-code/verify")
        let body = try jsonObject(request.httpBody)
        #expect(body["identifier"] as? [String: String] == ["type": "email", "value": "new@example.com"])
        #expect(body["verificationId"] as? String == "code-record")
        #expect(body["code"] as? String == "123456")
    }

    @Test("设置主邮箱：身份验证记录放在 logto-verification-id 请求头，新邮箱记录放在请求体")
    func buildsSetPrimaryEmailRequest() throws {
        let request = try LogtoAccountAPI(endpoint: endpoint).makeSetPrimaryEmailRequest(
            email: "new@example.com",
            newEmailVerificationID: "new-record",
            identityVerificationID: "identity-record",
            accessToken: "token"
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://logto.example.invalid/api/my-account/primary-email")
        #expect(request.value(forHTTPHeaderField: "logto-verification-id") == "identity-record")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let body = try jsonObject(request.httpBody)
        #expect(body["email"] as? String == "new@example.com")
        #expect(body["newIdentifierVerificationRecordId"] as? String == "new-record")
        #expect(body.count == 2)
    }

    @Test("设置密码：POST /api/my-account/password；有身份验证记录时放在请求头，没有时不带")
    func buildsSetPasswordRequest() throws {
        let api = LogtoAccountAPI(endpoint: endpoint)
        let request = try api.makeSetPasswordRequest(
            password: "new-secret",
            identityVerificationID: "identity-record",
            accessToken: "token"
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://logto.example.invalid/api/my-account/password")
        #expect(request.value(forHTTPHeaderField: "logto-verification-id") == "identity-record")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let body = try jsonObject(request.httpBody)
        #expect(body["password"] as? String == "new-secret")
        #expect(body.count == 1)

        // 只有 Apple 的账号：Logto 不要求身份验证，不带请求头
        let withoutVerification = try api.makeSetPasswordRequest(
            password: "new-secret",
            identityVerificationID: nil,
            accessToken: "token"
        )
        #expect(withoutVerification.value(forHTTPHeaderField: "logto-verification-id") == nil)
    }

    @Test("关联 Apple：创建社交验证记录带连接器 ID、state 和回程地址")
    func buildsStartSocialVerificationRequest() throws {
        let request = try LogtoAccountAPI(endpoint: endpoint).makeStartSocialVerificationRequest(
            connectorID: "apple-connector",
            state: "yadoa_abc",
            redirectURI: "https://logto.example.invalid/callback/apple-connector",
            accessToken: "token"
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://logto.example.invalid/api/verifications/social")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let body = try jsonObject(request.httpBody)
        #expect(body["connectorId"] as? String == "apple-connector")
        #expect(body["state"] as? String == "yadoa_abc")
        #expect(body["redirectUri"] as? String == "https://logto.example.invalid/callback/apple-connector")
        #expect(body.count == 3)
    }

    @Test("关联 Apple：校验回程用 verificationRecordId，回程参数放在 connectorData")
    func buildsVerifySocialRequest() throws {
        let request = try LogtoAccountAPI(endpoint: endpoint).makeVerifySocialRequest(
            recordID: "social-record",
            connectorData: ["state": "yadoa_abc", "id_token": "jwt", "redirectUri": "https://x/callback/c"],
            accessToken: "token"
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://logto.example.invalid/api/verifications/social/verify")
        let body = try jsonObject(request.httpBody)
        #expect(body["verificationRecordId"] as? String == "social-record")
        let connectorData = try #require(body["connectorData"] as? [String: String])
        #expect(connectorData == ["state": "yadoa_abc", "id_token": "jwt", "redirectUri": "https://x/callback/c"])
        #expect(body.count == 2)
    }

    @Test("关联 Apple：POST /api/my-account/identities；有身份验证记录时放在请求头，没有时不带")
    func buildsLinkSocialIdentityRequest() throws {
        let api = LogtoAccountAPI(endpoint: endpoint)
        let request = try api.makeLinkSocialIdentityRequest(
            verificationRecordID: "social-record",
            identityVerificationID: "identity-record",
            accessToken: "token"
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://logto.example.invalid/api/my-account/identities")
        #expect(request.value(forHTTPHeaderField: "logto-verification-id") == "identity-record")
        let body = try jsonObject(request.httpBody)
        #expect(body["newIdentifierVerificationRecordId"] as? String == "social-record")
        #expect(body.count == 1)

        let withoutVerification = try api.makeLinkSocialIdentityRequest(
            verificationRecordID: "social-record",
            identityVerificationID: nil,
            accessToken: "token"
        )
        #expect(withoutVerification.value(forHTTPHeaderField: "logto-verification-id") == nil)
    }

    // MARK: - 网络往返（假 URLProtocol）

    @Test("设置主邮箱成功返回 204 无响应体：不尝试解码，正常完成")
    func setPrimaryEmailAccepts204() async throws {
        let endpoint = StubURLProtocol.register(statusCode: 204)
        let api = LogtoAccountAPI(endpoint: endpoint, session: StubURLProtocol.makeSession())

        try await api.setPrimaryEmail(
            "new@example.com",
            newEmailVerificationID: "new-record",
            identityVerificationID: "identity-record",
            accessToken: "token"
        )

        let request = try #require(StubURLProtocol.recordedRequests(for: endpoint).first)
        #expect(request.value(forHTTPHeaderField: "logto-verification-id") == "identity-record")
        let body = try jsonObject(request.httpBody)
        #expect(body["email"] as? String == "new@example.com")
    }

    @Test("读取账号信息：解码 identities 的连接器 target 和各字段")
    func fetchAccountDecodesResponse() async throws {
        let endpoint = StubURLProtocol.register(statusCode: 200, body: Data(Self.fullAccountJSON.utf8))
        let api = LogtoAccountAPI(endpoint: endpoint, session: StubURLProtocol.makeSession())

        let info = try await api.fetchAccount(accessToken: "token")

        #expect(info.userID == "user-1")
        #expect(info.username == "yado")
        #expect(info.primaryEmail == "yado@gmail.com")
        #expect(info.hasPrimaryEmail == true)
        #expect(info.hasPassword == false)
        #expect(info.hasSecurityVerificationMethod)
        #expect(info.socialTargets == ["apple"])
        #expect(info.isSocialLinked("apple") == true)
        let request = try #require(StubURLProtocol.recordedRequests(for: endpoint).first)
        #expect(request.httpMethod == "GET")
    }

    @Test("发验证码：解码记录 ID 和 expiresAt；expiresAt 缺失或格式不对时为 nil")
    func sendCodeDecodesExpiry() async throws {
        let body = Data(#"{"verificationRecordId":"code-1","expiresAt":"2026-11-19T10:10:00.000Z"}"#.utf8)
        let endpoint = StubURLProtocol.register(statusCode: 201, body: body)
        let api = LogtoAccountAPI(endpoint: endpoint, session: StubURLProtocol.makeSession())

        let record = try await api.sendEmailVerificationCode(to: "a@example.com", purpose: .identityVerification, accessToken: "t")

        #expect(record.recordID == "code-1")
        // 2026-11-19T10:10:00Z
        #expect(record.expiresAt == Date(timeIntervalSince1970: 1_795_083_000))

        let badEndpoint = StubURLProtocol.register(
            statusCode: 201,
            body: Data(#"{"verificationRecordId":"code-2","expiresAt":"tomorrow"}"#.utf8)
        )
        let badAPI = LogtoAccountAPI(endpoint: badEndpoint, session: StubURLProtocol.makeSession())
        let badRecord = try await badAPI.sendEmailVerificationCode(to: "a@example.com", purpose: .newEmail, accessToken: "t")
        #expect(badRecord.recordID == "code-2")
        #expect(badRecord.expiresAt == nil)
    }

    @Test("发验证码返回 501：归为邮件服务未开通")
    func sendCodeMaps501() async {
        let endpoint = StubURLProtocol.register(statusCode: 501, body: Data(#"{"code":"connector.not_found"}"#.utf8))
        let api = LogtoAccountAPI(endpoint: endpoint, session: StubURLProtocol.makeSession())

        await #expect(throws: AccountProfileError.emailServiceUnavailable) {
            _ = try await api.sendEmailVerificationCode(to: "a@example.com", purpose: .newEmail, accessToken: "token")
        }
    }

    @Test("设置主邮箱返回 422 邮箱已被占用")
    func setPrimaryEmailMapsEmailInUse() async {
        let body = Data(#"{"code":"user.email_already_in_use","message":"taken"}"#.utf8)
        let endpoint = StubURLProtocol.register(statusCode: 422, body: body)
        let api = LogtoAccountAPI(endpoint: endpoint, session: StubURLProtocol.makeSession())

        await #expect(throws: AccountProfileError.emailInUse) {
            try await api.setPrimaryEmail(
                "a@example.com",
                newEmailVerificationID: "new",
                identityVerificationID: "identity",
                accessToken: "token"
            )
        }
    }

    // MARK: - 响应解码

    @Test("老会话（没有 email / identities scope）：缺字段解码为 nil，开关打开时需要重新登录")
    func decodesMissingFieldsAsUnknown() throws {
        let json = #"{"id":"user-1","username":null,"name":"芽豆","hasPassword":true,"hasSecurityVerificationMethod":true}"#
        let info = try JSONDecoder().decode(AccountSecurityInfo.self, from: Data(json.utf8))

        #expect(info.username == nil)
        #expect(info.primaryEmail == nil)
        #expect(info.hasPrimaryEmail == nil)
        #expect(info.isEmailBound == nil)
        #expect(info.socialTargets == nil)
        #expect(info.isSocialLinked("apple") == nil)
        #expect(info.hasPassword == true)
        #expect(info.needsReauthentication(isEmailAccountAvailable: true))
        // 线上开关关闭（旧版 Logto 可能本来就不返回）时不提示重新登录
        #expect(!info.needsReauthentication(isEmailAccountAvailable: false))
    }

    @Test("只有 Apple 的账号：identities 有 apple，没有任何身份验证方式")
    func decodesAppleOnlyAccount() throws {
        let json = """
        {"id":"user-2","primaryEmail":null,"hasPrimaryEmail":false,"hasPassword":false,
         "hasSecurityVerificationMethod":false,"identities":{"apple":{"userId":"apple-1","details":{}}}}
        """
        let info = try JSONDecoder().decode(AccountSecurityInfo.self, from: Data(json.utf8))

        #expect(info.isEmailBound == false)
        #expect(info.isSocialLinked("apple") == true)
        #expect(!info.hasSecurityVerificationMethod)
        #expect(!info.needsReauthentication(isEmailAccountAvailable: true))
    }

    @Test("旧版 Logto 没有 hasSecurityVerificationMethod：按密码和邮箱推断")
    func infersSecurityVerificationMethod() throws {
        let decoder = JSONDecoder()
        let withPassword = try decoder.decode(AccountSecurityInfo.self, from: Data(#"{"id":"u","hasPassword":true}"#.utf8))
        #expect(withPassword.hasSecurityVerificationMethod)

        let withEmail = try decoder.decode(AccountSecurityInfo.self, from: Data(#"{"id":"u","primaryEmail":"a@b.co"}"#.utf8))
        #expect(withEmail.hasSecurityVerificationMethod)

        let nothing = try decoder.decode(AccountSecurityInfo.self, from: Data(#"{"id":"u","identities":{}}"#.utf8))
        #expect(!nothing.hasSecurityVerificationMethod)
        #expect(nothing.socialTargets == [])
        #expect(nothing.isSocialLinked("apple") == false)
    }

    @Test("状态码校验：2xx 通过（204 空响应体也通过），其余按错误码归类")
    func validatesStatusCodes() {
        #expect(throws: Never.self) { try LogtoAccountAPI.validate(statusCode: 204, data: Data()) }
        #expect(throws: Never.self) { try LogtoAccountAPI.validate(statusCode: 201, data: Data("{}".utf8)) }
        #expect(throws: AccountProfileError.rateLimited) {
            try LogtoAccountAPI.validate(statusCode: 429, data: Data(#"{"code":"request.message_rate_limited"}"#.utf8))
        }
        #expect(throws: AccountProfileError.verificationRequired) {
            try LogtoAccountAPI.validate(statusCode: 401, data: Data(#"{"code":"verification_record.permission_denied"}"#.utf8))
        }
        #expect(throws: AccountProfileError.emailServiceUnavailable) {
            try LogtoAccountAPI.validate(statusCode: 501, data: Data())
        }
        #expect(throws: AccountProfileError.unknown("http.500")) {
            try LogtoAccountAPI.validate(statusCode: 500, data: Data())
        }
    }

    @Test("成功响应格式不符时报解码错误")
    func decodeFailureIsReported() {
        #expect(throws: AccountProfileError.unknown("decode")) {
            _ = try LogtoAccountAPI.decode(AccountSecurityInfo.self, from: Data(#"{"username":"no-id"}"#.utf8))
        }
    }

    // MARK: - 错误码映射

    @Test("绑定邮箱、设置密码相关的 Logto 错误码归类")
    func mapsEmailErrorCodes() {
        let cases: [(code: String, expected: AccountProfileError)] = [
            ("user.email_already_in_use", .emailInUse),
            ("verification_code.code_mismatch", .codeMismatch),
            ("verification_code.expired", .codeExpired),
            ("verification_code.exceed_max_try", .codeTooManyAttempts),
            ("verification_code.not_found", .codeInvalid),
            ("verification_code.email_mismatch", .codeInvalid),
            ("request.message_rate_limited", .rateLimited),
            ("verification_record.not_found", .newEmailVerificationInvalid),
            ("verification_record.permission_denied", .verificationRequired),
            ("account_center.field_not_editable", .notAllowed),
            ("account_center.not_enabled", .notAllowed),
            ("auth.unauthorized", .reauthenticationRequired),
            ("session.invalid_credentials", .wrongPassword),
            ("session.verification_blocked_too_many_attempts", .tooManyAttempts),
            ("password.rejected", .passwordRejected),
            ("user.same_password", .samePassword),
            ("user.identity_already_in_use", .socialIdentityInUse),
        ]
        for (code, expected) in cases {
            #expect(AccountProfileError.from(logtoCode: code) == expected, "\(code)")
            #expect(AccountProfileError.from(statusCode: 400, logtoCode: code) == expected, "\(code)")
        }
    }

    @Test("501 不管错误码都归为邮件服务未开通；没有错误码时用 http.<状态码>")
    func mapsStatusCodes() {
        #expect(AccountProfileError.from(statusCode: 501, logtoCode: "connector.not_found") == .emailServiceUnavailable)
        #expect(AccountProfileError.from(statusCode: 501, logtoCode: nil) == .emailServiceUnavailable)
        #expect(AccountProfileError.from(statusCode: 502, logtoCode: nil) == .unknown("http.502"))
    }

    @Test("凭证不被接受时提示与改昵称原来的「请重新登录」一致")
    func reauthenticationKeepsProfileEditMessage() {
        #expect(AccountProfileError.reauthenticationRequired.localizationKey == AccountProfileError.notAllowed.localizationKey)
    }

    @Test("读取账号信息失败：网络问题用网络提示，其余用读取场景的说明，不用修改场景的「暂时无法修改」")
    func loadFailureUsesReadingMessage() {
        #expect(AccountSecurityView.loadFailureDetailKey(for: .network) == AccountProfileError.network.localizationKey)
        #expect(AccountSecurityView.loadFailureDetailKey(for: .notAllowed) == "account.security.load_failed.detail")
        #expect(AccountSecurityView.loadFailureDetailKey(for: .unknown("http.500")) == "account.security.load_failed.detail")
    }

    @Test("注销结果归类：没有错误为完成，本机处理失败为本机清理失败，其余为失败；只有失败不退出登录")
    func classifiesDeletionOutcome() {
        #expect(AccountDeletionOutcome(remoteDeletionError: nil) == .completed)
        #expect(AccountDeletionOutcome(remoteDeletionError: SyncLifecycleError.storage) == .localCleanupFailed)
        #expect(AccountDeletionOutcome(remoteDeletionError: SyncLifecycleError.api(.network)) == .failed)
        #expect(AccountDeletionOutcome(remoteDeletionError: AccountDeletionAPIError.serviceUnavailable) == .failed)
        #expect(AccountDeletionOutcome(remoteDeletionError: ServiceAuthError.sessionExpired) == .failed)

        #expect(AccountDeletionOutcome.completed.signsOut)
        #expect(AccountDeletionOutcome.localCleanupFailed.signsOut)
        #expect(!AccountDeletionOutcome.failed.signsOut)
    }

    @Test("新增的错误和页面文案都有中英文")
    func newTextsAreLocalized() {
        let errors: [AccountProfileError] = [
            .reauthenticationRequired, .verificationRequired, .emailInUse, .codeMismatch, .codeExpired,
            .codeTooManyAttempts, .codeInvalid, .rateLimited, .emailServiceUnavailable, .newEmailVerificationInvalid,
            .passwordRejected, .samePassword, .socialIdentityInUse,
        ]
        let keys = errors.map(\.localizationKey) + [
            "auth.sign_in.email",
            "account.security.title",
            "account.security.shared_note",
            "account.security.reauth.message",
            "account.security.load_failed.detail",
            "account.delete.progress.title",
            "account.delete.progress.message",
            "account.security.email.bind",
            "account.security.email.change",
            "account.email.step_up.message",
            "account.email.code.resend_countdown",
            "account.email.error.invalid_format",
            "account.email.error.same_as_current",
            "account.email.step_up.failed",
            "account.email.step_up.incomplete",
            "account.reauth.switched.message",
            "account.security.password.change",
            "account.security.password.set_action",
            "account.password.change.title",
            "account.password.set.title",
            "account.password.new.title.change",
            "account.password.new.title.set",
            "account.password.new.message",
            "account.password.new.field",
            "account.password.new.placeholder",
            "account.password.confirm.field",
            "account.password.confirm.placeholder",
            "account.password.error.mismatch",
            "account.password.finished.changed",
            "account.password.finished.set",
            "account.password.finished.message",
            "account.security.apple.link",
            "account.apple.link.title",
            "account.apple.link.message",
            "account.apple.link.action",
            "account.apple.finished.title",
            "account.apple.finished.message",
            "account.apple.error.failed",
        ]
        for key in keys {
            #expect(AccountLocalization.string(key, locale: Locale(identifier: "en")) != key)
            #expect(AccountLocalization.string(key, locale: Locale(identifier: "zh-Hans")) != key)
        }
    }

    // MARK: - 邮箱

    @Test("邮箱打码：用户名只留第一个字符，域名保留", arguments: [
        ("yado@gmail.com", "y***@gmail.com"),
        ("a@b.co", "a***@b.co"),
        ("  Yado.Async@Example.com ", "Y***@Example.com"),
        ("芽豆@例子.中国", "芽***@例子.中国"),
        ("@example.com", "***"),
        ("not-an-email", "***"),
    ])
    func masksEmail(email: String, expected: String) {
        #expect(AccountEmail.masked(email) == expected)
    }

    @Test("邮箱格式与 Logto 规则一致，比较时不区分大小写")
    func validatesEmail() {
        #expect(AccountEmail.isValid("a@b.co"))
        #expect(AccountEmail.isValid("yado+test@mail.example.com"))
        #expect(!AccountEmail.isValid(""))
        #expect(!AccountEmail.isValid("a@b"))
        #expect(!AccountEmail.isValid("@b.co"))
        #expect(!AccountEmail.isValid("a b@c.co"))
        #expect(!AccountEmail.isValid(String(repeating: "a", count: AccountEmail.maxLength) + "@b.co"))
        #expect(AccountEmail.isSame("Yado@Gmail.com ", "yado@gmail.com"))
        #expect(!AccountEmail.isSame("a@b.co", "b@b.co"))
    }

    // MARK: - 身份验证

    @Test("身份验证方式：绑定了邮箱先用邮箱验证码，其次密码，完全没有方式时 step-up")
    func selectsIdentityVerificationMethod() {
        let passwordAndEmail = AccountSecurityInfo(
            userID: "u", primaryEmail: "a@b.co", hasPrimaryEmail: true, hasPassword: true,
            hasSecurityVerificationMethod: true
        )
        #expect(AccountIdentityVerificationMethod.select(for: passwordAndEmail) == .currentEmailCode("a@b.co"))

        let passwordOnly = AccountSecurityInfo(
            userID: "u", hasPrimaryEmail: false, hasPassword: true, hasSecurityVerificationMethod: true
        )
        #expect(AccountIdentityVerificationMethod.select(for: passwordOnly) == .password)

        let emailOnly = AccountSecurityInfo(
            userID: "u", primaryEmail: " a@b.co ", hasPrimaryEmail: true, hasPassword: false,
            hasSecurityVerificationMethod: true
        )
        #expect(AccountIdentityVerificationMethod.select(for: emailOnly) == .currentEmailCode("a@b.co"))

        let appleOnly = AccountSecurityInfo(
            userID: "u", hasPrimaryEmail: false, hasPassword: false,
            hasSecurityVerificationMethod: false, socialTargets: ["apple"]
        )
        #expect(AccountIdentityVerificationMethod.select(for: appleOnly) == .stepUp)

        // 只有手机号，或邮箱地址读不到：有方式但 App 用不上，不能走 step-up 绕圈
        let unusable = AccountSecurityInfo(
            userID: "u", hasPrimaryEmail: true, hasPassword: false, hasSecurityVerificationMethod: true
        )
        #expect(AccountIdentityVerificationMethod.select(for: unusable) == .unavailable)
    }

    @Test("身份验证记录 10 分钟有效，本地提前 30 秒视为过期")
    func identityVerificationExpires() {
        let verifiedAt = Date(timeIntervalSince1970: 1_000_000)
        let verification = AccountIdentityVerification(recordID: "r", verifiedAt: verifiedAt)

        #expect(verification.expiresAt == verifiedAt.addingTimeInterval(600))
        #expect(verification.isValid(at: verifiedAt))
        #expect(verification.isValid(at: verifiedAt.addingTimeInterval(9 * 60)))
        #expect(!verification.isValid(at: verifiedAt.addingTimeInterval(9 * 60 + 30)))
        #expect(!verification.isValid(at: verifiedAt.addingTimeInterval(10 * 60)))
    }

    @Test("当前邮箱验证码的身份验证：按发码返回的 expiresAt 过期，没有时从发码请求时刻起算")
    func emailCodeVerificationUsesCodeExpiry() {
        let requestedAt = Date(timeIntervalSince1970: 1_000_000)
        let expiresAt = requestedAt.addingTimeInterval(300)

        let withExpiry = AccountIdentityVerification.emailCode(
            recordID: "verified",
            code: EmailVerificationCodeRecord(recordID: "code", expiresAt: expiresAt),
            requestedAt: requestedAt
        )
        #expect(withExpiry.recordID == "verified")
        #expect(withExpiry.expiresAt == expiresAt)

        let withoutExpiry = AccountIdentityVerification.emailCode(
            recordID: "verified",
            code: EmailVerificationCodeRecord(recordID: "code", expiresAt: nil),
            requestedAt: requestedAt
        )
        #expect(withoutExpiry.expiresAt == requestedAt.addingTimeInterval(AccountIdentityVerification.lifetime))
    }

    @Test("重发倒计时 60 秒，剩余秒数向上取整")
    func cooldownCountsDown() {
        let sentAt = Date(timeIntervalSince1970: 1_000_000)
        #expect(EmailCodeCooldown.remainingSeconds(sentAt: nil, now: sentAt) == 0)
        #expect(EmailCodeCooldown.remainingSeconds(sentAt: sentAt, now: sentAt) == 60)
        #expect(EmailCodeCooldown.remainingSeconds(sentAt: sentAt, now: sentAt.addingTimeInterval(0.5)) == 60)
        #expect(EmailCodeCooldown.remainingSeconds(sentAt: sentAt, now: sentAt.addingTimeInterval(59.2)) == 1)
        #expect(EmailCodeCooldown.remainingSeconds(sentAt: sentAt, now: sentAt.addingTimeInterval(60)) == 0)
        #expect(EmailCodeCooldown.remainingSeconds(sentAt: sentAt, now: sentAt.addingTimeInterval(90)) == 0)
    }

    @Test("发码用途决定邮件模板")
    func purposeSelectsTemplate() {
        #expect(EmailVerificationPurpose.identityVerification.templateType == "UserPermissionValidation")
        #expect(EmailVerificationPurpose.newEmail.templateType == nil)
    }

    // MARK: - 重新登录与 step-up

    @Test("重新登录后比对 sub：同一账号为成功，换了账号或读不到都按换账号处理")
    func comparesSubjectAfterReauthentication() {
        #expect(AccountReauthenticationResult.afterSignIn(originalUserID: "a", currentUserID: "a") == .succeeded)
        #expect(AccountReauthenticationResult.afterSignIn(originalUserID: "a", currentUserID: "b") == .switchedAccount)
        #expect(AccountReauthenticationResult.afterSignIn(originalUserID: "a", currentUserID: nil) == .switchedAccount)
    }

    @Test("step-up 带 acr_values；登录额外申请 email 和 identities scope")
    func stepUpParametersAndScopes() {
        #expect(AuthStore.stepUpExtraParams == ["acr_values": "urn:logto:acr:1fa"])
        #expect(AuthStore.additionalScopes.contains("email"))
        #expect(AuthStore.additionalScopes.contains("identities"))
    }

    // MARK: - 环境开关与登录页

    @Test("邮箱账号只在 dev 开放，线上（Release、DebugProd）关闭")
    func emailAccountOnlyInDev() {
        #expect(AuthConfig.dev.isEmailAccountAvailable)
        #expect(!AuthConfig.prod.isEmailAccountAvailable)
    }

    @Test("设置 / 修改密码只在 dev 开放，线上关闭")
    func passwordChangeOnlyInDev() {
        #expect(AuthConfig.dev.isPasswordChangeAvailable)
        #expect(!AuthConfig.prod.isPasswordChangeAvailable)
    }

    @Test("App 内关联 Apple 只在 dev 开放（有连接器 ID），线上没有")
    func appleLinkOnlyInDev() {
        #expect(AuthConfig.dev.appleSocialConnectorID?.isEmpty == false)
        #expect(AuthConfig.prod.appleSocialConnectorID == nil)
    }

    // MARK: - 关联 Apple 的回程

    @Test("关联 Apple 的 state 以 yadoa_ 开头（与云服务器 nginx 的规则一致），每次不同；回程地址是 Logto 的 /callback/<连接器 ID>")
    func socialLinkStateAndRedirect() {
        let first = SocialLink.makeState()
        let second = SocialLink.makeState()
        #expect(first.hasPrefix("yadoa_"))
        #expect(first.count > "yadoa_".count + 16)
        #expect(first != second)
        #expect(SocialLink.redirectURI(endpoint: "https://dev-accounts.yado1225.top", connectorID: "abc")
            == "https://dev-accounts.yado1225.top/callback/abc")
    }

    @Test("解析回程：state 对得上且有授权结果时原样返回全部参数")
    func parsesAuthorizedCallback() throws {
        let url = try #require(URL(string: "com.yado.yadoa.dev://apple-link?state=yadoa_1&code=c&id_token=jwt&user=%7B%7D"))
        #expect(SocialLink.parseCallback(url, expectedState: "yadoa_1")
            == .authorized(["state": "yadoa_1", "code": "c", "id_token": "jwt", "user": "{}"]))
    }

    @Test("解析回程：用户取消为取消；state 对不上、缺授权结果、别的地址或其他错误都不接受")
    func rejectsBadCallbacks() throws {
        let cancelled = try #require(URL(string: "com.yado.yadoa.dev://apple-link?error=user_cancelled_authorize&state=yadoa_1"))
        #expect(SocialLink.parseCallback(cancelled, expectedState: "yadoa_1") == .cancelled)

        let otherError = try #require(URL(string: "com.yado.yadoa.dev://apple-link?error=invalid_request&state=yadoa_1"))
        #expect(SocialLink.parseCallback(otherError, expectedState: "yadoa_1") == .invalid)

        let wrongState = try #require(URL(string: "com.yado.yadoa.dev://apple-link?state=yadoa_2&id_token=jwt"))
        #expect(SocialLink.parseCallback(wrongState, expectedState: "yadoa_1") == .invalid)

        let noResult = try #require(URL(string: "com.yado.yadoa.dev://apple-link?state=yadoa_1"))
        #expect(SocialLink.parseCallback(noResult, expectedState: "yadoa_1") == .invalid)

        let loginCallback = try #require(URL(string: "com.yado.yadoa.dev://callback?state=yadoa_1&code=c"))
        #expect(SocialLink.parseCallback(loginCallback, expectedState: "yadoa_1") == .invalid)
    }

    @Test("邮箱登录直接进入托管页的邮箱输入页；其他方式不附加参数")
    func emailSignInOpensEmailScreen() {
        #expect(AuthSignInMethod.email.extraParams == ["first_screen": "identifier:sign_in", "identifier": "email"])
        #expect(AuthSignInMethod.password.extraParams == nil)
        #expect(AuthSignInMethod.social(.apple).extraParams == nil)
        #expect(AuthSignInMethod.social(.apple).socialProvider == .apple)
        #expect(AuthSignInMethod.email.socialProvider == nil)
    }

    // MARK: - 工具

    /// 完整的账号信息响应（新会话、账户中心字段都开放）。
    private static let fullAccountJSON = """
    {
      "id": "user-1",
      "username": "yado",
      "primaryEmail": "yado@gmail.com",
      "primaryPhone": null,
      "name": "芽豆",
      "avatar": null,
      "customData": {},
      "identities": {"apple": {"userId": "000123.abc", "details": {"email": "x@privaterelay.appleid.com"}}},
      "lastSignInAt": 1763500000000,
      "createdAt": 1760000000000,
      "updatedAt": 1763500000000,
      "profile": {},
      "applicationId": "app",
      "isSuspended": false,
      "hasPassword": false,
      "hasSecurityVerificationMethod": true,
      "hasPrimaryEmail": true,
      "hasPrimaryPhone": false
    }
    """

    /// 把请求体解析成 JSON 对象。
    private func jsonObject(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
