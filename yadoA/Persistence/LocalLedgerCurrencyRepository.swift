import Foundation
import SwiftData

/// 更换账本币种时产生的错误。
enum LedgerCurrencyRepositoryError: Error, Equatable {
    /// 目标币种不在可选币种里。
    case invalidCurrency(String)
}

/// 在主 actor 上把整个账本换成另一种币种的本地仓库。
///
/// 一个账本一种币，换币种只换符号、不换算金额：所有账户和流水的 `currencyCode` 在一次保存里改成新币种，
/// 同时把选择记在本机（账本为空时靠它决定币种）。保存经 `saveOrRollback` 进入同步台账，开了云同步时会传到其他设备。
@MainActor
final class LocalLedgerCurrencyRepository {
    /// 应用或测试持有的完整本地财务容器；每次保存命令创建新鲜 context。
    private let container: ModelContainer

    /// 保存成功后写入账本币种的本机存储；测试时可注入隔离实例。
    private let defaults: UserDefaults

    /// 测试可注入的保存前故障点；生产环境默认为空操作。
    private let beforeSave: () throws -> Void

    /// 使用应用级容器创建账本币种仓库。
    ///
    /// - Parameters:
    ///   - container: 应用或测试持有的完整本地财务容器。
    ///   - defaults: 保存成功后写入账本币种的本机存储。
    ///   - beforeSave: 全部修改完成后、显式保存前执行的故障点。
    init(
        container: ModelContainer,
        defaults: UserDefaults = .standard,
        beforeSave: @escaping () throws -> Void = {}
    ) {
        self.container = container
        self.defaults = defaults
        self.beforeSave = beforeSave
    }

    /// 把全部账户和流水的币种改成 `code`，金额不换算。
    ///
    /// 账户同时把资料更新时间设为 `now`，让同步知道它改过。已经是新币种的记录不动；
    /// 全部在同一个 context 里一次保存，成功后才写本机存的币种。
    ///
    /// - Parameters:
    ///   - code: 目标币种，必须在 `BookkeepingCurrency.selectableCodes()` 里。
    ///   - now: 注入的账户更新时间，便于确定性测试。
    /// - Throws: 币种不可选抛出 `LedgerCurrencyRepositoryError.invalidCurrency`；读取或保存失败时抛出底层错误，
    ///   此时所有记录整体回滚、本机存的币种也不变。
    func change(to code: String, now: Date = .now) throws {
        guard BookkeepingCurrency.isSelectable(code) else {
            throw LedgerCurrencyRepositoryError.invalidCurrency(code)
        }
        let context = container.makeManualSaveContext()
        do {
            for account in try context.fetch(FetchDescriptor<Account>()) where account.currencyCode != code {
                account.currencyCode = code
                account.updatedAt = now
            }
            for transaction in try context.fetch(FetchDescriptor<AccountTransaction>())
            where transaction.currencyCode != code {
                transaction.currencyCode = code
            }
        } catch {
            context.rollback()
            throw error
        }
        try context.saveOrRollback(beforeSave: beforeSave)
        defaults.set(code, forKey: BookkeepingCurrency.storageKey)
    }
}
