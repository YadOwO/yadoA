import Foundation
import Testing
@testable import yadoA

@Suite("按币种限制金额输入的小数位", .serialized)
@MainActor
struct AmountInputFractionDigitsTests {
    private let enUS = Locale(identifier: "en_US")

    // MARK: - AccountAmountParser

    @Test("没有小数的币种：整数合法，带小数点的都不合法")
    func parserRejectsDecimalPointWhenNoFractionDigits() {
        #expect(AccountAmountParser.amount(from: "12", locale: enUS, fractionDigits: 0) == 12)
        #expect(AccountAmountParser.amount(from: "0", locale: enUS, fractionDigits: 0) == 0)
        #expect(AccountAmountParser.amount(from: "12.5", locale: enUS, fractionDigits: 0) == nil)
        #expect(AccountAmountParser.amount(from: "12.", locale: enUS, fractionDigits: 0) == nil)
        #expect(AccountAmountParser.amount(from: "12.0", locale: enUS, fractionDigits: 0) == nil)

        #expect(AccountAmountParser.normalizedCNYAmountText("12", decimalSeparator: ".", fractionDigits: 0) == "12")
        #expect(AccountAmountParser.normalizedCNYAmountText("12.", decimalSeparator: ".", fractionDigits: 0) == nil)
        #expect(AccountAmountParser.normalizedCNYAmountText("12.5", decimalSeparator: ".", fractionDigits: 0) == nil)
        #expect(AccountAmountParser.normalizedCNYAmountText(".5", decimalSeparator: ".", fractionDigits: 0) == nil)
        #expect(AccountAmountParser.normalizedCNYAmountText("12,5", decimalSeparator: ",", fractionDigits: 0) == nil)

        #expect(AccountAmountParser.cnyAmount(fromNormalized: "12", fractionDigits: 0) == 12)
        #expect(AccountAmountParser.cnyAmount(fromNormalized: "12.5", fractionDigits: 0) == nil)
        #expect(AccountAmountParser.cnyAmount(fromNormalized: "12.", fractionDigits: 0) == nil)
    }

    @Test("默认仍是存储精度两位，一位小数时第二位被拒绝")
    func parserDefaultsToTwoDigitsAndHonoursOne() {
        #expect(AccountAmountParser.amount(from: "12.50", locale: enUS) == Decimal(string: "12.5"))
        #expect(AccountAmountParser.amount(from: "12.345", locale: enUS) == nil)
        #expect(AccountAmountParser.normalizedCNYAmountText("12.34", decimalSeparator: ".") == "12.34")
        #expect(AccountAmountParser.normalizedCNYAmountText("12.345", decimalSeparator: ".") == nil)
        #expect(AccountAmountParser.normalizedCNYAmountText("12.3", decimalSeparator: ".", fractionDigits: 1) == "12.3")
        #expect(AccountAmountParser.normalizedCNYAmountText("12.34", decimalSeparator: ".", fractionDigits: 1) == nil)
    }

    @Test("订阅编辑页按存储精度解析旧金额：带小数的 68.5 在无小数币种的账本下也合法")
    func parserAcceptsStoredPrecisionForLegacyAmount() {
        // 订阅编辑页的金额按两位存储精度解析，不按账本币种的小数位
        #expect(AccountAmountParser.amount(from: "68.5", locale: enUS, fractionDigits: 2) == Decimal(string: "68.5"))
        // 同一个旧金额按无小数币种解析仍然不合法，所以编辑页不能用账本币种的小数位解析初始值
        #expect(AccountAmountParser.amount(from: "68.5", locale: enUS, fractionDigits: 0) == nil)
    }

