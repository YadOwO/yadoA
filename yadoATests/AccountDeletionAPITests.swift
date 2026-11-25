import Foundation
import Testing
@testable import yadoA

/// 覆盖注销账号接口：App 只调 yado_hub 的 `DELETE /v1/account`，请求要带注销票据；验证请求构造、响应校验和错误映射；不发真实网络请求。
@Suite("注销账号接口")
@MainActor
struct AccountDeletionAPITests {
    /// hub 注销成功的响应体。
    private static let deletedBody = Data(#"{"deleted":true}"#.utf8)

    @Test("请求构造：DELETE yado_hub 的 /v1/account，带 hub 的 token、注销票据、版本头和够长的超时")
    func buildsRequest() throws {
        let hubEndpoint = try #require(URL(string: "https://hub.example.invalid"))
        let api = AccountDeletionAPI(hubAccessToken: { "hub" }, hubEndpoint: hubEndpoint)

        let request = api.makeURLRequest(token: "hub1", ticket: "ticket-1")

        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://hub.example.invalid/v1/account")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hub1")
        #expect(AccountDeletionAPI.ticketHeaderName == "X-Account-Deletion-Ticket")
        #expect(request.value(forHTTPHeaderField: AccountDeletionAPI.ticketHeaderName) == "ticket-1")
        #expect(request.value(forHTTPHeaderField: AppVersion.headerName) == AppVersion.current)
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == AccountDeletionAPI.requestTimeout)
        // hub 串行等几个服务最坏约 50 秒，前面的 nginx 60 秒；App 不能比它们先超时
        #expect(AccountDeletionAPI.requestTimeout > 60)
    }

    @Test("状态码映射：401 未授权，403 票据无效要重新验证，426 要升级，429 和 5xx（含 hub 某一步失败的 502、未配置的 503）暂时不可用，其他为契约错误")
    func mapsErrorStatusCodes() {
        #expect(AccountDeletionAPI.error(statusCode: 401) == .unauthorized)
        #expect(AccountDeletionAPI.error(statusCode: 403) == .verificationRequired)
        #expect(AccountDeletionAPI.error(statusCode: 426) == .upgradeRequired)
        #expect(AccountDeletionAPI.error(statusCode: 502) == .serviceUnavailable)
        #expect(AccountDeletionAPI.error(statusCode: 503) == .serviceUnavailable)
        #expect(AccountDeletionAPI.error(statusCode: 500) == .serviceUnavailable)
        #expect(AccountDeletionAPI.error(statusCode: 429) == .serviceUnavailable)
        #expect(AccountDeletionAPI.error(statusCode: 400) == .invalidContract)
    }

    @Test("hub 返回 200 和 deleted=true：只发一个请求，用的是 hub 的 token，带着传入的票据")
    func succeedsWithSingleHubRequest() async throws {
        let endpoint = StubURLProtocol.register(statusCode: 200, body: Self.deletedBody)
        let api = AccountDeletionAPI(
            session: StubURLProtocol.makeSession(),
            hubAccessToken: { "hub-token" },
            hubEndpoint: endpoint
        )

        try await api.deleteAccount(ticket: "ticket-1")

        let requests = StubURLProtocol.recordedRequests(for: endpoint)
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path() == "/v1/account")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hub-token")
        #expect(request.value(forHTTPHeaderField: "X-Account-Deletion-Ticket") == "ticket-1")
    }

    @Test("hub 返回 403（票据无效、过期或不属于当前用户）：抛需要重新验证，界面回到验证身份")
    func mapsForbiddenToVerificationRequired() async {
        let body = Data(#"{"code":"ACCOUNT_VERIFICATION_REQUIRED","message":"请先验证身份"}"#.utf8)
        let endpoint = StubURLProtocol.register(statusCode: 403, body: body)
        let api = AccountDeletionAPI(session: StubURLProtocol.makeSession(), hubAccessToken: { "t" }, hubEndpoint: endpoint)

        await #expect(throws: AccountDeletionAPIError.verificationRequired) {
            try await api.deleteAccount(ticket: "expired")
        }
    }

    @Test("hub 删到某个服务失败返回 502：抛暂时不可用，界面提示重试")
    func mapsHubStepFailureToServiceUnavailable() async {
        let body = Data(#"{"code":"ACCOUNT_DELETION_FAILED","message":"注销没有完成，请稍后重试","details":{"step":"yadoa-be"}}"#.utf8)
        let endpoint = StubURLProtocol.register(statusCode: 502, body: body)
        let api = AccountDeletionAPI(session: StubURLProtocol.makeSession(), hubAccessToken: { "t" }, hubEndpoint: endpoint)

        await #expect(throws: AccountDeletionAPIError.serviceUnavailable) {
            try await api.deleteAccount(ticket: "ticket-1")
        }
    }

    @Test("200 但响应体不是 deleted=true：按契约错误处理，不当成已注销")
    func rejectsUnexpectedBody() async {
        let endpoint = StubURLProtocol.register(statusCode: 200, body: Data(#"{"deleted":false}"#.utf8))
        let api = AccountDeletionAPI(session: StubURLProtocol.makeSession(), hubAccessToken: { "t" }, hubEndpoint: endpoint)

        await #expect(throws: AccountDeletionAPIError.invalidContract) {
            try await api.deleteAccount(ticket: "ticket-1")
        }
    }

    @Test("拿不到 hub 的 token：按登录状态归类，不发请求")
    func tokenFailureSkipsRequest() async {
        let endpoint = StubURLProtocol.register(statusCode: 200, body: Self.deletedBody)
        let session = StubURLProtocol.makeSession()

        let expired = AccountDeletionAPI(
            session: session,
            hubAccessToken: { throw ServiceAuthError.sessionExpired },
            hubEndpoint: endpoint
        )
        await #expect(throws: AccountDeletionAPIError.sessionExpired) {
            try await expired.deleteAccount(ticket: "ticket-1")
        }

        let signedOut = AccountDeletionAPI(
            session: session,
            hubAccessToken: { throw ServiceAuthError.notSignedIn },
            hubEndpoint: endpoint
        )
        await #expect(throws: AccountDeletionAPIError.notSignedIn) {
            try await signedOut.deleteAccount(ticket: "ticket-1")
        }

        let unavailable = AccountDeletionAPI(
            session: session,
            hubAccessToken: { throw ServiceAuthError.unavailable },
            hubEndpoint: endpoint
        )
        await #expect(throws: AccountDeletionAPIError.network) {
            try await unavailable.deleteAccount(ticket: "ticket-1")
        }

        #expect(StubURLProtocol.recordedRequests(for: endpoint).isEmpty)
    }
}

/// 注销的假实现：记录调用次数和每次带的票据，可指定抛错；也供其他注销相关测试共用。
@MainActor
final class FakeAccountDeleter: AccountDeleting {
    /// `deleteAccount(ticket:)` 被调用的次数（抛错的那次也算）。
    private(set) var callCount = 0

    /// 每次调用带的票据，按调用顺序。
    private(set) var tickets: [String] = []

    /// 调用时抛出的错误；为空时成功。
    private let error: AccountDeletionAPIError?

    /// 创建假实现。
    ///
    /// - Parameter error: 调用时抛出的错误；为空时成功。
    init(error: AccountDeletionAPIError? = nil) {
        self.error = error
    }

    func deleteAccount(ticket: String) async throws {
        callCount += 1
        tickets.append(ticket)
        if let error { throw error }
    }
}
