import SwiftData
import SwiftUI

/// “清除所有数据”入口及其破坏性确认、失败和完成反馈；清除前会留下可撤销的快照。
///
/// 账本本来就是空的时候不进入确认流程，直接提示没有数据可以清除。
/// 本机数据已绑定云端同步时，确认改为二选一：仅清除本机（解除绑定，云端保留），或连同云端一起清除。
struct DataResetEntryView: View {
    @Environment(\.locale) private var locale
    /// 云端同步的绑定与清空流程；预览中没有注入时为 nil，按未开启同步处理。
    @Environment(SyncLifecycle.self) private var syncLifecycle: SyncLifecycle?

    /// 当前应用容器；确认后才创建清除服务。
    private let container: ModelContainer

    @State private var isPresentingConfirmation = false
    /// 已绑定云端同步时，选择清除范围。
    @State private var isPresentingScopeChoice = false
    /// 正在清除（清除云端需要网络），期间禁用入口。
    @State private var isResetting = false
    /// 清除云端数据失败时的文案键；此时本机数据保持原样。
    @State private var syncErrorKey: String?
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
        .disabled(isResetting)
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
        .confirmationDialog(
            text("profile.reset.confirm.title"),
            isPresented: $isPresentingScopeChoice,
            titleVisibility: .visible
        ) {
            Button(text("profile.reset.scope.device"), role: .destructive) {
                Task { await reset(.deviceOnly) }
            }
            .accessibilityIdentifier("profile-reset-device-only")

            Button(text("profile.reset.scope.all"), role: .destructive) {
                Task { await reset(.deviceAndCloud) }
            }
            .accessibilityIdentifier("profile-reset-device-and-cloud")

            Button(text("common.cancel"), role: .cancel) {}
        } message: {
            Text(retentionText("profile.reset.scope.message"))
        }
        .alert(text("profile.reset.error"), isPresented: $isPresentingFailure) {
            Button(text("common.close"), role: .cancel) {}
        }
        .alert(
            text("profile.reset.cloudError"),
            isPresented: Binding(get: { syncErrorKey != nil }, set: { if !$0 { syncErrorKey = nil } })
        ) {
            Button(text("common.close"), role: .cancel) {}
        } message: {
            Text(text(syncErrorKey ?? ""))
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
        guard hasData else {
            isPresentingEmpty = true
            return
        }
        syncLifecycle?.refreshState()
        if syncLifecycle?.state.isBound == true {
            isPresentingScopeChoice = true
        } else {
            isPresentingConfirmation = true
        }
    }

    /// 未绑定云端同步时，用户确认后执行清除，并按结果展示完成或失败提示。
    private func eraseAll() {
        do {
            try eraseWithUndoSnapshot()
            finishReset()
        } catch {
            AppHaptics.play(.error)
            isPresentingFailure = true
        }
    }

    /// 已绑定云端同步时按选择的范围清除。
    ///
    /// - Parameter scope: 仅本机，或本机和云端。
    private func reset(_ scope: SyncResetScope) async {
        guard let syncLifecycle else { return }
        isResetting = true
        defer { isResetting = false }
        do {
            try await syncLifecycle.resetData(scope, eraseLocalData: eraseWithUndoSnapshot)
            finishReset()
        } catch let error as SyncLifecycleError {
            AppHaptics.play(.error)
            if case .api = error {
                syncErrorKey = SyncMessages.localizationKey(forLifecycleError: error)
            } else {
                isPresentingFailure = true
            }
        } catch {
            AppHaptics.play(.error)
            isPresentingFailure = true
        }
    }

    /// 先存一份撤销快照再清除；快照存不下来就不清除，现有数据保持原样。
    private func eraseWithUndoSnapshot() throws {
        try DataUndoService(container: container).perform(.reset) {
            try LocalDataResetService(container: container).eraseAll()
        }
    }

    /// 清除成功后的收尾：清掉最近搜索词，展示完成提示。
    private func finishReset() {
        // 最近搜索词来自已被清除的记账内容，一并清掉；它不属于备份数据，撤销也不会带回来。
        UserDefaults.standard.removeObject(forKey: BookkeepingSearchHistory.storageKey)
        canUndoReset = DataUndoService(container: container).availableSnapshot()?.operation == .reset
        AppHaptics.play(.destructive)
        isPresentingSuccess = true
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
