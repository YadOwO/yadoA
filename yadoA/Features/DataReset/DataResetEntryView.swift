import SwiftData
import SwiftUI

/// “清除所有数据”入口及其破坏性确认、失败和完成反馈。
struct DataResetEntryView: View {
    @Environment(\.locale) private var locale

    /// 当前应用容器；确认后才创建清除服务。
    private let container: ModelContainer

    @State private var isPresentingConfirmation = false
    @State private var isPresentingSuccess = false
    @State private var isPresentingFailure = false

    /// 使用当前应用容器创建入口。
    init(container: ModelContainer) {
        self.container = container
    }

    var body: some View {
        Button {
            isPresentingConfirmation = true
        } label: {
            Label(text("profile.reset.title"), systemImage: "trash")
        }
        .accessibilityIdentifier("profile-reset-data")
        .alert(text("profile.reset.confirm.title"), isPresented: $isPresentingConfirmation) {
            Button(text("profile.reset.confirm.action"), role: .destructive) {
                eraseAll()
            }
            .accessibilityIdentifier("profile-reset-confirm")

            Button(text("common.cancel"), role: .cancel) {}
                .accessibilityIdentifier("profile-reset-cancel")
        } message: {
            Text(text("profile.reset.confirm.message"))
        }
        .alert(text("profile.reset.success.title"), isPresented: $isPresentingSuccess) {
            Button(text("common.done")) {}
                .accessibilityIdentifier("profile-reset-done")
        }
        .alert(text("profile.reset.error"), isPresented: $isPresentingFailure) {
            Button(text("common.close"), role: .cancel) {}
        }
    }

    /// 用户确认后执行清除，并按结果展示完成或失败提示。
    private func eraseAll() {
        do {
            try LocalDataResetService(container: container).eraseAll()
            isPresentingSuccess = true
        } catch {
            isPresentingFailure = true
        }
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
