import Foundation
import Testing
@testable import yadoA

/// 验证同步接口契约的编解码与 yadoA_be 的 openapi 一致，以及请求构造和错误映射。
@Suite("云端同步接口契约")
struct SyncAPIContractTests {
    /// 2026-10-22T08:30:00.500Z；毫秒部分可精确表示，避免浮点误差影响断言。
    private let modifiedAt = Date(timeIntervalSince1970: 1_792_657_800.5)

    private let recordID = UUID(uuidString: "3F1C8A52-6F0B-4A3E-9D55-2C7B1E0F4A10")!

    private let deviceID = UUID(uuidString: "7D2B6C1E-4F3A-4B8E-9A0D-5E6F7A8B9C0D")!

    @Test("推送请求按契约编码：UUID 小写、日期带毫秒、删除显式带 null")
    func encodesPushRequest() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: ["id": recordID.uuidString.lowercased(), "name": "现金", "openingBalance": "12.30", "sortIndex": 3],
            options: [.sortedKeys]
        )
        let upsertChange = try SyncChange.upsert(entityType: .account, recordID: recordID, modifiedAt: modifiedAt, payload: payload)
        let request = SyncPushRequest(
            deviceID: deviceID,
            epoch: 2,
            since: 42,
            changes: [
                upsertChange,
                .deletion(entityType: .transaction, recordID: recordID, modifiedAt: modifiedAt),
            ]
        )

        let object = try jsonObject(SyncCoding.makeEncoder().encode(request))
        #expect(object["deviceId"] as? String == "7d2b6c1e-4f3a-4b8e-9a0d-5e6f7a8b9c0d")
        #expect(object["epoch"] as? Int == 2)
        #expect(object["since"] as? Int == 42)
        let changes = try #require(object["changes"] as? [[String: Any]])
        #expect(changes.count == 2)

        let upsert = changes[0]
        #expect(upsert["entityType"] as? String == "account")
        #expect(upsert["recordId"] as? String == "3f1c8a52-6f0b-4a3e-9d55-2c7b1e0f4a10")
        #expect(upsert["modifiedAt"] as? String == "2026-10-22T08:30:00.500Z")
        #expect(upsert["isDeleted"] as? Bool == false)
        let upsertPayload = try #require(upsert["payload"] as? [String: Any])
        #expect(upsertPayload["openingBalance"] as? String == "12.30")
        #expect(upsertPayload["sortIndex"] as? Int == 3)

        let deletion = changes[1]
        #expect(deletion["entityType"] as? String == "transaction")
        #expect(deletion["isDeleted"] as? Bool == true)
        #expect(deletion.keys.contains("payload"))
        #expect(deletion["payload"] is NSNull)
    }

    @Test("没改过的预置记录的 distantPast 按 1970-01-01 发送")
    func encodesDistantPastAsEpoch() throws {
        let change = SyncChange.deletion(entityType: .category, recordID: recordID, modifiedAt: .distantPast)
        let object = try jsonObject(SyncCoding.makeEncoder().encode(change))
        #expect(object["modifiedAt"] as? String == "1970-01-01T00:00:00.000Z")
    }

    @Test("同步内容必须是 JSON 对象")
    func rejectsNonObjectPayload() {
        #expect(throws: DecodingError.self) {
            try SyncChange.upsert(entityType: .account, recordID: recordID, modifiedAt: modifiedAt, payload: Data("[1,2]".utf8))
        }
    }

    @Test("同步内容往返后内容不变，金额字符串原样保留")
    func roundTripsPayload() throws {
        let original: [String: Any] = [
            "amount": "1234567890.123456789",
            "flag": true,
            "nested": ["a": NSNull(), "b": [1, 2.5, "x"]],
            "note": NSNull(),
            "sortIndex": 7,
        ]
        let data = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        let value = try SyncJSONValue(payload: data)
        let roundTripped = try JSONSerialization.jsonObject(with: value.jsonData()) as? NSDictionary
        #expect(roundTripped == original as NSDictionary)
        guard case let .object(fields) = value else {
            Issue.record("顶层应为对象")
            return
        }
        #expect(fields["amount"] == .string("1234567890.123456789"))
        #expect(fields["flag"] == .bool(true))
        #expect(fields["sortIndex"] == .integer(7))
    }

    @Test("拉取结果解码：墓碑内容为空，未知类型保留原值且不影响整页")
    func decodesPullPage() throws {
        let json = """
        {
          "changes": [
            {"entityType": "account", "recordId": "3f1c8a52-6f0b-4a3e-9d55-2c7b1e0f4a10",
             "modifiedAt": "2026-10-22T08:30:00.500Z", "isDeleted": false,
             "payload": {"name": "现金"}, "serverVersion": 41},
            {"entityType": "transaction", "recordId": "3f1c8a52-6f0b-4a3e-9d55-2c7b1e0f4a10",
             "modifiedAt": "2026-10-22T08:30:00.000Z", "isDeleted": true, "payload": null, "serverVersion": 42},
            {"entityType": "budget", "recordId": "7d2b6c1e-4f3a-4b8e-9a0d-5e6f7a8b9c0d",
             "modifiedAt": "2026-10-22T08:30:00.000Z", "isDeleted": false, "payload": {}, "serverVersion": 43}
          ],
          "nextSince": 43,
          "hasMore": true,
          "resetRequired": false
        }
        """
        let page = try SyncCoding.makeDecoder().decode(SyncPullPage.self, from: Data(json.utf8))
        #expect(page.nextSince == 43)
        #expect(page.hasMore)
        #expect(!page.resetRequired)
        #expect(page.changes.count == 3)

        let account = page.changes[0]
        #expect(account.entityType == .account)
        #expect(account.recordID == recordID)
        #expect(account.modifiedAt == modifiedAt)
        #expect(account.payload == .object(["name": .string("现金")]))
        #expect(account.serverVersion == 41)

        let tombstone = page.changes[1]
        #expect(tombstone.isDeleted)
        #expect(tombstone.payload == nil)

        let unknown = page.changes[2]
        #expect(unknown.entityType == nil)
        #expect(unknown.entityTypeRawValue == "budget")
    }

    @Test("推送响应解码：stale 带回服务端版本，resetRequired 时结果为空")
    func decodesPushResponse() throws {
        let json = """
        {
          "results": [
            {"entityType": "account", "recordId": "3f1c8a52-6f0b-4a3e-9d55-2c7b1e0f4a10", "status": "applied",
             "serverVersion": 50, "modifiedAt": "2026-10-22T08:30:00.500Z"},
            {"entityType": "category", "recordId": "7d2b6c1e-4f3a-4b8e-9a0d-5e6f7a8b9c0d", "status": "stale",
             "serverVersion": 12, "modifiedAt": "2026-10-22T08:30:00.000Z",
             "current": {"entityType": "category", "recordId": "7d2b6c1e-4f3a-4b8e-9a0d-5e6f7a8b9c0d",
                         "modifiedAt": "2026-10-22T08:30:00.000Z", "isDeleted": false,
                         "payload": {"sortIndex": 2}, "serverVersion": 12}}
          ],
          "resetRequired": false
        }
        """
        let response = try SyncCoding.makeDecoder().decode(SyncPushResponse.self, from: Data(json.utf8))
        #expect(response.results.count == 2)
        #expect(response.results[0].status == .applied)
        #expect(response.results[0].serverVersion == 50)
        #expect(response.results[0].modifiedAt == modifiedAt)
        #expect(response.results[0].current == nil)
        #expect(response.results[1].status == .stale)
        #expect(response.results[1].entityType == .category)
        #expect(response.results[1].current?.payload == .object(["sortIndex": .integer(2)]))

        let reset = try SyncCoding.makeDecoder().decode(
            SyncPushResponse.self,
            from: Data(#"{"results":[],"resetRequired":true}"#.utf8)
        )
        #expect(reset.results.isEmpty)
        #expect(reset.resetRequired)
    }

    @Test("请求构造：方法、路径、查询参数和鉴权头")
    func buildsRequests() throws {
        let endpoint = try #require(URL(string: "https://example.invalid"))
        let api = SyncAPI(endpoint: endpoint) { "token" }

        let pull = api.makeURLRequest(.pull(since: 0, deviceID: deviceID, epoch: 1, limit: nil), body: nil, token: "abc")
        #expect(pull.httpMethod == "GET")
        let pullComponents = try #require(pull.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(pullComponents.path == "/v1/sync/pull")
        #expect(pullComponents.queryItems?.first { $0.name == "since" }?.value == "0")
        #expect(pullComponents.queryItems?.first { $0.name == "deviceId" }?.value == "7d2b6c1e-4f3a-4b8e-9a0d-5e6f7a8b9c0d")
        #expect(pullComponents.queryItems?.first { $0.name == "epoch" }?.value == "1")
        #expect(pullComponents.queryItems?.contains { $0.name == "limit" } == false)
        #expect(pull.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(pull.httpBody == nil)

        let limited = api.makeURLRequest(.pull(since: 5, deviceID: deviceID, epoch: 1, limit: 100), body: nil, token: "abc")
        #expect(limited.url?.query()?.contains("limit=100") == true)

        let delete = api.makeURLRequest(.deleteAllData(epoch: 3), body: nil, token: "abc")
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.path() == "/v1/sync/data")
        #expect(delete.url?.query() == "epoch=3")

        let push = api.makeURLRequest(.push, body: Data("{}".utf8), token: "abc")
        #expect(push.httpMethod == "POST")
        #expect(push.url?.path() == "/v1/sync/push")
        #expect(push.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(push.timeoutInterval == SyncAPI.requestTimeout)

        let state = api.makeURLRequest(.state, body: nil, token: "abc")
        #expect(state.httpMethod == "GET")
        #expect(state.url?.absoluteString == "https://example.invalid/v1/sync/state")
    }

    @Test("错误状态码映射：409 只有 EPOCH_MISMATCH 才视为代次不一致")
    func mapsErrorStatusCodes() {
        let epochMismatch = Data(#"{"code":"EPOCH_MISMATCH","message":"x","details":{"epoch":3}}"#.utf8)
        let otherConflict = Data(#"{"code":"CONFLICT","message":"x"}"#.utf8)
        #expect(SyncAPI.error(statusCode: 409, body: epochMismatch) == .epochMismatch(currentEpoch: 3))
        #expect(SyncAPI.error(statusCode: 409, body: otherConflict) == .invalidContract)
        #expect(SyncAPI.error(statusCode: 401, body: Data()) == .unauthorized)
        #expect(SyncAPI.error(statusCode: 400, body: Data()) == .invalidContract)
        #expect(SyncAPI.error(statusCode: 413, body: Data()) == .invalidContract)
        #expect(SyncAPI.error(statusCode: 429, body: Data()) == .serviceUnavailable)
        #expect(SyncAPI.error(statusCode: 502, body: Data()) == .serviceUnavailable)
        #expect(SyncAPI.error(statusCode: 503, body: Data()) == .serviceUnavailable)
    }

    @Test("获取凭证失败时映射为对应错误，且不发出请求")
    func mapsTokenFailures() async throws {
        let cases: [(ServiceAuthError, SyncAPIError)] = [
            (.notSignedIn, .notSignedIn),
            (.sessionExpired, .sessionExpired),
            (.unavailable, .network),
        ]
        let endpoint = try #require(URL(string: "https://example.invalid"))
        for (authError, expected) in cases {
            let api = SyncAPI(endpoint: endpoint) { throw authError }
            await #expect(throws: expected) {
                try await api.fetchState()
            }
        }
    }

    @Test("只有临时故障可以自动重试")
    func classifiesRetryableErrors() {
        #expect(SyncAPIError.network.isRetryable)
        #expect(SyncAPIError.timeout.isRetryable)
        #expect(SyncAPIError.serviceUnavailable.isRetryable)
        #expect(!SyncAPIError.epochMismatch(currentEpoch: 1).isRetryable)
        #expect(!SyncAPIError.sessionExpired.isRetryable)
        #expect(!SyncAPIError.invalidContract.isRetryable)
    }

    @Test("同步服务的 Logto resource 与后端 audience 一致")
    func syncResourceMatchesBackendAudience() {
        #expect(AuthConfig.syncServiceResource == "https://api.yado1225.top/yadoa")
        #expect(SyncAPI.productionEndpoint.absoluteString == "https://yadoa-api.yado1225.top")
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
