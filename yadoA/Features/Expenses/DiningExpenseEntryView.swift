import SwiftData
import SwiftUI
import UIKit

/// 新增记账入口：持有新草稿，页面本身与编辑记账共用 `BookkeepingEntryForm`。
struct DiningExpenseEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Query private var accounts: [Account]
    @Query private var preferences: [BookkeepingPreference]
    @StateObject private var flow: DiningExpenseEntryFlow

    /// 快捷指令传入的临时参考图，不作为流水附件持久化。
    private let screenshot: UIImage?
    /// 外部入口的关闭动作；普通导航录入沿用环境 dismiss。
    private let onFinish: (@MainActor () -> Void)?

    /// 创建支出录入页。
    ///
    /// - Parameters:
    ///   - draft: 可选的既有草稿，默认创建以今天为日期的新草稿。
    ///   - screenshot: 截图入口的参考图片，为空时保持普通记账流程。
    ///   - onFinish: 外部展示容器在取消或保存成功后的收尾动作。
    ///   - save: 上层注入的本地餐饮支出保存动作。
    init(
        draft: DiningExpenseDraft? = nil,
        screenshot: UIImage? = nil,
        onFinish: (@MainActor () -> Void)? = nil,
        save: @escaping DiningExpenseSaveAction
    ) {
        self.screenshot = screenshot
        self.onFinish = onFinish
        _flow = StateObject(
            wrappedValue: DiningExpenseEntryFlow(
                draft: draft,
                saveAction: save
            )
        )
    }

    var body: some View {
        BookkeepingEntryForm(
            flow: flow,
            configuration: .entry,
            screenshot: screenshot,
            // 截图入口先展示接收状态，让用户确认图片后主动选择分类。
            startsWithCategorySelection: screenshot == nil
        ) {
            // 首页回到前台后会把这一笔短暂标红，提示它记在了哪里。
            HomeRecentEntryHighlight.shared.mark(
                id: flow.draft.id,
                transactionDay: flow.draft.transactionDay
            )
            finishEntry()
        }
        .navigationTitle(AccountLocalization.string("bookkeeping.entry.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(flow.isSaving)
        .toolbar {
            if screenshot != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AccountLocalization.string("common.close", locale: locale)) {
                        finishEntry()
                    }
                    .disabled(flow.isSaving)
                    .accessibilityIdentifier("screenshot-entry-close")
                }
            }
        }
        .task {
            applyInitialDefaultIfNeeded()
        }
    }

    /// 无论取消还是保存成功，都只关闭本次录入页面。
    private func finishEntry() {
        if let onFinish {
            onFinish()
        } else {
            dismiss()
        }
    }

    /// 从当前查询快照解析一次 canonical 默认，不将偏好变化绑定到现有草稿。
    private func applyInitialDefaultIfNeeded() {
        let preference = preferences.first { $0.id == BookkeepingPreference.singletonID }
        let defaultAccountID = BookkeepingPreference.resolvedAccountID(
            preference: preference,
            accounts: accounts
        )
        flow.applyInitialDefault(defaultAccountID)
    }
}
