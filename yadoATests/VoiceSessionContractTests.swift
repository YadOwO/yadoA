import Foundation
import Testing
@testable import yadoA

/// 验证语音记账会话契约的编解码与 yado_ai 的 openapi 一致，工具调用能原样回传。
@Suite("语音记账会话契约")
@MainActor
struct VoiceSessionContractTests {
    @Test("tool_calls 响应解码，canFinishLocally 缺失时按 false 处理")
    func decodesToolCallsResponse() throws {
        let json = """
        {"status":"tool_calls","toolCalls":[
          {"id":"c1","name":"create_transaction","input":{"type":"expense","amount":"28","accountId":"A1",
            "categoryId":"dining","date":"2026-10-20","note":null,"inferredFields":["account"]}},
          {"id":"c2","name":"update_transaction","input":{"id":"T1","patch":{"amount":"40","note":null}}},
          {"id":"c3","name":"search_transactions","input":{"filter":{"keyword":"打车"},"limit":10}}
        ],"canFinishLocally":true}
        """
        let response = try JSONDecoder().decode(VoiceSessionTurnResponse.self, from: Data(json.utf8))
        guard case let .toolCalls(calls, canFinishLocally, followUpAsk) = response else {
            Issue.record("应为 tool_calls")
            return
        }
        #expect(canFinishLocally)
        #expect(followUpAsk == nil)
        #expect(calls.map(\.name) == [.createTransaction, .updateTransaction, .searchTransactions])
        guard case let .createTransaction(_, create) = calls[0],
              case let .updateTransaction(_, update) = calls[1]
        else {
            Issue.record("调用类型不符")
            return
        }
        #expect(create.note == nil)
        #expect(create.inferredFields == [.account])
        #expect(update.patch.amount == "40")
        #expect(update.patch.note == .clear)

        let legacy = #"{"status":"tool_calls","toolCalls":[{"id":"c1","name":"delete_transaction","input":{"id":"T1"}}]}"#
        let legacyResponse = try JSONDecoder().decode(VoiceSessionTurnResponse.self, from: Data(legacy.utf8))
        #expect(legacyResponse == .toolCalls([.deleteTransaction(id: "c1", input: VoiceDeleteTransactionInput(id: "T1"))], canFinishLocally: false))
    }

    @Test("tool_calls 响应带追问时解码 followUpAsk，候选项缺失时为空")
    func decodesToolCallsWithFollowUpAsk() throws {
        let json = """
        {"status":"tool_calls","toolCalls":[{"id":"c1","name":"create_transaction","input":{"type":"expense",
          "amount":"28","accountId":"A1","categoryId":"dining","date":"2026-10-20","note":"午饭","inferredFields":[]}}],
         "canFinishLocally":false,"ask":{"question":"打车花了多少钱？"}}
        """
        let response = try JSONDecoder().decode(VoiceSessionTurnResponse.self, from: Data(json.utf8))
        guard case let .toolCalls(calls, canFinishLocally, followUpAsk) = response else {
            Issue.record("应为 tool_calls")
            return
        }
        #expect(calls.count == 1)
        #expect(!canFinishLocally)
        #expect(followUpAsk == VoiceFollowUpAsk(question: "打车花了多少钱？"))
    }

