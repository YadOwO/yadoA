import SwiftUI

/// 分类图标选择页：按主题分组浏览，顶部搜索栏按中英文关键词实时过滤。
struct CategorySymbolPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    /// 选中的图标，点选后写回并返回上一页。
    @Binding var selection: String?

    /// 搜索栏当前输入的关键词。
    @State private var query = ""

    /// 根据可用宽度自动调整列数。
    private let columns = [
        GridItem(.adaptive(minimum: 56, maximum: 72), spacing: 12)
    ]

    var body: some View {
        let sections = CategorySymbolLibrary.search(query, locale: locale)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.group.localizedTitle(locale: locale))
                            .font(.system(.headline, design: .serif))
                            .accessibilityAddTraits(.isHeader)

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(section.symbols) { symbol in
                                symbolButton(symbol)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(AccountLocalization.string("category.symbol.search.prompt", locale: locale))
        )
        .paperPage()
        .navigationTitle(AccountLocalization.string("category.symbol.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 单个图标；当前选中的涂成实墨色。
    private func symbolButton(_ symbol: CategorySymbol) -> some View {
        let isSelected = symbol.name == selection

        return Button {
            selection = symbol.name
            dismiss()
        } label: {
            Image(systemName: symbol.name)
                .font(.title2.weight(.medium))
                .foregroundStyle(isSelected ? Color(.onAccent) : Color.primary)
                .frame(width: 56, height: 56)
                .background {
                    HandDrawnBlob(seed: symbol.name.handDrawnSeed)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(symbol.keywords.first ?? symbol.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("category-symbol-\(symbol.name)")
    }
}
