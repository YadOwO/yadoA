import SwiftData
import SwiftUI

/// 首页入口；当前先承载财务总览占位，后续首页能力在此继续扩展。
struct HomeView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(
                    AccountLocalization.string("home.overview.title", locale: locale),
                    systemImage: "chart.pie"
                )
            } description: {
                Text(AccountLocalization.string("home.overview.message", locale: locale))
            }
            .navigationTitle(AppTab.home.title(locale: locale))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        DiningExpenseEntryView { draft in
                            let repository = LocalExpenseRepository(
                                container: modelContext.container
                            )
                            try repository.save(draft)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(
                        Text(AccountLocalization.string("expense.entry.action", locale: locale))
                    )
                    .accessibilityIdentifier("home-add-expense")
                }
            }
        }
    }
}

#Preview {
    HomeView()
        .modelContainer(
            for: [Account.self, ExpenseTransaction.self],
            inMemory: true
        )
}