    @Test("ask 与 reply 响应解码")
    func decodesAskAndReply() throws {
        let ask = #"{"status":"ask","question":"打车花了多少钱？","options":[{"id":"T1","label":"10-19 打车 ¥35"}]}"#
        #expect(try JSONDecoder().decode(VoiceSessionTurnResponse.self, from: Data(ask.utf8))
            == .ask(question: "打车花了多少钱？", options: [VoiceAskOption(id: "T1", label: "10-19 打车 ¥35")]))
        let reply = #"{"status":"reply","text":"已记 1 笔"}"#
        #expect(try JSONDecoder().decode(VoiceSessionTurnResponse.self, from: Data(reply.utf8)) == .reply(text: "已记 1 笔"))
    }

    @Test("工具调用原样回传：必填的空备注编码为 null，修改备注区分不改与清空")
    func encodesToolCallsForRoundTrip() throws {
        let create = VoiceToolCall.createTransaction(id: "c1", input: VoiceCreateTransactionInput(
            type: .expense, amount: "28", accountId: "A1", categoryId: "dining",
            date: "2026-10-20", note: nil, inferredFields: []
        ))
        let createJSON = try jsonObject(create)
        let createInput = try #require(createJSON["input"] as? [String: Any])
        #expect(createJSON["name"] as? String == "create_transaction")
        #expect(createInput.keys.contains("note"))
        #expect(createInput["note"] is NSNull)

        let clear = VoiceToolCall.updateTransaction(id: "c2", input: VoiceUpdateTransactionInput(
            id: "T1", patch: VoiceTransactionPatch(note: .clear)
        ))
        let clearPatch = try #require((try jsonObject(clear)["input"] as? [String: Any])?["patch"] as? [String: Any])
        #expect(clearPatch["note"] is NSNull)

        let unchanged = VoiceToolCall.updateTransaction(id: "c3", input: VoiceUpdateTransactionInput(
            id: "T1", patch: VoiceTransactionPatch(amount: "40")
        ))
        let unchangedPatch = try #require((try jsonObject(unchanged)["input"] as? [String: Any])?["patch"] as? [String: Any])
        #expect(!unchangedPatch.keys.contains("note"))
        #expect(unchangedPatch["amount"] as? String == "40")

        // 解码后再编码保持一致
        let decoded = try JSONDecoder().decode(VoiceToolCall.self, from: JSONEncoder().encode(clear))
        #expect(decoded == clear)
    }

    @Test("账户工具调用解码，原样回传时可空字段编码为 null")
    func decodesAndEncodesAccountToolCalls() throws {
        let json = """
        {"status":"tool_calls","toolCalls":[
          {"id":"c1","name":"adjust_balance","input":{"accountId":"A1","targetBalance":null,"delta":"-12.5","note":null}},
          {"id":"c2","name":"transfer","input":{"fromAccountId":null,"toAccountId":"A2","amount":"300",
            "date":"2026-10-20","note":"还花呗","isAmountUncertain":false}},
          {"id":"c3","name":"create_account","input":{"type":"debitCard","templateId":"debitCard.cmb","name":null,
            "balance":"0","lastFourDigits":"1234","note":null,"inferredFields":["balance"]}},
          {"id":"c4","name":"update_account","input":{"accountId":"A1",
            "patch":{"name":"零钱","lastFourDigits":null,"isDefault":true}}},
          {"id":"c5","name":"delete_account","input":{"accountId":"A3"}}
        ],"canFinishLocally":true}
        """
        let response = try JSONDecoder().decode(VoiceSessionTurnResponse.self, from: Data(json.utf8))
        guard case let .toolCalls(calls, _, _) = response else {
            Issue.record("应为 tool_calls")
            return
        }
        #expect(calls.map(\.name) == [.adjustBalance, .transfer, .createAccount, .updateAccount, .deleteAccount])
        guard case let .adjustBalance(_, adjust) = calls[0],
              case let .transfer(_, transfer) = calls[1],
              case let .createAccount(_, create) = calls[2],
              case let .updateAccount(_, update) = calls[3]
        else {
            Issue.record("调用类型不符")
            return
        }
        #expect(adjust.targetBalance == nil)
        #expect(adjust.delta == "-12.5")
        #expect(transfer.fromAccountId == nil)
        #expect(transfer.toAccountId == "A2")
        #expect(create.name == nil)
        #expect(create.inferredFields == [.balance])
        #expect(update.patch == VoiceAccountPatch(name: "零钱", lastFourDigits: .clear, setsDefault: true))

        // 原样回传：必填的可空字段编码为 null，修改中不改的字段不出现
        let adjustInput = try #require(try jsonObject(calls[0])["input"] as? [String: Any])
        #expect(adjustInput["targetBalance"] is NSNull)
        #expect(adjustInput["note"] is NSNull)
        let transferInput = try #require(try jsonObject(calls[1])["input"] as? [String: Any])
        #expect(transferInput["fromAccountId"] is NSNull)
        let createInput = try #require(try jsonObject(calls[2])["input"] as? [String: Any])
        #expect(createInput["name"] is NSNull)
        #expect(createInput["templateId"] as? String == "debitCard.cmb")
        let patch = try #require((try jsonObject(calls[3])["input"] as? [String: Any])?["patch"] as? [String: Any])
        #expect(patch["lastFourDigits"] is NSNull)
        #expect(patch["isDefault"] as? Bool == true)
        #expect(!patch.keys.contains("note"))
        #expect(!patch.keys.contains("isActive"))
        for call in calls {
            #expect(try JSONDecoder().decode(VoiceToolCall.self, from: JSONEncoder().encode(call)) == call)
        }
    }

    @Test("账户修改只写要改的字段，不设为默认时不写 isDefault")
    func encodesAccountPatchSparsely() throws {
        let restore = try jsonObject(VoiceAccountPatch(isActive: true))
        #expect(restore.keys.sorted() == ["isActive"])
        let clearNote = try jsonObject(VoiceAccountPatch(note: .clear))
        #expect(clearNote.keys.sorted() == ["note"])
        #expect(clearNote["note"] is NSNull)
    }

    @Test("账户工具的执行结果按契约编码")
    func encodesAccountToolOutputs() throws {
        let adjusted = try jsonObject(VoiceToolOutput.balanceAdjusted(before: "100", after: "87.5"))
        #expect(adjusted["ok"] as? Bool == true)
        #expect(adjusted["balanceBefore"] as? String == "100")
        #expect(adjusted["balanceAfter"] as? String == "87.5")
        #expect(try jsonObject(VoiceToolOutput.failure(.balanceNotZero))["code"] as? String == "balance_not_zero")
        #expect(try jsonObject(VoiceToolOutput.failure(.hasTransactions))["code"] as? String == "has_transactions")
    }

    @Test("请求与事件按契约编码")
    func encodesRequestAndEvents() throws {
        let request = VoiceSessionTurnRequest(
            locale: "zh-Hans",
            capabilities: [.accountTools],
            now: "2026-10-20T12:30:00-07:00",
            defaultAccountId: nil,
            accounts: [
                VoiceAccountOption(id: "A1", name: "微信", isActive: true, type: "virtualAccount", balance: "12.5"),
                VoiceAccountOption(id: "A2", name: "花呗", isActive: true, type: "creditCard", balance: "-800"),
            ],
            categories: [VoiceCategoryOption(id: "other", name: "其他", type: .expense)],
            events: [
                .user(text: "午饭 28", selectedOptionId: nil),
                .toolCall(.deleteTransaction(id: "c1", input: VoiceDeleteTransactionInput(id: "T1"))),
                .toolResult(VoiceToolResult(toolCallId: "c1", name: .deleteTransaction, output: .failure(.notFound))),
                .toolResult(VoiceToolResult(toolCallId: "c2", name: .createTransaction, output: .created(id: "T2"))),
                .assistant(text: "已记 1 笔"),
            ]
        )
        let object = try jsonObject(request)
        #expect(object["defaultAccountId"] is NSNull)
        #expect(object["capabilities"] as? [String] == ["account_tools"])
        let accounts = try #require(object["accounts"] as? [[String: Any]])
        #expect(accounts.map { $0["type"] as? String } == ["virtualAccount", "creditCard"])
        #expect(accounts.map { $0["balance"] as? String } == ["12.5", "-800"])
        let events = try #require(object["events"] as? [[String: Any]])
        #expect(events.map { $0["kind"] as? String } == ["user", "tool_call", "tool_result", "tool_result", "assistant"])
        #expect(!events[0].keys.contains("selectedOptionId"))
        let failure = try #require((events[2]["toolResult"] as? [String: Any])?["output"] as? [String: Any])
        #expect(failure["ok"] as? Bool == false)
        #expect(failure["code"] as? String == "not_found")
        let created = try #require((events[3]["toolResult"] as? [String: Any])?["output"] as? [String: Any])
        #expect(created["ok"] as? Bool == true)
        #expect(created["id"] as? String == "T2")
    }

    @Test("查询结果中没有备注的流水编码为 null")
    func encodesSearchItemWithNullNote() throws {
        let output = VoiceToolOutput.searchResult(total: 1, items: [VoiceTransactionItem(
            id: "T1", date: "2026-10-20", type: .income, amount: "100", categoryId: "salary",
            accountId: "A1", note: nil, isEditable: false
        )])
        let object = try jsonObject(output)
        let item = try #require((object["items"] as? [[String: Any]])?.first)
        #expect(item["note"] is NSNull)
        #expect(item["isEditable"] as? Bool == false)
        #expect(object["total"] as? Int == 1)
    }

    @Test("获取凭证失败时也记下凭证耗时，且没有发出请求")
    func recordsTokenTimingWhenTokenFails() async throws {
        let cases: [(ServiceAuthError, VoiceSessionAPIError)] = [
            (.unavailable, .network),
            (.sessionExpired, .sessionExpired),
            (.notSignedIn, .notSignedIn),
        ]
        let endpoint = try #require(URL(string: "https://example.invalid"))
        let request = VoiceSessionTurnRequest(
            locale: "zh-Hans", capabilities: [], now: "2026-10-20T12:30:00-07:00", defaultAccountId: nil,
            accounts: [], categories: [], events: [.user(text: "午饭 28", selectedOptionId: nil)]
        )
        for (authError, expected) in cases {
            // 模拟凭证过期后刷新很慢、最终失败
            let api = VoiceSessionAPI(endpoint: endpoint) {
                try await Task.sleep(for: .milliseconds(20))
                throw authError
            }
            let trace = VoiceRequestTrace(sessionID: "S", turn: 1, request: 1)
            await #expect(throws: expected) {
                try await api.send(request, turnID: UUID(), trace: trace)
            }
            #expect((trace.tokenMs ?? 0) >= 20)
            #expect(trace.transportMs == nil)
            #expect(trace.statusCode == nil)
        }
    }

    @Test("错误状态码映射：429 区分每分钟与每天，402 点数不足，409 轮次失效")
    func mapsErrorStatusCodes() {
        let daily = Data(#"{"code":"TOO_MANY_REQUESTS","message":"x","details":{"rule":"per_day"}}"#.utf8)
        let minute = Data(#"{"code":"TOO_MANY_REQUESTS","message":"x","details":{"rule":"per_minute"}}"#.utf8)
        #expect(VoiceSessionAPI.error(statusCode: 429, body: daily) == .rateLimited(isDaily: true))
        #expect(VoiceSessionAPI.error(statusCode: 429, body: minute) == .rateLimited(isDaily: false))
        #expect(VoiceSessionAPI.error(statusCode: 413, body: Data()) == .sessionTooLong)
        #expect(VoiceSessionAPI.error(statusCode: 502, body: Data()) == .serviceUnavailable)
        #expect(VoiceSessionAPI.error(statusCode: 401, body: Data()) == .unauthorized)
        #expect(VoiceSessionAPI.error(statusCode: 402, body: Data()) == .insufficientPoints)
        #expect(VoiceSessionAPI.error(statusCode: 409, body: Data()) == .turnInvalid)
        #expect(VoiceSessionAPI.error(statusCode: 400, body: Data()) == .invalidContract)
    }

    @Test("账户余额按带符号、最多两位小数的十进制字符串发送")
    func formatsAccountBalance() {
        #expect(VoiceSessionContext.balanceString(Decimal(string: "3000")!) == "3000")
        #expect(VoiceSessionContext.balanceString(Decimal(string: "-12.5")!) == "-12.5")
        #expect(VoiceSessionContext.balanceString(Decimal(string: "0.125")!) == "0.13")
        #expect(VoiceSessionContext.balanceString(.zero) == "0")
    }

    @Test("上下文的语言与时刻格式")
    func formatsLocaleAndTimestamp() throws {
        #expect(VoiceSessionContext.localeCode(for: Locale(identifier: "zh-Hans")) == "zh-Hans")
        #expect(VoiceSessionContext.localeCode(for: Locale(identifier: "en_US")) == "en")
        let timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        let date = Date(timeIntervalSince1970: 1_792_470_600) // 2026-10-20T04:30:00Z
        #expect(VoiceSessionContext.timestamp(date, timeZone: timeZone) == "2026-10-20T12:30:00+08:00")
    }

    @Test("Logto token 接口返回 invalid_grant 或 invalid_target 时判定凭证失效")
    func detectsRevokedCredentials() {
        #expect(AuthStore.isRevokedTokenResponse(statusCode: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)))
        #expect(AuthStore.isRevokedTokenResponse(statusCode: 400, body: Data(#"{"code":"oidc.invalid_target"}"#.utf8)))
        #expect(!AuthStore.isRevokedTokenResponse(statusCode: 400, body: Data(#"{"error":"invalid_request"}"#.utf8)))
        #expect(!AuthStore.isRevokedTokenResponse(statusCode: 500, body: Data(#"{"error":"invalid_grant"}"#.utf8)))
        #expect(!AuthStore.isRevokedTokenResponse(statusCode: 400, body: nil))
    }

    /// 编码为 JSON 对象，便于检查字段是否出现、是否为 null。
    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
