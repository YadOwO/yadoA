import Foundation
import Testing
@testable import yadoA

/// 覆盖注销前验证身份和数据清单：yado_hub 的三个接口的请求构造、请求体编码、错误映射，以及数据清单的解码和展示行；
/// 不发真实网络请求。
@Suite("注销前验证身份和数据清单")
@MainActor
struct AccountDeletionVerificationAPITests {
    /// 指向假 hub 的客户端。
    private func makeAPI() throws -> AccountDeletionVerificationAPI {
        let hubEndpoint = try #require(URL(string: "https://hub.example.invalid"))
        return AccountDeletionVerificationAPI(hubAccessToken: { "hub" }, hubEndpoint: hubEndpoint)
    }

    // MARK: - 请求构造

    @Test("发验证码：POST /v1/account/verification/email-code，带 hub 的 token 和版本头，没有请求体")
    func buildsEmailCodeRequest() throws {
        let request = try makeAPI().makeEmailCodeRequest(token: "hub1")

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://hub.example.invalid/v1/account/verification/email-code")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hub1")
        #expect(request.value(forHTTPHeaderField: AppVersion.headerName) == AppVersion.current)
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == AccountDeletionVerificationAPI.verificationTimeout)
        #expect(AccountDeletionVerificationAPI.verificationTimeout == 40)
    }

    @Test("换票据：POST /v1/account/verification，JSON 请求体、hub 的 token 和版本头")
    func buildsVerificationRequest() throws {
        let request = try makeAPI().makeVerificationRequest(proof: .password("secret"), token: "hub1")

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://hub.example.invalid/v1/account/verification")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hub1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: AppVersion.headerName) == AppVersion.current)
        #expect(request.timeoutInterval == AccountDeletionVerificationAPI.verificationTimeout)
        #expect(request.httpBody != nil)
    }

    @Test("数据清单：GET /v1/account/summary，带 hub 的 token 和版本头，没有请求体，超时 20 秒")
    func buildsSummaryRequest() throws {
        let request = try makeAPI().makeSummaryRequest(token: "hub1")

        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://hub.example.invalid/v1/account/summary")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hub1")
        #expect(request.value(forHTTPHeaderField: AppVersion.headerName) == AppVersion.current)
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == AccountDeletionVerificationAPI.summaryTimeout)
        #expect(AccountDeletionVerificationAPI.summaryTimeout == 20)
    }

    // MARK: - 请求体

    @Test("三种身份凭据的 JSON：method 区分，字段名和 hub 的契约一致")
    func encodesProofs() throws {
        #expect(try Self.json(of: .emailCode("123456")) == ["method": "email_code", "code": "123456"])
        #expect(try Self.json(of: .password("secret")) == ["method": "password", "password": "secret"])
        #expect(try Self.json(of: .idToken("a.b.c")) == ["method": "id_token", "idToken": "a.b.c"])
    }

    @Test("换票据的请求体就是凭据的 JSON")
    func verificationRequestBodyIsProofJSON() throws {
        let request = try makeAPI().makeVerificationRequest(proof: .emailCode("654321"), token: "hub1")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])

        #expect(object == ["method": "email_code", "code": "654321"])
    }

    // MARK: - 错误映射

    @Test("400 看 details.reason：密码错、验证码不对、验证码失效、没有主邮箱、登录不够新")
    func mapsIdentityVerificationFailures() {
        let cases: [(String, AccountDeletionVerificationError)] = [
            ("wrong_password", .wrongPassword),
            ("code_mismatch", .codeMismatch),
            ("code_invalid", .codeInvalid),
            ("email_unavailable", .emailUnavailable),
            ("login_not_recent", .loginNotRecent),
        ]
        for (reason, expected) in cases {
            let body = Data(#"{"code":"IDENTITY_VERIFICATION_FAILED","message":"没通过","details":{"reason":"\#(reason)"}}"#.utf8)
            #expect(AccountDeletionVerificationError.error(statusCode: 400, body: body) == expected)
        }
    }

    @Test("400 认不出的原因、别的错误码、没有 details 或 body 不是 JSON：按服务暂时不可用")
    func mapsUnknownBadRequestToServiceUnavailable() {
        let unknownReason = Data(#"{"code":"IDENTITY_VERIFICATION_FAILED","details":{"reason":"something_new"}}"#.utf8)
        let otherCode = Data(#"{"code":"BAD_REQUEST","message":"参数不对","details":{"reason":"wrong_password"}}"#.utf8)
        let noDetails = Data(#"{"code":"IDENTITY_VERIFICATION_FAILED","message":"没通过"}"#.utf8)
        let arrayDetails = Data(#"{"code":"BAD_REQUEST","details":[{"path":["code"]}]}"#.utf8)

        #expect(AccountDeletionVerificationError.error(statusCode: 400, body: unknownReason) == .serviceUnavailable)
        #expect(AccountDeletionVerificationError.error(statusCode: 400, body: otherCode) == .serviceUnavailable)
        #expect(AccountDeletionVerificationError.error(statusCode: 400, body: noDetails) == .serviceUnavailable)
        #expect(AccountDeletionVerificationError.error(statusCode: 400, body: arrayDetails) == .serviceUnavailable)
        #expect(AccountDeletionVerificationError.error(statusCode: 400, body: Data("oops".utf8)) == .serviceUnavailable)
        #expect(AccountDeletionVerificationError.error(statusCode: 400, body: Data()) == .serviceUnavailable)
    }

    @Test("其他状态码：401 登录失效，426 要升级，429 限流，5xx 和别的都按服务暂时不可用")
    func mapsOtherStatusCodes() {
        let body = Data()
        #expect(AccountDeletionVerificationError.error(statusCode: 401, body: body) == .sessionExpired)
        #expect(AccountDeletionVerificationError.error(statusCode: 426, body: body) == .upgradeRequired)
        #expect(AccountDeletionVerificationError.error(statusCode: 429, body: body) == .rateLimited)
        #expect(AccountDeletionVerificationError.error(statusCode: 502, body: body) == .serviceUnavailable)
        #expect(AccountDeletionVerificationError.error(statusCode: 503, body: body) == .serviceUnavailable)
        #expect(AccountDeletionVerificationError.error(statusCode: 500, body: body) == .serviceUnavailable)
        #expect(AccountDeletionVerificationError.error(statusCode: 404, body: body) == .serviceUnavailable)
    }

    @Test("错误提示文案键：和计划里的对应关系一致，且都有中英文")
    func errorLocalizationKeys() {
        let expected: [(AccountDeletionVerificationError, String)] = [
            (.wrongPassword, "profile.edit.error.wrong_password"),
            (.codeMismatch, "account.email.error.code_mismatch"),
            (.codeInvalid, "account.email.error.code_invalid"),
            (.emailUnavailable, "account.email.identity.unavailable"),
            (.serviceUnavailable, "account.email.identity.unavailable"),
            (.loginNotRecent, "account.delete.verify.error.login_not_recent"),
            (.rateLimited, "account.delete.verify.error.rate_limited"),
            (.sessionExpired, "account.delete.failed.session"),
            (.upgradeRequired, "account.delete.failed.upgrade"),
            (.network, "profile.edit.error.network"),
        ]
        for (error, key) in expected {
            #expect(error.localizationKey == key)
            #expect(AccountLocalization.string(key, locale: Locale(identifier: "en")) != key)
            #expect(AccountLocalization.string(key, locale: Locale(identifier: "zh-Hans")) != key)
        }
    }

    // MARK: - 数据清单的解码和展示行

    @Test("数据清单解码：服务名、状态和各项数量原样读出")
    func decodesSummary() throws {
        let json = """
        {"services":[
          {"service":"yado-ai","status":"ok","items":[{"key":"points_balance","count":120}]},
          {"service":"yadoa-be","status":"unavailable","items":[]}
        ]}
        """
        let summary = try JSONDecoder().decode(AccountDataSummary.self, from: Data(json.utf8))

        #expect(summary.services.count == 2)
        #expect(summary.services[0].service == "yado-ai")
        #expect(summary.services[0].status == .ok)
        #expect(summary.services[0].items == [AccountDataSummary.Item(key: "points_balance", count: 120)])
        #expect(summary.services[1].status == .unavailable)
        #expect(summary.services[1].items.isEmpty)
    }

    @Test("数据清单解码：没有 items 当成空，认不出的状态当成查不到，空的 services 也行")
    func decodesSummaryLeniently() throws {
        let json = #"{"services":[{"service":"yadoi-be","status":"degraded"}]}"#
        let summary = try JSONDecoder().decode(AccountDataSummary.self, from: Data(json.utf8))
        #expect(summary.services == [AccountDataSummary.Service(service: "yadoi-be", status: .unavailable)])

        let empty = try JSONDecoder().decode(AccountDataSummary.self, from: Data(#"{"services":[]}"#.utf8))
        #expect(empty.services.isEmpty)
        #expect(empty.rows.isEmpty)
    }

    @Test("展示行：三个产品的已知项各一行，顺序和服务的顺序一致")
    func rowsFollowServiceOrder() {
        let summary = AccountDataSummary(services: [
            .init(service: "yado-ai", status: .ok, items: [.init(key: "points_balance", count: 80)]),
            .init(service: "yadoa-be", status: .ok, items: [.init(key: "synced_records", count: 12)]),
            .init(service: "yadoi-be", status: .ok, items: [.init(key: "items", count: 3)]),
        ])

        #expect(summary.rows == [
            .count(titleKey: "account.delete.summary.ai.points_balance", count: 80),
            .count(titleKey: "account.delete.summary.yadoa.synced_records", count: 12),
            .count(titleKey: "account.delete.summary.yadoi.items", count: 3),
        ])
    }

    @Test("展示行：认不出的服务或 key 跳过，数量为 0 的跳过")
    func rowsSkipUnknownAndZero() {
        let summary = AccountDataSummary(services: [
            .init(service: "yado-future", status: .ok, items: [.init(key: "points_balance", count: 5)]),
            .init(service: "yadoa-be", status: .ok, items: [
                .init(key: "synced_records", count: 0),
                .init(key: "something_new", count: 9),
            ]),
            .init(service: "yadoi-be", status: .ok, items: [.init(key: "items", count: 7)]),
            .init(service: "yado-ai", status: .ok, items: [.init(key: "items", count: 4)]),
        ])

        #expect(summary.rows == [.count(titleKey: "account.delete.summary.yadoi.items", count: 7)])
    }

    @Test("展示行：查不到的已知服务显示产品名那一行，认不出的服务跳过")
    func rowsShowUnavailableProducts() {
        let summary = AccountDataSummary(services: [
            .init(service: "yadoa-be", status: .unavailable),
            .init(service: "yado-future", status: .unavailable),
            .init(service: "yadoi-be", status: .ok, items: [.init(key: "items", count: 2)]),
            .init(service: "yado-ai", status: .unavailable),
        ])

        #expect(summary.rows == [
            .unavailable(productNameKey: "account.delete.summary.product.yadoa"),
            .count(titleKey: "account.delete.summary.yadoi.items", count: 2),
            .unavailable(productNameKey: "account.delete.summary.product.ai"),
        ])
        #expect(summary.rows[0].isUnavailable)
        #expect(!summary.rows[1].isUnavailable)
    }

    @Test("展示行用到的文案键都有中英文")
    func summaryTextsAreLocalized() {
        let keys = [
            "account.delete.summary.title",
            "account.delete.summary.loading",
            "account.delete.summary.empty",
            "account.delete.summary.failed",
            "account.delete.summary.yadoa.synced_records",
            "account.delete.summary.yadoi.items",
            "account.delete.summary.ai.points_balance",
            "account.delete.summary.product.yadoa",
            "account.delete.summary.product.yadoi",
            "account.delete.summary.product.ai",
            "account.delete.summary.unavailable",
            "account.delete.verify.message",
            "account.delete.verify.step_up.message",
            "account.delete.verify.back",
            "account.delete.verify.reload",
        ]
        for key in keys {
            #expect(AccountLocalization.string(key, locale: Locale(identifier: "en")) != key)
            #expect(AccountLocalization.string(key, locale: Locale(identifier: "zh-Hans")) != key)
        }
    }

    // MARK: - 接口调用

    @Test("发验证码返回 200 和 sent=true：只发一个请求")
    func sendsEmailCode() async throws {
        let endpoint = StubURLProtocol.register(statusCode: 200, body: Data(#"{"sent":true}"#.utf8))
        let api = AccountDeletionVerificationAPI(
            session: StubURLProtocol.makeSession(),
            hubAccessToken: { "hub-token" },
            hubEndpoint: endpoint
        )

        try await api.sendEmailCode()

        let requests = StubURLProtocol.recordedRequests(for: endpoint)
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/v1/account/verification/email-code")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hub-token")
    }

    @Test("换票据返回 200：取出票据；请求体是凭据的 JSON")
    func verifiesAndReturnsTicket() async throws {
        let body = Data(#"{"ticket":"ticket-abc","expiresAt":"2026-11-25T08:10:00.000Z"}"#.utf8)
        let endpoint = StubURLProtocol.register(statusCode: 200, body: body)
        let api = AccountDeletionVerificationAPI(
            session: StubURLProtocol.makeSession(),
            hubAccessToken: { "hub-token" },
            hubEndpoint: endpoint
        )

        let ticket = try await api.verify(.idToken("a.b.c"))

        #expect(ticket == "ticket-abc")
        let request = try #require(StubURLProtocol.recordedRequests(for: endpoint).first)
        #expect(request.url?.path() == "/v1/account/verification")
        let sent = try #require(request.httpBody)
        #expect(try JSONSerialization.jsonObject(with: sent) as? [String: String] == ["method": "id_token", "idToken": "a.b.c"])
    }

    @Test("换票据：200 但没有票据、或 400 密码错误，分别按契约错误和对应原因处理")
    func verifyFailures() async {
        let emptyEndpoint = StubURLProtocol.register(statusCode: 200, body: Data(#"{"ticket":""}"#.utf8))
        let emptyAPI = AccountDeletionVerificationAPI(
            session: StubURLProtocol.makeSession(),
            hubAccessToken: { "t" },
            hubEndpoint: emptyEndpoint
        )
        await #expect(throws: AccountDeletionVerificationError.serviceUnavailable) {
            _ = try await emptyAPI.verify(.password("x"))
        }

        let wrongBody = Data(#"{"code":"IDENTITY_VERIFICATION_FAILED","message":"密码不对","details":{"reason":"wrong_password"}}"#.utf8)
        let wrongEndpoint = StubURLProtocol.register(statusCode: 400, body: wrongBody)
        let wrongAPI = AccountDeletionVerificationAPI(
            session: StubURLProtocol.makeSession(),
            hubAccessToken: { "t" },
            hubEndpoint: wrongEndpoint
        )
        await #expect(throws: AccountDeletionVerificationError.wrongPassword) {
            _ = try await wrongAPI.verify(.password("x"))
        }
    }

    @Test("数据清单返回 200：解码成展示行")
    func fetchesSummary() async throws {
        let body = Data(#"{"services":[{"service":"yadoa-be","status":"ok","items":[{"key":"synced_records","count":6}]}]}"#.utf8)
        let endpoint = StubURLProtocol.register(statusCode: 200, body: body)
        let api = AccountDeletionVerificationAPI(
            session: StubURLProtocol.makeSession(),
            hubAccessToken: { "t" },
            hubEndpoint: endpoint
        )

        let summary = try await api.fetchSummary()

        #expect(summary.rows == [.count(titleKey: "account.delete.summary.yadoa.synced_records", count: 6)])
        let request = try #require(StubURLProtocol.recordedRequests(for: endpoint).first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/v1/account/summary")
    }

    @Test("数据清单：响应体不对按契约错误处理；拿不到 hub 的 token 按登录状态归类、不发请求")
    func summaryFailures() async {
        let badEndpoint = StubURLProtocol.register(statusCode: 200, body: Data(#"{"nope":1}"#.utf8))
        let badAPI = AccountDeletionVerificationAPI(
            session: StubURLProtocol.makeSession(),
            hubAccessToken: { "t" },
            hubEndpoint: badEndpoint
        )
        await #expect(throws: AccountDeletionVerificationError.serviceUnavailable) {
            _ = try await badAPI.fetchSummary()
        }

        let endpoint = StubURLProtocol.register(statusCode: 200, body: Data(#"{"services":[]}"#.utf8))
        let session = StubURLProtocol.makeSession()
        let expired = AccountDeletionVerificationAPI(
            session: session,
            hubAccessToken: { throw ServiceAuthError.sessionExpired },
            hubEndpoint: endpoint
        )
        await #expect(throws: AccountDeletionVerificationError.sessionExpired) {
            _ = try await expired.fetchSummary()
        }
        let unavailable = AccountDeletionVerificationAPI(
            session: session,
            hubAccessToken: { throw ServiceAuthError.unavailable },
            hubEndpoint: endpoint
        )
        await #expect(throws: AccountDeletionVerificationError.network) {
            try await unavailable.sendEmailCode()
        }
        #expect(StubURLProtocol.recordedRequests(for: endpoint).isEmpty)
    }

    // MARK: - 工具

    /// 把凭据编码成字典，方便断言。
    private static func json(of proof: AccountDeletionProof) throws -> [String: String] {
        let data = try JSONEncoder().encode(proof)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }
}