    @Test("新建账户的期初余额按币种小数位校验")
    func openingBalanceHonoursFractionDigits() {
        #expect(AccountDraft.openingBalance(from: "", locale: enUS, fractionDigits: 0) == 0)
        #expect(AccountDraft.openingBalance(from: "100", locale: enUS, fractionDigits: 0) == 100)
        #expect(AccountDraft.openingBalance(from: "100.5", locale: enUS, fractionDigits: 0) == nil)
        #expect(AccountDraft.openingBalance(from: "100.5", locale: enUS) == Decimal(string: "100.5"))
        let draft = AccountDraft(accountType: .cash, name: "现金", amountText: "100.5")
        #expect(draft.isFormValid(locale: enUS))
        #expect(!draft.isFormValid(locale: enUS, fractionDigits: 0))
    }

    // MARK: - AmountExpression

    @Test("没有小数的币种：算式里的整数合法，带小数点的都不合法")
    func expressionRejectsDecimalPointWhenNoFractionDigits() {
        #expect(AmountExpression.isValidInput("12", fractionDigits: 0))
        #expect(AmountExpression.isValidInput("12+", fractionDigits: 0))
        #expect(AmountExpression.isValidInput("1+2×3", fractionDigits: 0))
        #expect(!AmountExpression.isValidInput("12.5", fractionDigits: 0))
        #expect(!AmountExpression.isValidInput("12.", fractionDigits: 0))
        #expect(!AmountExpression.isValidInput("1.5+2", fractionDigits: 0))
        #expect(!AmountExpression.isValidInput("1+2.5", fractionDigits: 0))
        // 默认两位小数不变
        #expect(AmountExpression.isValidInput("1.25+2.5"))
        #expect(!AmountExpression.isValidInput("1.255"))
    }

    @Test("算式结果按币种的小数位四舍五入")
    func expressionResultRoundsToFractionDigits() {
        #expect(AmountExpression.result(of: "10÷3") == Decimal(string: "3.33"))
        #expect(AmountExpression.result(of: "10÷3", fractionDigits: 0) == 3)
        #expect(AmountExpression.result(of: "5÷2", fractionDigits: 0) == 3)
        #expect(AmountExpression.result(of: "1÷3", fractionDigits: 0) == nil)
    }

    @Test("无小数币种里算式的小数部分被丢掉，其他币种原样")
    func expressionDropsFractionsOnlyWhenNoFractionDigits() {
        #expect(AmountExpression.droppingFractionDigits(from: "12.5", fractionDigits: 0) == "12")
        #expect(AmountExpression.droppingFractionDigits(from: "12.5+", fractionDigits: 0) == "12+")
        #expect(AmountExpression.droppingFractionDigits(from: "1.5+2.25×3", fractionDigits: 0) == "1+2×3")
        #expect(AmountExpression.droppingFractionDigits(from: ".5", fractionDigits: 0) == "")
        #expect(AmountExpression.droppingFractionDigits(from: "12.5+3", fractionDigits: 2) == "12.5+3")
    }

    // MARK: - 实时输入：旧金额带小数时可以删掉

    @Test("无小数币种的实时输入：小数点和小数部分被丢掉，旧金额能一位位退格")
    func liveInputDropsFractionForZeroDigitCurrency() {
        #expect(AccountAmountParser.normalizedLiveAmountText("12.5", decimalSeparator: ".", fractionDigits: 0) == "12")
        #expect(AccountAmountParser.normalizedLiveAmountText("12.", decimalSeparator: ".", fractionDigits: 0) == "12")
        #expect(AccountAmountParser.normalizedLiveAmountText("12,5", decimalSeparator: ",", fractionDigits: 0) == "12")
        #expect(AccountAmountParser.normalizedLiveAmountText(".5", decimalSeparator: ".", fractionDigits: 0) == "")
        #expect(AccountAmountParser.normalizedLiveAmountText("125", decimalSeparator: ".", fractionDigits: 0) == "125")
        #expect(AccountAmountParser.normalizedLiveAmountText("", decimalSeparator: ".", fractionDigits: 0) == "")
        // 非数字仍然拒绝
        #expect(AccountAmountParser.normalizedLiveAmountText("1a", decimalSeparator: ".", fractionDigits: 0) == nil)
        // 有小数位的币种与严格规则一致
        #expect(AccountAmountParser.normalizedLiveAmountText("12.", decimalSeparator: ".", fractionDigits: 2) == "12.")
        #expect(AccountAmountParser.normalizedLiveAmountText("12.345", decimalSeparator: ".", fractionDigits: 2) == nil)
    }

