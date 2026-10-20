import SwiftUI

/// 删除有流水的分类前，选择流水迁往哪个分类。
///
/// 标题直接写明受影响的流水笔数，默认选中「其他」，确认按钮写成「移动并删除」，
/// 让用户在点下去之前就知道会发生什么。
struct CategoryDeleteMigrationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    /// 删除请求：被删除的分类与受影响的流水笔数。
    let request: CategoryDeletionRequest

    /// 可选的迁移目标：同方向、未隐藏、不含被删除分类本身。
    let targets: [BookkeepingCategoryItem]

    /// 用户确认后的回调，参数为目标分类 key。
    let onConfirm: (String) -> Void

    /// 当前选中的目标分类 key，默认「其他」。
    @State private var targetKey = BookkeepingCategoryKey.other

    var body: some View {
        List {
            Section {
                ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                    targetRow(target, isLast: index == targets.count - 1, seed: 500 + UInt64(index))
                }
            } header: {
                Text(
                    String(
                        format: text("category.delete.migration.header"),
                        locale: locale,
                        request.transactionCount
                    )
                )
                .font(.system(.headline, design: .serif))
                .foregroundStyle(.primary)
                .ledgerHeadingRule(seed: 499)
            } footer: {
                Text(
                    String(
                        format: text("category.delete.migration.footer"),
                        locale: locale,
                        request.item.title(locale: locale)
                    )
                )
            }
        }
        .paperPage()
        .navigationTitle(
            String(format: text("category.delete.confirm.title"), locale: locale, request.item.title(locale: locale))
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(text("common.cancel")) { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(role: .destructive) {
                onConfirm(targetKey)
                dismiss()
            } label: {
                Text(text("category.delete.migration.confirm"))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .modifier(CategoryProminentButtonStyle())
            .tint(Color(.ledgerRed))
            .disabled(!targets.contains { $0.key == targetKey })
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityIdentifier("category-migration-confirm")
        }
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

    /// 按当前应用语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
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
