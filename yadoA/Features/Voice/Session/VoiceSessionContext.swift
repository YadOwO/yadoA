import Foundation
import SwiftData

/// 每一步请求都要带上的本地上下文：账户、分类、默认记账账户。
///
/// 每一步都从存储重新读取，会话期间在别处改了账户或分类也能立即生效。
struct VoiceSessionContext: Equatable {
    /// 全部账户，启用在前，最多 50 个。
    let accounts: [VoiceAccountOption]

    /// 未删除的分类，按展示顺序，最多 100 个。
    let categories: [VoiceCategoryOption]

    /// 当前有效的默认记账账户。
    let defaultAccountID: String?

    /// 读取当前上下文。
    ///
    /// - Parameters:
    ///   - container: 应用持有的本地财务容器。
    ///   - locale: 分类名称使用的语言环境。
    /// - Returns: 读取失败的部分按空处理，交由服务端追问或提示。
    static func make(container: ModelContainer, locale: Locale) -> VoiceSessionContext {
        let context = container.makeManualSaveContext()
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\Account.createdAt)]))) ?? []
        let preference = try? context.canonicalBookkeepingPreference()
        let catalog = VoiceToolExecutor.catalog(in: context)

        // 停用账户也要发送，用于识别查询结果中的历史流水；超出上限时优先保留启用账户
        let sortedAccounts = accounts.filter(\.isActive) + accounts.filter { !$0.isActive }
        let accountOptions = sortedAccounts.prefix(VoiceSessionLimits.maxAccounts).compactMap { account -> VoiceAccountOption? in
            let name = String(account.name.prefix(VoiceSessionLimits.maxOptionNameLength))
            let type = String(account.typeRawValue.prefix(VoiceSessionLimits.maxAccountTypeLength))
            // 名称或类型为空的是损坏数据，不符合契约，不发送
            guard !name.isEmpty, !type.isEmpty else { return nil }
            return VoiceAccountOption(
                id: account.id.uuidString,
                name: name,
                // 只有可记账的 CNY 账户才能新增或改入流水
                isActive: account.supportsBookkeeping && account.currencyCode == "CNY",
                type: type,
                balance: balanceString(account.balance)
            )
        }
        let categoryOptions = BookkeepingEntryType.allCases.flatMap { direction in
            catalog.items(for: direction).map { item in
                VoiceCategoryOption(
                    id: item.key,
                    name: String(item.title(locale: locale).prefix(VoiceSessionLimits.maxOptionNameLength)),
                    type: VoiceEntryType(direction)
                )
            }
        }
        .filter { !$0.name.isEmpty }
        .prefix(VoiceSessionLimits.maxCategories)

        let defaultAccountID = BookkeepingPreference.resolvedAccountID(preference: preference, accounts: accounts)
        return VoiceSessionContext(
            accounts: Array(accountOptions),
            categories: Array(categoryOptions),
            defaultAccountID: defaultAccountID?.uuidString
        )
    }

    /// 提供给语音识别的专有名词：启用账户与分类的名称，提高「招行卡」「微信」等的识别率。
    var contextualStrings: [String] {
        accounts.filter(\.isActive).map(\.name) + categories.map(\.name)
    }

    /// 把账户余额转为契约中带符号、最多两位小数的十进制字符串。
    ///
    /// 本地余额本应只有两位小数，这里仍先四舍五入，避免异常数据让整个请求不合契约。
    static func balanceString(_ balance: Decimal) -> String {
        var source = balance
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 2, .plain)
        return VoiceToolExecutor.amountString(rounded)
    }

    /// 契约中的界面语言：中文界面为 `zh-Hans`，其余为 `en`。
    static func localeCode(for locale: Locale) -> String {
        locale.language.languageCode == .chinese ? "zh-Hans" : "en"
    }

    /// 带时区偏移的 ISO 8601 时刻；服务端取前 10 位作为用户本地的今天。
    static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
