import SwiftData
import SwiftUI

/// “清除所有数据”入口及其破坏性确认、失败和完成反馈；清除前会留下可撤销的快照。
///
/// 账本本来就是空的时候不进入确认流程，直接提示没有数据可以清除。
struct DataResetEntryView: View {
    @Environment(\.locale) private var locale

    /// 当前应用容器；确认后才创建清除服务。
    private let container: ModelContainer

    @State private var isPresentingConfirmation = false
    @State private var isPresentingSuccess = false
    @State private var isPresentingFailure = false
    /// 账本为空时点击入口展示的“没有数据”提示。
    @State private var isPresentingEmpty = false
    /// 本次清除是否留下了可撤销的快照；账本原本为空时没有。
    @State private var canUndoReset = false

    /// 使用当前应用容器创建入口。
    init(container: ModelContainer) {
        self.container = container
    }

    var body: some View {
        Button {
            beginReset()
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
            Text(retentionText("profile.reset.confirm.message"))
        }
        .alert(text("profile.reset.success.title"), isPresented: $isPresentingSuccess) {
            Button(text("common.done")) {}
                .accessibilityIdentifier("profile-reset-done")
        } message: {
            if canUndoReset {
                Text(retentionText("profile.reset.success.message"))
            }
        }
        .alert(text("profile.reset.error"), isPresented: $isPresentingFailure) {
            Button(text("common.close"), role: .cancel) {}
        }
        .alert(text("profile.reset.empty.title"), isPresented: $isPresentingEmpty) {
            Button(text("common.close"), role: .cancel) {}
                .accessibilityIdentifier("profile-reset-empty-close")
        } message: {
            Text(text("profile.reset.empty.message"))
        }
    }

    /// 点击入口：有数据才进入破坏性确认，没有数据直接说明无需清除。
    private func beginReset() {
        // 读不出数量时按有数据处理，交给确认后的清除流程报告失败。
        let hasData = (try? LocalDataResetService(container: container).hasData()) ?? true
        if hasData {
            isPresentingConfirmation = true
        } else {
            isPresentingEmpty = true
        }
    }

    /// 用户确认后执行清除，并按结果展示完成或失败提示。
    private func eraseAll() {
        do {
            // 清除前先存一份撤销快照；快照存不下来就不清除，现有数据保持原样。
            let undoService = DataUndoService(container: container)
            try undoService.perform(.reset) {
                try LocalDataResetService(container: container).eraseAll()
            }
            canUndoReset = undoService.availableSnapshot()?.operation == .reset
            isPresentingSuccess = true
        } catch {
            isPresentingFailure = true
        }
    }

    /// 解析带撤销保留天数占位符的文案。
    private func retentionText(_ key: String) -> String {
        String(format: text(key), locale: locale, DataUndoPolicy.retentionDays)
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
