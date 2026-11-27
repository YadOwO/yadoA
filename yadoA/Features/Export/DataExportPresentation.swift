import SwiftUI
import UIKit

/// 导出流程的统一界面：确认弹窗、失败提示和系统分享面板。
///
/// 账户管理页和设置页的导出入口、账户页的备份提醒卡片共用它，保证确认文案、重试和分享行为一致。
struct DataExportPresentation: ViewModifier {
    @Environment(\.locale) private var locale

    /// 被呈现界面所属的导出流程。
    @ObservedObject var flow: DataExportFlow

    /// 是否正在显示导出确认弹窗；由触发导出的按钮置为 `true`。
    @Binding var isPresentingConfirmation: Bool

    func body(content: Content) -> some View {
        content
            .alert(
                AccountLocalization.string(
                    "account.management.export.warning.title",
                    locale: locale
                ),
                isPresented: $isPresentingConfirmation
            ) {
                Button(
                    AccountLocalization.string(
                        "account.management.export.title",
                        locale: locale
                    )
                ) {
                    flow.startExport()
                }
                .accessibilityIdentifier("account-management-export-confirm")

                Button(
                    AccountLocalization.string("common.cancel", locale: locale),
                    role: .cancel
                ) {}
                .accessibilityIdentifier("account-management-export-cancel")
            } message: {
                Text(
                    AccountLocalization.string(
                        "account.management.export.warning.message",
                        locale: locale
                    )
                )
            }
            .alert(
                AccountLocalization.string("account.management.export.error", locale: locale),
                isPresented: failurePresented
            ) {
                Button(AccountLocalization.string("common.retry", locale: locale)) {
                    flow.retry()
                }

                Button(
                    AccountLocalization.string("common.close", locale: locale),
                    role: .cancel
                ) {
                    flow.dismissFailure()
                }
            }
            .sheet(item: shareItemBinding, onDismiss: flow.finishSharing) { item in
                DataExportShareSheet(url: item.url, onCompleted: flow.markShareCompleted)
            }
    }

    /// 将状态机中的失败状态转换为系统 Alert 的布尔绑定。
    private var failurePresented: Binding<Bool> {
        Binding(
            get: { flow.failure != nil },
            set: { isPresented in
                if !isPresented {
                    flow.dismissFailure()
                }
            }
        )
    }

    /// 将状态机中的分享 URL 转换为 `.sheet(item:)` 所需的可选绑定。
    private var shareItemBinding: Binding<DataExportShareItem?> {
        Binding(
            get: { flow.shareItem },
            set: { _ in }
        )
    }
}

extension View {
    /// 给触发导出的视图挂上统一的确认弹窗、失败提示和分享面板。
    ///
    /// - Parameters:
    ///   - flow: 这个入口持有的导出流程。
    ///   - isPresentingConfirmation: 是否显示导出确认弹窗。
    func dataExportPresentation(
        flow: DataExportFlow,
        isPresentingConfirmation: Binding<Bool>
    ) -> some View {
        modifier(
            DataExportPresentation(
                flow: flow,
                isPresentingConfirmation: isPresentingConfirmation
            )
        )
    }
}

/// 以系统 UIKit 分享面板呈现备份文件，支持保存到 Files 或分享给其他目标。
private struct DataExportShareSheet: UIViewControllerRepresentable {
    /// 已生成的备份文件地址。
    let url: URL

    /// 用户真正存好或发出文件时调用；点了取消或在文件选择器里取消不会调用。
    let onCompleted: () -> Void

    /// 创建系统分享面板，并在系统报告「已完成」时通知调用方。
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        let onCompleted = onCompleted
        controller.completionWithItemsHandler = { _, completed, _, _ in
            guard completed else { return }
            Task { @MainActor in onCompleted() }
        }
        return controller
    }

    /// 分享面板无须在 SwiftUI 状态变化时更新内容。
    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
