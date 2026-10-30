import SwiftData
import SwiftUI

/// App 回到前台和进入后台时要做的记账杂事：把到期的周期记账记入账本，重排每日提醒。
private struct BookkeepingLifecycleHostModifier: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    /// 同步引擎；由外层在本地数据就绪后注入，还没创建时为 nil。
    @Environment(SyncEngine.self) private var syncEngine: SyncEngine?

    func body(content: Content) -> some View {
        content
            .task(id: Trigger(isActive: scenePhase == .active, hasSyncEngine: syncEngine != nil)) {
                guard scenePhase == .active else { return }
                await generateDueEntries()
                await rescheduleReminders()
            }
            // 进入后台时再排一次：刚才记过账的话，今天的提醒要取消
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                Task { await rescheduleReminders() }
            }
    }

    /// 触发一轮处理的条件。
    private struct Trigger: Equatable {
        /// App 是否在前台。
        let isActive: Bool

        /// 同步引擎是否已创建；开启同步时要等它创建好。
        let hasSyncEngine: Bool
    }

    /// 把到期的周期记账记入账本，并让首页提示这几笔。
    ///
    /// 开启了同步时先等这一轮同步结束：其他设备可能已经记过、甚至已经删掉了这一期，
    /// 先拿到它们的进度，才不会把已删除的流水又生成回来。网络不通时同步会失败结束，不影响记入。
    private func generateDueEntries() async {
        if SyncState.load(from: SyncChangeTracker.defaults).isEnabled {
            guard let syncEngine else { return }
            await syncEngine.waitUntilIdle()
        }
        guard !Task.isCancelled else { return }
        let today = TransactionDay.encode(.now, calendar: calendar)
        let entries = LocalRecurringRuleRepository(container: modelContext.container).generateDue(today: today)
        for entry in entries {
            HomeRecentEntryHighlight.shared.mark(id: entry.id, transactionDay: entry.transactionDay)
        }
    }

    /// 按当前偏好重排每日提醒。
    private func rescheduleReminders() async {
        await BookkeepingReminderScheduler.reschedule(
            container: modelContext.container,
            locale: locale,
            calendar: calendar
        )
    }
}

extension View {
    /// 挂上前后台切换时的记账杂事；需要放在注入了同步引擎的视图里面。
    func bookkeepingLifecycleHost() -> some View {
        modifier(BookkeepingLifecycleHostModifier())
    }
}
