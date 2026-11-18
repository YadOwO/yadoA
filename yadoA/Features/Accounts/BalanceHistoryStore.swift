import Foundation
import Observation
import SwiftData
import SwiftUI

/// 余额走势的数据缓存：各账户每天余额变化的合计，账户页汇总卡片、资产趋势页和账户详情共用。
///
/// 流水可能有几万笔，不能每次刷新界面都全部读一遍。这里的做法：
/// - 本地数据每保存一次，`dataVersion` 加一，旧结果标记为过期，但先不重算；
/// - 有走势的页面在屏幕上时才重算，连续保存（导入、同步）只在停下来之后算一次；
/// - 重算用一个临时 context 分批读取流水，每批之间让出主线程，读完就释放，不把几万笔流水留在内存里；
/// - 重算期间页面照常显示上一次的结果，算好后整体替换。
///
/// 页面通过 `refreshesBalanceHistory()` 触发重算，用 `ledgers` 建 `AccountBalanceHistory` 取点。
@Observable
final class BalanceHistoryStore {
    /// 每批读取的流水笔数；每读完一批让出一次主线程，保证滚动、点按不卡顿。
    private static let batchSize = 2_000

    /// 数据刚保存后等一小会儿再重算，连续保存只算一次。
    private static let debounce: Duration = .milliseconds(300)

    /// 汇总好的各账户材料，键为账户 UUID；第一次还没算完时为 `nil`。
    private(set) var ledgers: [UUID: AccountBalanceHistory.Ledger]?

    /// 本地数据保存一次加一；页面用它触发重算。
    private(set) var dataVersion = 0

    /// `ledgers` 对应的数据版本。
    @ObservationIgnored private var loadedVersion: Int?

    /// 正在重算的数据版本；同一版本不重复开始。
    @ObservationIgnored private var loadingVersion: Int?

    /// `ledgers` 读自哪个容器；换了容器（如预览、测试）要重读。
    @ObservationIgnored private var loadedContainer: ObjectIdentifier?

    /// 正在进行的重算；有更新的版本要算时取消它。
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// 本地数据保存通知的监听；第一次用到时才注册。
    @ObservationIgnored private var saveObserver: (any NSObjectProtocol)?

    /// 最近一次本地数据保存的时间，用来判断是不是还在连续保存。
    @ObservationIgnored private var lastSaveAt: ContinuousClock.Instant?

    /// 页面出现或数据保存后调用：结果已是最新、或这一版正在算时什么也不做。
    ///
    /// 刚保存过时先等一小会儿再算，期间又保存了就重新等；第一次没有结果，或离上次保存已经很久（例如切回账户页），立即开始。
    ///
    /// - Parameters:
    ///   - container: 本地数据容器。
    ///   - calendar: 提供时区的日历，决定建账日落在哪个业务日。
    func refresh(container: ModelContainer, calendar: Calendar) {
        observeSavesIfNeeded()
        let version = dataVersion
        let isCurrent = loadedContainer == ObjectIdentifier(container) && loadedVersion == version
        guard !isCurrent, loadingVersion != version else { return }

        loadTask?.cancel()
        loadingVersion = version
        let quietAt = ledgers == nil ? nil : lastSaveAt.map { $0 + BalanceHistoryStore.debounce }
        loadTask = Task { [weak self] in
            if let quietAt {
                try? await Task.sleep(until: quietAt, clock: .continuous)
            }
            guard !Task.isCancelled else { return }
            await self?.reload(container: container, calendar: calendar, version: version)
        }
    }

    /// 立即重读全部账户和流水，汇总成各账户每天的余额变化。
    ///
    /// 读取失败时保留上一次的结果，等下次保存后再试；被更新的版本取消时直接放弃。
    ///
    /// - Parameters:
    ///   - container: 本地数据容器。
    ///   - calendar: 提供时区的日历。
    ///   - version: 这次结果对应的数据版本；不传时取当前版本。
    func reload(container: ModelContainer, calendar: Calendar, version: Int? = nil) async {
        observeSavesIfNeeded()
        let version = version ?? dataVersion
        defer {
            if loadingVersion == version { loadingVersion = nil }
        }

        // 临时 context 读完即释放，读到的几万个流水对象不会留在界面的 context 里
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let accounts = try context.fetch(FetchDescriptor<Account>())
            var builder = AccountBalanceHistory.LedgerBuilder(accounts: accounts)
            let batchSize = BalanceHistoryStore.batchSize
            let transactions = try context.fetch(BalanceHistoryStore.transactionDescriptor, batchSize: batchSize)
            for (index, transaction) in transactions.enumerated() {
                builder.add(transaction)
                if index % batchSize == batchSize - 1 {
                    // 让出主线程，界面在这时照常响应；数据又变了就放弃这一次
                    await Task.yield()
                    if Task.isCancelled { return }
                }
            }
            ledgers = builder.ledgers(for: accounts, calendar: calendar)
            loadedVersion = version
            loadedContainer = ObjectIdentifier(container)
        } catch {
            // 展示用的缓存：读不出来时继续用上一次的结果；第一次就失败时按没有流水处理，页面不会一直转圈
            if ledgers == nil { ledgers = [:] }
        }
    }

    /// 只读汇总要用的字段，备注等其他字段不读，减少读取量。
    ///
    /// 这里列的字段必须覆盖 `AccountBalanceRebuilder.balanceChanges` 和 `LedgerBuilder.add` 读到的全部字段，
    /// 漏了的字段会在读到时逐笔补取，反而更慢。
    private static var transactionDescriptor: FetchDescriptor<AccountTransaction> {
        var descriptor = FetchDescriptor<AccountTransaction>()
        descriptor.propertiesToFetch = [
            \.accountID,
            \.typeRawValue,
            \.categoryRawValue,
            \.amount,
            \.balanceBefore,
            \.balanceAfter,
            \.balanceDelta,
            \.counterpartAccountID,
            \.transactionDay
        ]
        return descriptor
    }

    /// 监听本地数据保存：任何 context 保存后都把结果标记为过期。
    ///
    /// 这个对象跟着 App 一直存在，监听不需要注销；放在第一次用到时注册，避免 SwiftUI 重复创建实例时多注册。
    private func observeSavesIfNeeded() {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastSaveAt = ContinuousClock.now
                self.dataVersion += 1
            }
        }
    }
}

extension View {
    /// 页面出现时、以及本地数据保存后，请求 `BalanceHistoryStore` 重算走势材料。
    ///
    /// 要挂在一直显示的视图上（例如列表本身），挂在可能不显示的走势段落上就触发不了。
    func refreshesBalanceHistory() -> some View {
        modifier(BalanceHistoryRefreshModifier())
    }
}

/// 读取环境里的走势缓存和数据容器，按数据版本触发重算。
private struct BalanceHistoryRefreshModifier: ViewModifier {
    @Environment(BalanceHistoryStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Environment(\.calendar) private var calendar

    func body(content: Content) -> some View {
        content.task(id: store.dataVersion) {
            store.refresh(container: modelContext.container, calendar: calendar)
        }
    }
}
