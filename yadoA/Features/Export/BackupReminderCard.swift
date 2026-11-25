import SwiftData
import SwiftUI

/// 账户页顶部的备份提醒卡片：提示账本只存在本机，并提供「现在备份」和「以后再说」。
///
/// 是否显示由调用方用 `BackupReminderPolicy` 判断，卡片自身只负责呈现和触发动作。
/// 「现在备份」走和导出入口完全相同的确认弹窗、`DataExportFlow` 和分享面板；
/// 备份真正完成后调用方的判断条件不再成立，卡片随之消失。
struct BackupReminderCard: View {
    @Environment(\.locale) private var locale
    @StateObject private var flow: DataExportFlow
    @State private var isPresentingConfirmation = false

    /// 点「以后再说」时的处理，由调用方记录暂缓截止时间。
    private let onLater: () -> Void

    /// 使用当前应用容器创建导出流程；流程初始化时清扫上次残留文件，与导出入口一致。
    ///
    /// - Parameters:
    ///   - container: 当前本地财务容器。
    ///   - onLater: 用户点「以后再说」时调用。
    init(container: ModelContainer, onLater: @escaping () -> Void) {
        _flow = StateObject(
            wrappedValue: DataExportFlow(
                service: BackupExportService(container: container)
            )
        )
        self.onLater = onLater
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(AccountLocalization.string("backup.reminder.message", locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)

                // List 行里的按钮必须都显式设样式，否则整行会被当成一个按钮，点一下两个动作一起触发。
                HStack(spacing: 12) {
                    Button {
                        isPresentingConfirmation = true
                    } label: {
                        Text(AccountLocalization.string("backup.reminder.backup_now", locale: locale))
                    }
                    .buttonStyle(.bordered)
                    .disabled(flow.isPreparing)
                    .accessibilityIdentifier("account-list-backup-reminder-backup")

                    Button {
                        onLater()
                    } label: {
                        Text(AccountLocalization.string("backup.reminder.later", locale: locale))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("account-list-backup-reminder-later")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-list-backup-reminder")
        .dataExportPresentation(flow: flow, isPresentingConfirmation: $isPresentingConfirmation)
    }
}
