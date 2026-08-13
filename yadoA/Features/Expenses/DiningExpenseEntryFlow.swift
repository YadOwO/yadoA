import Combine
import Foundation

/// 记账页面注入的显式保存动作。
typealias DiningExpenseSaveAction = @MainActor (DiningExpenseDraft) async throws -> Void

/// 餐饮支出提交期间的页面状态。
enum DiningExpenseSubmissionState: Equatable {
    case editing
    case saving
    case failed
}

/// 持有单份餐饮支出草稿，并协调金额输入与防重复提交。
@MainActor
final class DiningExpenseEntryFlow: ObservableObject {
    /// 页面及其后续账户子流程共享的同一份草稿。
    @Published private(set) var draft: DiningExpenseDraft

    /// 当前提交状态；失败时保留草稿供用户继续修改或重试。
    @Published private(set) var submissionState: DiningExpenseSubmissionState = .editing

    /// 记账日期使用的公历，仅在界面边界转换年月日。
    private let calendar: Calendar

    /// 由上层注入的本地持久化动作。
    private let saveAction: DiningExpenseSaveAction

    /// 创建一条带稳定 UUID 的餐饮支出流程。
    ///
    /// - Parameters:
    ///   - draft: 需要恢复的既有草稿；为空时以今天创建新草稿。
    ///   - now: 新草稿的默认记账日期。
    ///   - calendar: 提供当前时区的日历，内部统一转换为公历。
    ///   - saveAction: 显式保存餐饮流水与账户金额的动作。
    init(
        draft: DiningExpenseDraft? = nil,
        now: Date = .now,
        calendar: Calendar = .current,
        saveAction: @escaping DiningExpenseSaveAction
    ) {
        let gregorianCalendar = Self.gregorianCalendar(basedOn: calendar)
        self.calendar = gregorianCalendar
        self.saveAction = saveAction
        self.draft = draft ?? DiningExpenseDraft(
            transactionDay: Self.transactionDay(for: now, calendar: gregorianCalendar)
        )
    }

    /// 当前是否正在保存，用于忽略重复完成操作。
    var isSaving: Bool {
        submissionState == .saving
    }

    /// 最近一次保存是否失败。
    var hasSaveError: Bool {
        submissionState == .failed
    }

    /// 草稿是否已经具备有效金额和账户选择。
    var canSubmit: Bool {
        draft.amount != nil && draft.accountID != nil && !isSaving
    }

    /// 金额区域展示的字符；空草稿使用零作为视觉占位。
    var displayedAmount: String {
        draft.amountText.isEmpty ? "0" : draft.amountText
    }

    /// 当前 `YYYYMMDD` 草稿值对应的公历日期。
    var transactionDate: Date {
        let year = draft.transactionDay / 10_000
        let month = draft.transactionDay / 100 % 100
        let day = draft.transactionDay % 100
        let components = DateComponents(year: year, month: month, day: day)
        return calendar.date(from: components) ?? calendar.startOfDay(for: .now)
    }

    /// 追加一位数字，且小数点后最多保留两位。
    func appendDigit(_ digit: Int) {
        guard !isSaving, (0...9).contains(digit) else { return }

        var amountText = draft.amountText
        if let decimalPoint = amountText.firstIndex(of: ".") {
            let fractionalDigits = amountText.distance(from: amountText.index(after: decimalPoint), to: amountText.endIndex)
            guard fractionalDigits < 2 else { return }
        }

        if amountText == "0" {
            guard digit != 0 else { return }
            amountText = String(digit)
        } else {
            amountText.append(String(digit))
        }
        updateAmountText(amountText)
    }

    /// 追加唯一的小数点；空金额会先补零。
    func appendDecimalPoint() {
        guard !isSaving, !draft.amountText.contains(".") else { return }
        updateAmountText(draft.amountText.isEmpty ? "0." : draft.amountText + ".")
    }

    /// 删除金额缓冲区中的最后一个字符。
    func deleteBackward() {
        guard !isSaving, !draft.amountText.isEmpty else { return }
        var amountText = draft.amountText
        amountText.removeLast()
        updateAmountText(amountText)
    }

    /// 更新可选备注，并在编辑后清除上一次失败提示。
    func updateNote(_ note: String) {
        guard !isSaving else { return }
        draft.note = note
        markAsEditing()
    }

    /// 更新记账日期，仅把公历年月日写回草稿。
    func updateTransactionDate(_ date: Date) {
        guard !isSaving else { return }
        draft.transactionDay = Self.transactionDay(for: date, calendar: calendar)
        markAsEditing()
    }

    /// 回填唯一账户 UUID，不重建金额、日期或备注等其他草稿字段。
    func selectAccount(id: UUID?) {
        guard !isSaving else { return }
        draft.accountID = id
        markAsEditing()
    }

    /// 复制当前草稿并执行一次显式保存；失败时原草稿保持不变。
    ///
    /// - Parameter onSaved: 仅在持久化成功后调用的返回动作。
    func submit(onSaved: @escaping @MainActor () -> Void) async {
        guard canSubmit else { return }

        let submittedDraft = draft
        submissionState = .saving
        do {
            try await saveAction(submittedDraft)
            submissionState = .editing
            onSaved()
        } catch {
            submissionState = .failed
        }
    }

    /// 替换金额字符并清除上一次失败提示。
    private func updateAmountText(_ amountText: String) {
        draft.amountText = amountText
        markAsEditing()
    }

    /// 用户修改草稿后回到可提交状态。
    private func markAsEditing() {
        if submissionState == .failed {
            submissionState = .editing
        }
    }

    /// 复用调用方时区并把日历标识统一为公历。
    private static func gregorianCalendar(basedOn source: Calendar) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = source.locale
        calendar.timeZone = source.timeZone
        return calendar
    }

    /// 把公历日期转换为不含时区语义的 `YYYYMMDD` 整数。
    private static func transactionDay(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 1970) * 10_000
            + (components.month ?? 1) * 100
            + (components.day ?? 1)
    }
}
