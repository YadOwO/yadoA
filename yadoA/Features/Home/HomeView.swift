import SwiftUI

/// 首页入口；当前先承载财务总览占位，后续首页能力在此继续扩展。
struct HomeView: View {
    @Environment(\.locale) private var locale

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
        }
    }
}

#Preview {
    HomeView()
}
