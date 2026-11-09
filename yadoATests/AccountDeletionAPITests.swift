import Foundation
import Testing
@testable import yadoA

/// 覆盖注销账号接口的请求构造和状态码映射；不发真实网络请求。
@Suite("注销账号接口")
struct AccountDeletionAPITests {
    @Test("请求构造：两个接口都是 DELETE，路径和鉴权头正确")
    func buildsRequests() throws {
        let aiEndpoint = try #require(URL(string: "https://ai.example.invalid"))
        let syncEndpoint = try #require(URL(string: "https://sync.example.invalid"))
        let api = AccountDeletionAPI(
            aiAccessToken: { "ai" },
            syncAccessToken: { "sync" },
            aiEndpoint: aiEndpoint,
            syncEndpoint: syncEndpoint
        )

        let aiRequest = api.makeURLRequest(.aiData, token: "abc")
        #expect(aiRequest.httpMethod == "DELETE")
        #expect(aiRequest.url?.absoluteString == "https://ai.example.invalid/v1/account")
        #expect(aiRequest.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(aiRequest.httpBody == nil)
        #expect(aiRequest.timeoutInterval == AccountDeletionAPI.requestTimeout)

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
}
