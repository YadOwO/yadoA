import SwiftData
import SwiftUI

/// 账户分类排序页：拖动调整分类顺序，账户页和各处选择账户时都按这个顺序排列。
///
/// 页面打开即处于拖动状态；每次拖动后立即保存，没有单独的保存按钮。
struct AccountTypeOrderView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Query private var queriedAccounts: [Account]
    @Query private var preferences: [BookkeepingPreference]

    /// 最近一次保存是否失败。
    @State private var isSaveFailed = false

    var body: some View {
        let order = AccountDisplayOrder(preferences: preferences)
        let accountTypes = order.accountTypes

        List {
            Section {
                ForEach(Array(accountTypes.enumerated()), id: \.element) { index, accountType in
                    row(accountType)
                        .ledgerRow(seed: 330 + UInt64(index), showsRule: index != accountTypes.count - 1)
                        .accessibilityIdentifier("account-type-order-row-\(accountType.rawValue)")
                }
                .onMove { source, destination in
                    var reordered = accountTypes
                    reordered.move(fromOffsets: source, toOffset: destination)
                    save(AccountDisplayOrder(accountTypes: reordered))
                }
            } footer: {
                Text(text("account.type_order.footer"))
            }
        }
        .contentMargins(.top, 4, for: .scrollContent)
        // 这一页只用来排序，打开即可拖动。
        .environment(\.editMode, .constant(.active))
        .animation(.default, value: accountTypes)
        .paperPage()
        .navigationTitle(text("account.type_order.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(text("account.type_order.reset")) {
                    save(.default)
                }
                .disabled(order == .default)
                .accessibilityIdentifier("account-type-order-reset")
            }
        }
        .alert(text("account.type_order.save_error"), isPresented: $isSaveFailed) {
            Button(text("common.close"), role: .cancel) {}
        }
    }

    /// 一个分类：图标、名称、包含哪些账户的说明，以及该分类下启用账户的数量。
    private func row(_ accountType: AccountType) -> some View {
        let count = queriedAccounts.count { $0.isActive && $0.accountType == accountType }
        return HStack(spacing: 12) {
            Image(systemName: accountType.symbolName)
                .font(.body)
                .foregroundStyle(accountType.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(accountType.title(locale: locale))
                    .foregroundStyle(.primary)
                if let note = note(for: accountType) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if count > 0 {
                Text(count.formatted())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// 分类名下面的一行说明，告诉用户这个分类里有哪些账户；没有说明的分类（现金、储蓄卡、自定义资产）为 nil。
    ///
    /// 虚拟账户单独写明微信、支付宝：新建账户时它俩是单独的快捷入口，用户不知道排序时要拖「虚拟账户」。
    /// 新建页里虚拟账户的说明是「其他电子钱包」，因为微信、支付宝已经列在旁边，这里不能照搬。
    ///
    /// - Parameter accountType: 要说明的分类。
    private func note(for accountType: AccountType) -> String? {
        if accountType == .virtualAccount {
            return text("account.type_order.virtualAccount.note")
        }
        return accountType.subtitle(locale: locale)
    }

    /// 写入新的分类顺序，失败时提示。
    private func save(_ order: AccountDisplayOrder) {
        do {
            try LocalAccountRepository(container: modelContext.container).saveAccountTypeOrder(order)
        } catch {
            AppHaptics.play(.error)
            isSaveFailed = true
        }
    }

    /// 按当前应用语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview {
    NavigationStack {
        AccountTypeOrderView()
    }
    .modelContainer(try! AccountDataContainer.inMemory().modelContainer)
}
