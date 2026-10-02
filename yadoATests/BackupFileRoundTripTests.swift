import Foundation
import Testing
@testable import yadoA

@Suite("备份格式往返", .serialized)
struct BackupFileRoundTripTests {
    /// 构造覆盖三类流水与完整账户字段的信封夹具。
    private func makeFixture() -> BackupFile {
        let baseDate = Date(timeIntervalSince1970: 1_780_000_000.125)
        return BackupFile(
            exportedAt: baseDate,
            appVersion: "1.0",
            appBuild: "42",
            accounts: [
                BackupAccount(
                    id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
                    type: "cash",
                    templateID: nil,
                    name: "现金",
                    note: "零钱",
                    lastFourDigits: nil,
                    balance: "-12.34",
                    currencyCode: "CNY",
                    createdAt: baseDate,
                    updatedAt: baseDate,
                    deactivatedAt: nil
                ),
                BackupAccount(
                    id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
                    type: "creditCard",
                    templateID: "credit.template",
                    name: "信用卡",
                    note: nil,
                    lastFourDigits: "4321",
                    balance: "0.01",
                    currencyCode: "CNY",
                    createdAt: baseDate,
                    updatedAt: baseDate,
                    deactivatedAt: baseDate
                ),
            ],
            transactions: [
                BackupTransaction(
                    id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!,
                    accountID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
                    type: "diningExpense",
                    category: "dining",
                    amount: "25.50",
                    title: "午餐",
                    balanceBefore: nil,
                    balanceAfter: nil,
                    balanceDelta: nil,
                    currencyCode: "CNY",
                    transactionDay: 20260902,
                    note: nil,
                    savedAt: baseDate
                ),
                BackupTransaction(
                    id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!,
                    accountID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
                    type: "income",
                    category: "salary",
                    amount: "100000.99",
                    title: nil,
                    balanceBefore: nil,
                    balanceAfter: nil,
                    balanceDelta: nil,
                    currencyCode: "CNY",
                    transactionDay: 20260901,
                    note: "八月工资",
                    savedAt: baseDate
                ),
                BackupTransaction(
                    id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000003")!,
                    accountID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
                    type: "balanceAdjustment",
                    category: nil,
                    amount: nil,
                    title: nil,
                    balanceBefore: "-12.34",
                    balanceAfter: "6666.66",
                    balanceDelta: "6679.00",
                    currencyCode: "CNY",
                    transactionDay: 20260902,
                    note: "手动修正",
                    savedAt: baseDate
                ),
            ],
            bookkeepingPreference: BackupBookkeepingPreference(
                defaultAccountID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
            )
        )
    }

    @Test("三类流水与全部账户字段 JSON 往返后完全相等")
    func roundTripPreservesAllFields() throws {
        let fixture = makeFixture()

        let data = try BackupFileEncoding.makeEncoder().encode(fixture)
        let decoded = try BackupFileEncoding.decode(data)

        #expect(decoded == fixture)
    }

    @Test("枚举保存 rawValue 原文且所有 UUID 为小写连字符字符串")
    func encodedValuesAreStableRepresentations() throws {
        let data = try BackupFileEncoding.makeEncoder().encode(makeFixture())
        let jsonObject = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let accounts = try #require(jsonObject["accounts"] as? [[String: Any]])
        let transactions = try #require(jsonObject["transactions"] as? [[String: Any]])
        let preference = try #require(
            jsonObject["bookkeepingPreference"] as? [String: Any]
        )

        #expect(accounts[0]["id"] as? String == "aaaaaaaa-0000-0000-0000-000000000001")
        #expect(accounts[1]["id"] as? String == "aaaaaaaa-0000-0000-0000-000000000002")
        #expect(transactions[0]["id"] as? String == "bbbbbbbb-0000-0000-0000-000000000001")
        #expect(transactions[0]["accountID"] as? String == "aaaaaaaa-0000-0000-0000-000000000001")
        #expect(transactions[1]["id"] as? String == "bbbbbbbb-0000-0000-0000-000000000002")
        #expect(transactions[1]["accountID"] as? String == "aaaaaaaa-0000-0000-0000-000000000001")
        #expect(transactions[2]["id"] as? String == "bbbbbbbb-0000-0000-0000-000000000003")
        #expect(transactions[2]["accountID"] as? String == "aaaaaaaa-0000-0000-0000-000000000002")
        #expect(preference["defaultAccountID"] as? String == "aaaaaaaa-0000-0000-0000-000000000001")

