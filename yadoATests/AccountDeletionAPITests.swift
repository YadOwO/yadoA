import Foundation
import Testing
@testable import yadoA

/// 覆盖注销账号接口的请求构造和状态码映射；不发真实网络请求。
@Suite("注销账号接口")
struct AccountDeletionAPITests {
    @Test("请求构造：三个接口都是 DELETE，路径和鉴权头正确")
    func buildsRequests() throws {
        let aiEndpoint = try #require(URL(string: "https://ai.example.invalid"))
        let syncEndpoint = try #require(URL(string: "https://sync.example.invalid"))
        let hubEndpoint = try #require(URL(string: "https://hub.example.invalid"))
        let api = AccountDeletionAPI(
            aiAccessToken: { "ai" },
            syncAccessToken: { "sync" },
            hubAccessToken: { "hub" },
            aiEndpoint: aiEndpoint,
            syncEndpoint: syncEndpoint,
            hubEndpoint: hubEndpoint
        )

        let aiRequest = api.makeURLRequest(.aiData, token: "abc")
        #expect(aiRequest.httpMethod == "DELETE")
        #expect(aiRequest.url?.absoluteString == "https://ai.example.invalid/v1/account")
        #expect(aiRequest.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(aiRequest.httpBody == nil)
        #expect(aiRequest.timeoutInterval == AccountDeletionAPI.requestTimeout)

        let feedbackRequest = api.makeURLRequest(.feedbackData, token: "hub1")
        #expect(feedbackRequest.httpMethod == "DELETE")
        #expect(feedbackRequest.url?.absoluteString == "https://hub.example.invalid/v1/account")
        #expect(feedbackRequest.value(forHTTPHeaderField: "Authorization") == "Bearer hub1")
        #expect(feedbackRequest.httpBody == nil)
        #expect(feedbackRequest.timeoutInterval == AccountDeletionAPI.requestTimeout)

        let accountRequest = api.makeURLRequest(.account, token: "xyz")
        #expect(accountRequest.httpMethod == "DELETE")
        #expect(accountRequest.url?.absoluteString == "https://sync.example.invalid/v1/me")
        #expect(accountRequest.value(forHTTPHeaderField: "Authorization") == "Bearer xyz")
        #expect(accountRequest.httpBody == nil)
    }

    @Test("状态码映射：401 未授权，429 和 5xx 暂时不可用，其他为契约错误")
    func mapsErrorStatusCodes() {
        #expect(AccountDeletionAPI.error(statusCode: 401) == .unauthorized)
        #expect(AccountDeletionAPI.error(statusCode: 503) == .serviceUnavailable)
        #expect(AccountDeletionAPI.error(statusCode: 429) == .serviceUnavailable)
        #expect(AccountDeletionAPI.error(statusCode: 400) == .invalidContract)
    }

    @Test("调用顺序：AI → 意见反馈 → 账号")
    @MainActor
    func deletesInFixedOrder() async throws {
        let deleter = FakeAccountDeleter()

        try await deleter.deleteRemoteData()

        #expect(deleter.calls == [.ai, .feedback, .account])
    }

    @Test("意见反馈删除失败：抛出原错误，不再删除账号")
    @MainActor
    func feedbackFailureStopsBeforeAccount() async {
        let deleter = FakeAccountDeleter(failing: .feedback, error: .serviceUnavailable)

        await #expect(throws: AccountDeletionAPIError.serviceUnavailable) {
            try await deleter.deleteRemoteData()
        }
        #expect(deleter.calls == [.ai, .feedback])
    }

    @Test("AI 删除失败：后面两步都不调")
    @MainActor
    func aiFailureStopsEverything() async {
        let deleter = FakeAccountDeleter(failing: .ai, error: .network)

        await #expect(throws: AccountDeletionAPIError.network) {
            try await deleter.deleteRemoteData()
        }
        #expect(deleter.calls == [.ai])
    }
}

/// 记录调用顺序的注销假实现，可指定某一步抛错；也供其他注销相关测试共用。
@MainActor
final class FakeAccountDeleter: AccountDeleting {
    /// 三个服务端动作。
    enum Step: Equatable {
        case ai
        case feedback
        case account
    }

    /// 已调用的动作，按调用顺序记录（抛错的那一步也会记录）。
    private(set) var calls: [Step] = []

    /// 要抛错的那一步；为空时三步都成功。
    private let failingStep: Step?

    /// 失败那一步抛出的错误。
    private let error: AccountDeletionAPIError

    /// 创建假实现。
    ///
    /// - Parameters:
    ///   - failing: 要抛错的那一步；为空时都成功。
    ///   - error: 失败时抛出的错误。
    init(failing: Step? = nil, error: AccountDeletionAPIError = .serviceUnavailable) {
        self.failingStep = failing
        self.error = error
    }

    func deleteAIData() async throws {
        try record(.ai)
    }

    func deleteFeedbackData() async throws {
        try record(.feedback)
    }

    func deleteAccount() async throws {
        try record(.account)
    }

    /// 记录一次调用，并在这一步被指定失败时抛错。
    private func record(_ step: Step) throws {
        calls.append(step)
        if step == failingStep { throw error }
    }
}
