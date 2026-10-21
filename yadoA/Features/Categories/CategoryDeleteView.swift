import SwiftUI

/// 删除有流水的分类时，用户在这里选择：把流水移到其他分类，或一并删除流水。
///
/// 标题和选项直接写明受影响的流水笔数；默认选「移到其他分类」并预选「其他」，
/// 底部按钮的文案随选择变化，删除流水前再确认一次，让用户在点下去之前就知道会发生什么。
struct CategoryDeleteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    /// 删除请求：被删除的分类与对流水的影响。
    let request: CategoryDeletionRequest

    /// 可选的迁移目标：同方向、未删除、不含被删除分类本身。
    let targets: [BookkeepingCategoryItem]

    /// 用户确认后的回调，参数为流水的处理方式。
    let onConfirm: (CategoryTransactionDisposition) -> Void

    /// 流水是否一并删除；默认迁移，保留数据。
    @State private var deletesTransactions = false

    /// 当前选中的迁移目标 key，默认「其他」。
    @State private var targetKey = BookkeepingCategoryKey.other

    /// 是否正在二次确认删除流水。
    @State private var isConfirmingTransactionDeletion = false

    /// 流水笔数。
    private var count: Int { request.impact.transactionCount }

    var body: some View {
        List {
            Section {
                choiceRow(
                    deletesTransactions: false,
                    title: text("category.delete.choice.migrate"),
                    detail: text("category.delete.choice.migrate.detail"),
                    isEnabled: true,
                    seed: 480
                )
                choiceRow(
                    deletesTransactions: true,
                    title: text("category.delete.choice.delete"),
                    detail: deleteChoiceDetail,
                    isEnabled: request.impact.canDeleteTransactions,
                    seed: 481
                )
            } header: {
                sectionHeader(format("category.delete.choice.header", count), seed: 479)
            }

            if !deletesTransactions {
                Section {
                    ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                        targetRow(target, isLast: index == targets.count - 1, seed: 500 + UInt64(index))
                    }
                } header: {
                    sectionHeader(text("category.delete.migration.header"), seed: 499)
                } footer: {
                    Text(format("category.delete.migration.footer", request.item.title(locale: locale)))
                }
            }
        }
        .animation(.default, value: deletesTransactions)
        .paperPage()
        .navigationTitle(format("category.delete.confirm.title", request.item.title(locale: locale)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(text("common.cancel")) { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            confirmButton
        }
        .confirmationDialog(
            format("category.delete.transactions.alert.title", count),
            isPresented: $isConfirmingTransactionDeletion,
            titleVisibility: .visible
        ) {
            Button(text("category.delete.action"), role: .destructive) {
                finish(.delete)
            }
            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(text("category.delete.transactions.alert.message"))
        }
    }

    /// 「一并删除流水」的说明；有停用账户的流水时说明为什么不能选。
    private var deleteChoiceDetail: String {
        request.impact.canDeleteTransactions
            ? text("category.delete.choice.delete.detail")
            : format("category.delete.choice.delete.locked", request.impact.inactiveAccountTransactionCount)
    }

    /// 底部主按钮：迁移时写「移动并删除」，删除流水时写明会删掉几笔流水。
    private var confirmButton: some View {
        Button(role: .destructive) {
            if deletesTransactions {
                isConfirmingTransactionDeletion = true
            } else {
                finish(.migrate(to: targetKey))
            }
        } label: {
            Text(
                deletesTransactions
                    ? format("category.delete.transactions.confirm", count)
                    : text("category.delete.migration.confirm")
            )
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .modifier(CategoryProminentButtonStyle())
        .tint(Color(.ledgerRed))
        .disabled(!canConfirm)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .accessibilityIdentifier("category-delete-confirm")
    }

    /// 删除流水需要允许删除；迁移需要选中一个有效目标。
    private var canConfirm: Bool {
        deletesTransactions
            ? request.impact.canDeleteTransactions
            : targets.contains { $0.key == targetKey }
    }

    /// 一个处理方式选项；选中的那个在行首显示实心圆点。
    private func choiceRow(
        deletesTransactions value: Bool,
        title: String,
        detail: String,
        isEnabled: Bool,
        seed: UInt64
    ) -> some View {
        let isSelected = deletesTransactions == value
        return Button {
            deletesTransactions = value
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(value ? "category-delete-option-delete" : "category-delete-option-migrate")
        .ledgerRow(seed: seed, showsRule: !value)
    }

    /// 单个迁移目标；选中的那个在行尾打勾。
    private func targetRow(_ target: BookkeepingCategoryItem, isLast: Bool, seed: UInt64) -> some View {
        let isSelected = target.key == targetKey
        return Button {
            targetKey = target.key
        } label: {
            HStack {
                CategoryRowLabel(item: target, subtitle: nil, showsChevron: false)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("category-migration-target-\(target.key)")
        .ledgerRow(seed: seed, showsRule: !isLast)
    }

    /// 分组标题，沿用管理页的衬线标题样式。
    private func sectionHeader(_ title: String, seed: UInt64) -> some View {
        Text(title)
            .font(.system(.headline, design: .serif))
            .foregroundStyle(.primary)
            .ledgerHeadingRule(seed: seed)
    }

    /// 交给管理页执行删除，并关闭本页。
    private func finish(_ disposition: CategoryTransactionDisposition) {
        onConfirm(disposition)
        dismiss()
    }

    /// 按当前应用语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }

    /// 解析带参数的 String Catalog 文案。
    private func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}

/// 分类页底部主按钮：iOS 26 使用 Liquid Glass，iOS 18 降级为系统强调按钮。
struct CategoryProminentButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}
