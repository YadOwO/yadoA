import SwiftUI

/// 记账币种选择页，「我的 › 设置 › 记账币种」和首次引导的建账户一步共用。
///
/// 常用币种排在前面，其余 ISO 常用币种按名称排在「全部币种」里；搜索时只显示按代码、名称或符号匹配上的项。
/// 点一行只回传所选代码，由调用方决定要不要关闭页面、要不要确认；页面本身只负责左上角的关闭按钮。
struct LedgerCurrencyPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    /// 当前选中的币种代码，该行打勾。
    let selection: String

    /// 用户点选了某个币种；选中当前币种也会回传。
    let onSelect: (String) -> Void

    /// 搜索栏里的文字。
    @State private var query = ""

    /// 列表里的一行：币种代码、本地化名称和符号。
    private struct Entry: Identifiable {
        /// ISO 4217 货币代码。
        let code: String
        /// 当前语言下的币种名称。
        let name: String
        /// 当前语言下的币种符号。
        let symbol: String

        var id: String { code }

        /// 搜索词是否命中代码、名称或符号。
        func matches(_ query: String) -> Bool {
            code.localizedCaseInsensitiveContains(query)
                || name.localizedCaseInsensitiveContains(query)
                || symbol.localizedCaseInsensitiveContains(query)
        }
    }

    /// 一个分组：标题键和组内的币种。
    private struct EntryGroup: Identifiable {
        /// 分组标题的本地化键。
        let titleKey: String
        /// 组内的币种。
        let entries: [Entry]

        var id: String { titleKey }
    }

    var body: some View {
        let displayedGroups = groups(matching: query.trimmingCharacters(in: .whitespacesAndNewlines))

        NavigationStack {
            List {
                ForEach(displayedGroups) { group in
                    Section(text(group.titleKey)) {
                        ForEach(group.entries) { entry in
                            row(entry)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ledger-currency-list")
            .scrollContentBackground(.hidden)
            // 表单页在宽屏上固定宽度居中，背景照样铺满
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .background(Color(.paperBackground).ignoresSafeArea())
            .navigationTitle(text("settings.currency.title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: text("settings.currency.search"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        // 标题加图标：iPhone Duo 外屏把工具栏竖排在侧边时只有带图标的按钮能竖排
                        Label(text("common.close"), systemImage: "xmark")
                    }
                    .accessibilityIdentifier("ledger-currency-close")
                }
            }
        }
    }

    /// 要显示的分组：没有搜索词时是「常用」和「全部币种」，有搜索词时只留命中的项，空分组不显示。
    private func groups(matching query: String) -> [EntryGroup] {
        let commonCodes = BookkeepingCurrency.commonCodes
        let codes = BookkeepingCurrency.selectableCodes()
        let symbols = BookkeepingCurrency.symbols(for: codes, locale: locale)
        let entries = codes.map {
            Entry(
                code: $0,
                name: BookkeepingCurrency.displayName(for: $0, locale: locale),
                symbol: symbols[$0] ?? $0
            )
        }
        // 常用币种保持 `commonCodes` 的顺序，其余按名称排序
        let common = commonCodes.compactMap { code in entries.first { $0.code == code } }
        let others = entries.filter { !commonCodes.contains($0.code) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let allGroups = [
            EntryGroup(titleKey: "settings.currency.section.common", entries: common),
            EntryGroup(titleKey: "settings.currency.section.all", entries: others)
        ]
        guard !query.isEmpty else { return allGroups }
        return allGroups
            .map { EntryGroup(titleKey: $0.titleKey, entries: $0.entries.filter { $0.matches(query) }) }
            .filter { !$0.entries.isEmpty }
    }

    /// 一行：名称、代码、符号，当前选中的打勾。
    private func row(_ entry: Entry) -> some View {
        let isSelected = entry.code == selection
        return Button {
            onSelect(entry.code)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .foregroundStyle(.primary)
                    Text(entry.code)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(entry.symbol)
                    .foregroundStyle(.secondary)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("ledger-currency-row-\(entry.code)")
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
