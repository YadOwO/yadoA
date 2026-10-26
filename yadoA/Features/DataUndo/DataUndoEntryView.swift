import SwiftData
import SwiftUI

/// “撤销上次恢复 / 清除”入口及其确认、失败和完成反馈。
///
/// 只有存在保留期内的快照时才显示；没有可撤销内容时整行（含分隔线）不占位。
struct DataUndoEntryView<Divider: View>: View {
    @Environment(\.locale) private var locale

    /// 当前应用容器对应的撤销服务。
    private let service: DataUndoService

    /// 显示在本行上方的分隔线，随本行一起显隐。
    private let divider: Divider

    /// 当前可撤销的快照；为 `nil` 时入口隐藏。
    @State private var snapshot: DataUndoSnapshot?
    /// 等待用户确认的快照。
    @State private var pendingSnapshot: DataUndoSnapshot?
    /// 刚完成撤销的操作类型，用于完成提示。
    @State private var completedOperation: DataUndoOperation?
    /// 撤销失败的原因，用于失败提示。
    @State private var failure: DataUndoError?

    /// 使用当前应用容器创建入口。
    ///
    /// - Parameters:
    ///   - container: 当前应用容器。
    ///   - divider: 显示在本行上方的分隔线。
    init(container: ModelContainer, @ViewBuilder divider: () -> Divider) {
        service = DataUndoService(container: container)
        self.divider = divider()
    }

    var body: some View {
        // 必须用真实容器而不是 Group：内容为空时 Group 上的 onAppear 不会触发，
        // 重新进入页面就读不到已有快照。
        VStack(spacing: 0) {
            if let snapshot {
                divider

                Button {
                    pendingSnapshot = snapshot
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(text(Self.titleKey(for: snapshot.operation)))
                            Text(deadline(for: snapshot))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                }
                .accessibilityIdentifier("profile-undo-data")
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .dataUndoSnapshotDidChange)) { _ in
            reload()
        }
        .alert(
            text(Self.confirmTitleKey(for: pendingSnapshot?.operation ?? .restore)),
            isPresented: isPresented($pendingSnapshot),
            presenting: pendingSnapshot
        ) { _ in
            Button(text("profile.undo.confirm.action"), role: .destructive) {
                undo()
            }
            .accessibilityIdentifier("profile-undo-confirm")

            Button(text("common.cancel"), role: .cancel) {}
                .accessibilityIdentifier("profile-undo-cancel")
        } message: { snapshot in
            Text(confirmationMessage(for: snapshot))
        }
        .alert(
            text("profile.undo.success.title"),
            isPresented: isPresented($completedOperation),
            presenting: completedOperation
        ) { _ in
            Button(text("common.done")) {}
                .accessibilityIdentifier("profile-undo-done")
        } message: { operation in
            Text(text(Self.successMessageKey(for: operation)))
        }
        .alert(
            text("profile.undo.error.title"),
            isPresented: isPresented($failure),
            presenting: failure
        ) { _ in
            Button(text("common.close"), role: .cancel) {}
        } message: { error in
            Text(failureMessage(for: error))
        }
    }

    /// 重新读取可用快照；过期快照在读取时被清理，入口随之隐藏。
    private func reload() {
        snapshot = service.availableSnapshot()
    }

    /// 用户确认后执行撤销，并按结果展示完成或失败提示。
    private func undo() {
        guard let operation = pendingSnapshot?.operation else { return }
        do {
            try service.undo()
            AppHaptics.play(.restore)
            completedOperation = operation
        } catch {
            AppHaptics.play(.error)
            failure = error as? DataUndoError ?? .undoFailed
        }
        reload()
    }

    /// 把可选状态转换为系统 Alert 的布尔绑定；关闭提示即清空该状态。
    private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { if !$0 { value.wrappedValue = nil } }
        )
    }

    /// 入口副标题：最晚可以撤销到哪一天。
    private func deadline(for snapshot: DataUndoSnapshot) -> String {
        String(
            format: text("profile.undo.deadline"),
            locale: locale,
            snapshot.expiresAt.formatted(
                Date.FormatStyle().month(.abbreviated).day().locale(locale)
            )
        )
    }

    /// 确认提示正文：撤销后会回来多少数据，以及之后的改动会丢失。
    private func confirmationMessage(for snapshot: DataUndoSnapshot) -> String {
        let key = switch snapshot.operation {
        case .restore: "profile.undo.confirm.message.restore"
        case .reset: "profile.undo.confirm.message.reset"
        }
        return String(
            format: text(key),
            locale: locale,
            snapshot.accountCount,
            snapshot.transactionCount
        )
    }

    /// 失败提示正文：过期与还原失败分开说明。
    private func failureMessage(for error: DataUndoError) -> String {
        switch error {
        case .nothingToUndo:
            String(format: text("profile.undo.error.expired"), locale: locale, DataUndoPolicy.retentionDays)
        case .snapshotFailed, .undoFailed:
            text("profile.undo.error.failed")
        }
    }

    /// 入口标题键：按上次操作类型区分。
    private static func titleKey(for operation: DataUndoOperation) -> String {
        switch operation {
        case .restore: "profile.undo.title.restore"
        case .reset: "profile.undo.title.reset"
        }
    }

    /// 确认提示标题键。
    private static func confirmTitleKey(for operation: DataUndoOperation) -> String {
        switch operation {
        case .restore: "profile.undo.confirm.title.restore"
        case .reset: "profile.undo.confirm.title.reset"
        }
    }

    /// 完成提示正文键。
    private static func successMessageKey(for operation: DataUndoOperation) -> String {
        switch operation {
        case .restore: "profile.undo.success.message.restore"
        case .reset: "profile.undo.success.message.reset"
        }
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
