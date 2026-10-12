import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 从 yadoA 备份文件恢复数据的入口及其选择、确认、失败和完成反馈。
struct DataImportEntryView: View {
    @Environment(\.locale) private var locale
    @StateObject private var flow: DataImportFlow
    @State private var isPresentingPicker = false

    /// 使用当前应用容器创建恢复流程。
    init(container: ModelContainer) {
        _flow = StateObject(
            wrappedValue: DataImportFlow(
                service: BackupImportService(container: container)
            )
        )
    }

    var body: some View {
        Button {
            #if DEBUG
            // UI 自动化无法稳定驱动系统文件选择器，改为直接载入隔离夹具备份。
            if let fixtureURL = BackupImportUITestFixture.backupFileURL() {
                flow.loadBackup(from: fixtureURL)
                return
            }
            #endif
            isPresentingPicker = true
        } label: {
            Label(text("account.management.import.title"), systemImage: "square.and.arrow.down")
        }
        .accessibilityIdentifier("account-management-import-data")
        .fileImporter(
            isPresented: $isPresentingPicker,
            // 经聊天工具转发的备份可能丢失自定义类型，同时允许普通 JSON。
            allowedContentTypes: [BackupFileType.yadoABackup, .json]
        ) { result in
            switch result {
            case let .success(url):
                flow.loadBackup(from: url)
            case .failure:
                flow.failSelection()
            }
        }
        .alert(
            text("account.management.import.confirm.title"),
            isPresented: isPresented(flow.pendingPlan),
            presenting: flow.pendingPlan
        ) { plan in
            Button(
                text("account.management.import.confirm.action"),
                role: plan.replacesExistingData ? .destructive : nil
            ) {
                flow.confirmRestore()
            }
            .accessibilityIdentifier("account-management-import-confirm")

            Button(text("common.cancel"), role: .cancel) {
                flow.dismiss()
            }
            .accessibilityIdentifier("account-management-import-cancel")
        } message: { plan in
            Text(confirmationMessage(for: plan))
        }
        .alert(
            text("account.management.import.error.title"),
            isPresented: isPresented(flow.failure),
            presenting: flow.failure
        ) { _ in
            Button(text("common.close"), role: .cancel) {
                flow.dismiss()
            }
        } message: { error in
            Text(text(Self.messageKey(for: error)))
        }
        .alert(
            text("account.management.import.success.title"),
            isPresented: isPresented(flow.completedPlan),
            presenting: flow.completedPlan
        ) { _ in
            Button(text("common.done")) {
                flow.dismiss()
            }
            .accessibilityIdentifier("account-management-import-done")
        } message: { plan in
            Text(summary(for: plan))
        }
    }

    /// 将状态机中的可选值转换为系统 Alert 的布尔绑定；关闭提示即回到空闲。
    ///
    /// 只有当前仍处于该提示对应的状态时才复位，避免确认按钮推进状态后
    /// 被系统随后的关闭回调覆盖。
    private func isPresented<Value: Equatable>(_ value: @autoclosure @escaping () -> Value?) -> Binding<Bool> {
        Binding(
            get: { value() != nil },
            set: { isPresented in
                if !isPresented, value() != nil {
                    flow.dismiss()
                }
            }
        )
    }

    /// 确认提示正文：备份摘要；本地已有数据时追加整体替换警告。
    private func confirmationMessage(for plan: BackupImportPlan) -> String {
        guard plan.replacesExistingData else { return summary(for: plan) }
        return summary(for: plan) + "\n\n" + text("account.management.import.confirm.replace_warning")
    }

    /// 备份导出时间与记录数量的本地化摘要。
    private func summary(for plan: BackupImportPlan) -> String {
        String(
            format: text("account.management.import.summary"),
            locale: locale,
            plan.exportedAt.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
            ),
            plan.accountCount,
            plan.transactionCount
        )
    }

    /// 不同失败类别对应的本地化正文键。
    private static func messageKey(for error: BackupImportError) -> String {
        switch error {
        case .fileUnreadable:
            "account.management.import.error.unreadable"
        case .invalidFormat, .invalidContent:
            "account.management.import.error.invalid"
        case .unsupportedVersion:
            "account.management.import.error.unsupported_version"
        case .restoreFailed:
            "account.management.import.error.failed"
        }
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
