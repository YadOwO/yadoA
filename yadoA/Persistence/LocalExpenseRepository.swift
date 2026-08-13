import Foundation
import SwiftData

/// 本地餐饮支出写入边界产生的错误。
enum ExpenseRepositoryError: Error, Equatable {
    /// 相同流水 UUID 已经存在，拒绝覆盖或再次联动账户金额。
    case duplicateID(UUID)

    /// 草稿绑定的账户不存在。
    case accountNotFound(UUID)

    /// 持久化账户类型未知，无法安全判断金额影响方向。
    case unsupportedAccountType(String)

    /// 当前版本仅允许 CNY 账户记录餐饮支出。
    case unsupportedCurrency(String)

    /// 精确十进制金额计算失败。
    case balanceCalculationFailed
}

/// 在主 actor 上原子保存餐饮流水和账户金额变化的本地仓库。
@MainActor
final class LocalExpenseRepository {
    /// 唯一写入 context；关闭自动保存后仅显式保存成功才算完成记账。
    private let modelContext: ModelContext

    /// 测试可注入的保存前故障点；生产环境默认为空操作。
    private let beforeSave: () throws -> Void

    /// 使用应用级容器创建串行写入仓库。
    ///
    /// - Parameters:
    ///   - container: 应用或测试持有的完整本地财务容器。
    ///   - beforeSave: 流水与金额均完成内存修改后、显式保存前执行的故障点。
    convenience init(
        container: ModelContainer,
        beforeSave: @escaping () throws -> Void = {}
    ) {
        self.init(
            modelContext: ModelContext(container),
            beforeSave: beforeSave
        )
    }

    /// 使用仓库独占的 context 创建本地支出写入边界。
    ///
    /// - Parameters:
    ///   - modelContext: 同时管理账户与支出流水的 context。
    ///   - beforeSave: 显式保存前执行的可注入操作。
    private init(
        modelContext: ModelContext,
        beforeSave: @escaping () throws -> Void
    ) {
        modelContext.autosaveEnabled = false
        self.modelContext = modelContext
        self.beforeSave = beforeSave
    }

    /// 校验草稿，并通过一次显式保存同时新增流水和联动账户金额。
    ///
    /// - Parameters:
    ///   - draft: 页面提交时复制的稳定草稿。
    ///   - savedAt: 注入的保存时间，供同日流水排序使用。
    /// - Throws: 流水重复、草稿无效、账户不可用、金额计算或保存失败时抛出错误。
    func save(
        _ draft: DiningExpenseDraft,
        savedAt: Date = .now
    ) throws {
        guard try !containsTransaction(id: draft.id) else {
            throw ExpenseRepositoryError.duplicateID(draft.id)
        }

        let transaction = try ExpenseTransaction.validating(
            draft: draft,
            savedAt: savedAt
        )
        guard let account = try account(id: transaction.accountID) else {
            throw ExpenseRepositoryError.accountNotFound(transaction.accountID)
        }
        guard account.currencyCode == transaction.currencyCode else {
            throw ExpenseRepositoryError.unsupportedCurrency(account.currencyCode)
        }
        guard let accountType = account.accountType else {
            throw ExpenseRepositoryError.unsupportedAccountType(account.typeRawValue)
        }

        let updatedBalance = try Self.updatedBalance(
            account.balance,
            by: transaction.amount,
            effect: accountType.expenseBalanceEffect
        )

        modelContext.insert(transaction)
        account.balance = updatedBalance
        do {
            try beforeSave()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// 获取指定 UUID 的账户。
    private func account(id: UUID) throws -> Account? {
        let accountID = id
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in
                account.id == accountID
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// 判断指定 UUID 的流水是否已经存在，避免实例化无须读取的完整模型。
    private func containsTransaction(id: UUID) throws -> Bool {
        let transactionID = id
        let descriptor = FetchDescriptor<ExpenseTransaction>(
            predicate: #Predicate<ExpenseTransaction> { transaction in
                transaction.id == transactionID
            }
        )
        return try modelContext.fetchCount(descriptor) > 0
    }

    /// 根据账户语义计算支出后的精确金额，并拒绝溢出或精度损失。
    private static func updatedBalance(
        _ balance: Decimal,
        by expenseAmount: Decimal,
        effect: ExpenseBalanceEffect
    ) throws -> Decimal {
        var currentBalance = balance
        var amount = expenseAmount
        var result = Decimal()
        let calculationError: Decimal.CalculationError
        switch effect {
        case .decreaseValue:
            calculationError = NSDecimalSubtract(
                &result,
                &currentBalance,
                &amount,
                .plain
            )
        case .increaseDebt:
            calculationError = NSDecimalAdd(
                &result,
                &currentBalance,
                &amount,
                .plain
            )
        }
        guard calculationError == .noError else {
            throw ExpenseRepositoryError.balanceCalculationFailed
        }
        return result
    }
}