        #expect(transactions[0]["type"] as? String == "diningExpense")
        #expect(transactions[1]["type"] as? String == "income")
        #expect(transactions[2]["type"] as? String == "balanceAdjustment")
        #expect(transactions[2]["transactionDay"] as? Int == 20260902)
    }

    @Test("编码端始终写出账户与流水的全部字段")
    func encoderWritesAllFieldsIncludingNil() throws {
        let data = try BackupFileEncoding.makeEncoder().encode(makeFixture())
        let jsonObject = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let account = try #require(
            (jsonObject["accounts"] as? [[String: Any]])?.first
        )
        let transaction = try #require(
            (jsonObject["transactions"] as? [[String: Any]])?.first
        )

        #expect(Set(account.keys) == [
            "id", "type", "templateID", "name", "note", "lastFourDigits",
            "balance", "currencyCode", "createdAt", "updatedAt", "deactivatedAt",
        ])
        #expect(Set(transaction.keys) == [
            "id", "accountID", "type", "category", "amount", "title",
            "balanceBefore", "balanceAfter", "balanceDelta", "currencyCode",
            "transactionDay", "note", "savedAt",
        ])
        #expect(account["templateID"] is NSNull)
        #expect(account["lastFourDigits"] is NSNull)
        #expect(account["deactivatedAt"] is NSNull)
        #expect(transaction["balanceBefore"] is NSNull)
        #expect(transaction["balanceAfter"] is NSNull)
        #expect(transaction["balanceDelta"] is NSNull)
        #expect(transaction["note"] is NSNull)
    }

    @Test("金额边界值与含小数秒日期往返无损")
    func roundTripEdgeValues() throws {
        var fixture = makeFixture()
        let precisionDate = Date(timeIntervalSince1970: 1_780_000_000.625)
        fixture = BackupFile(
            exportedAt: precisionDate,
            appVersion: fixture.appVersion,
            appBuild: fixture.appBuild,
            accounts: [
                BackupAccount(
                    id: UUID(),
                    type: "cash",
                    templateID: nil,
                    name: "边界",
                    note: nil,
                    lastFourDigits: nil,
                    balance: "0.01",
                    currencyCode: "CNY",
                    createdAt: precisionDate,
                    updatedAt: precisionDate,
                    deactivatedAt: nil
                )
            ],
            transactions: [
                BackupTransaction(
                    id: UUID(),
                    accountID: fixture.transactions[0].accountID,
                    type: "balanceAdjustment",
                    category: nil,
                    amount: nil,
                    title: nil,
                    balanceBefore: "-99999999.99",
                    balanceAfter: "0",
                    balanceDelta: "99999999.99",
                    currencyCode: "CNY",
                    transactionDay: 20260101,
                    note: nil,
                    savedAt: precisionDate
                )
            ],
            bookkeepingPreference: nil
        )

        let data = try BackupFileEncoding.makeEncoder().encode(fixture)
        let decoded = try BackupFileEncoding.decode(data)

        #expect(decoded == fixture)
        #expect(decoded.accounts[0].balance == "0.01")
        #expect(decoded.transactions[0].balanceBefore == "-99999999.99")
        #expect(decoded.exportedAt == precisionDate)
    }

    @Test("偏好三态：键缺省、显式 null、有值指针可区分")
    func preferenceStatesAreDistinguishable() throws {
        let withRecord = makeFixture()
        let withNone = BackupFile(
            exportedAt: withRecord.exportedAt,
            appVersion: withRecord.appVersion,
            appBuild: withRecord.appBuild,
            accounts: withRecord.accounts,
            transactions: withRecord.transactions,
            bookkeepingPreference: BackupBookkeepingPreference(defaultAccountID: nil)
        )
        let withoutRecord = BackupFile(
            exportedAt: withRecord.exportedAt,
            appVersion: withRecord.appVersion,
            appBuild: withRecord.appBuild,
            accounts: withRecord.accounts,
            transactions: withRecord.transactions,
            bookkeepingPreference: nil
        )

        let recordData = try BackupFileEncoding.makeEncoder().encode(withRecord)
        let noneData = try BackupFileEncoding.makeEncoder().encode(withNone)
        let absentData = try BackupFileEncoding.makeEncoder().encode(withoutRecord)

        #expect(try BackupFileEncoding.decode(recordData).bookkeepingPreference == withRecord.bookkeepingPreference)
        #expect(try BackupFileEncoding.decode(noneData).bookkeepingPreference == .init(defaultAccountID: nil))
        #expect(try BackupFileEncoding.decode(absentData).bookkeepingPreference == nil)

        #expect(String(decoding: noneData, as: UTF8.self).contains("\"defaultAccountID\" : null"))
        #expect(!String(decoding: absentData, as: UTF8.self).contains("bookkeepingPreference"))
    }

    @Test("未来版本追加的可选字段被旧解码器安全忽略")
    func unknownFieldsAreIgnored() throws {
        let data = try BackupFileEncoding.makeEncoder().encode(makeFixture())
        var jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        jsonObject["futureMetadata"] = "未来字段"
        var firstAccount = (jsonObject["accounts"] as! [[String: Any]])[0]
        firstAccount["futureAccountField"] = 123
        jsonObject["accounts"] = [firstAccount]
        let mutated = try JSONSerialization.data(withJSONObject: jsonObject)

        let decoded = try BackupFileEncoding.decode(mutated)

        #expect(decoded.accounts.count == 1)
        #expect(decoded.accounts[0].id == makeFixture().accounts[0].id)
        #expect(decoded.appVersion == "1.0")
    }

    @Test("身份字段缺失时解码抛错，不静默降级")
    func missingIdentityFieldThrows() throws {
        let data = try BackupFileEncoding.makeEncoder().encode(makeFixture())
        var jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var firstAccount = (jsonObject["accounts"] as! [[String: Any]])[0]
        firstAccount.removeValue(forKey: "id")
        jsonObject["accounts"] = [firstAccount]
        let mutated = try JSONSerialization.data(withJSONObject: jsonObject)

        #expect(throws: DecodingError.self) {
            try BackupFileEncoding.decode(mutated)
        }
    }

    @Test("不符合固定格式的日期串解码抛错")
    func malformedDateThrows() throws {
        let data = try BackupFileEncoding.makeEncoder().encode(makeFixture())
        var jsonObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        jsonObject["exportedAt"] = "2026/09/02 08:00:00"
        let mutated = try JSONSerialization.data(withJSONObject: jsonObject)

        #expect(throws: DecodingError.self) {
            try BackupFileEncoding.decode(mutated)
        }
    }
}