    @Test("记账编辑：旧金额 12.50 在无小数币种下退格能删到整数")
    func editFlowLetsUserDeleteLegacyDecimals() {
        let flow = DiningExpenseEditFlow(
            draft: DiningExpenseEditDraft(
                id: UUID(), accountID: UUID(), amountText: "12.5", transactionDay: 20260901
            )
        ) { _ in }

        // 退格一次：「12.5」→「12.」
        flow.updateAmountText("12.", decimalSeparator: ".", fractionDigits: 0)
        #expect(flow.draft.amountText == "12")
        // 继续改写：整数部分可以改，也输不进新的小数
        flow.updateAmountText("125", decimalSeparator: ".", fractionDigits: 0)
        #expect(flow.draft.amountText == "125")
        flow.updateAmountText("125.5", decimalSeparator: ".", fractionDigits: 0)
        #expect(flow.draft.amountText == "125")
    }

    @Test("新记账：无小数币种输不进小数点，有小数的币种照常两位")
    func entryFlowHonoursFractionDigits() {
        let flow = DiningExpenseEntryFlow { _ in }

        flow.updateAmountText("12", decimalSeparator: ".", fractionDigits: 0)
        flow.updateAmountText("12.", decimalSeparator: ".", fractionDigits: 0)
        #expect(flow.draft.amountText == "12")

        flow.updateAmountText("12.5", decimalSeparator: ".")
        #expect(flow.draft.amountText == "12.5")
        flow.updateAmountText("12.567", decimalSeparator: ".")
        #expect(flow.draft.amountText == "12.5")
    }

    @Test("转账：无小数币种输不进小数点，也能删掉已有的小数")
    func transferFlowHonoursFractionDigits() {
        let flow = TransferFlow(draft: TransferDraft(amountText: "30.5", transactionDay: 20261022)) { _ in }

        flow.updateAmountText("30.", decimalSeparator: ".", fractionDigits: 0)
        #expect(flow.draft.amountText == "30")
        flow.updateAmountText("30.5", decimalSeparator: ".", fractionDigits: 0)
        #expect(flow.draft.amountText == "30")
        flow.updateAmountText("30.55", decimalSeparator: ".")
        #expect(flow.draft.amountText == "30.55")
    }

    @Test("调余额：当前余额带小数时，无小数币种下能删掉小数")
    func balanceAdjustmentFlowHonoursFractionDigits() {
        let flow = BalanceAdjustmentFlow(
            draft: BalanceAdjustmentDraft(accountID: UUID(), currentBalance: Decimal(string: "40.5")!),
            currentBalance: Decimal(string: "40.5")!
        ) { _ in .unchanged(currentBalance: 0) }
        #expect(flow.draft.amountText == "40.5")

        flow.updateAmountText("40.", decimalSeparator: ".", fractionDigits: 0)
        #expect(flow.draft.amountText == "40")
        #expect(flow.draft.targetBalance == 40)
        flow.updateAmountText("40.5", decimalSeparator: ".", fractionDigits: 0)
        #expect(flow.draft.amountText == "40")
    }

    @Test("周期记账编辑沿用记账流程：旧金额的小数可以删，也不能输新的")
    func recurringEditUsesEntryFlowRules() {
        // 周期记账编辑页用同一个记账流程和表单，这里用带旧金额的草稿覆盖这条路径
        let flow = DiningExpenseEntryFlow(
            draft: DiningExpenseDraft(amountText: "800.5", transactionDay: 20261101),
            requiresCategoryConfirmation: true
        ) { _ in }

        flow.updateAmountText("800.", decimalSeparator: ".", fractionDigits: 0)
        #expect(flow.draft.amountText == "800")
        flow.updateAmountText("800.5", decimalSeparator: ".", fractionDigits: 0)
        #expect(flow.draft.amountText == "800")
    }
}
