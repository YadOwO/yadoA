import Foundation
import SwiftUI
import Testing
@testable import yadoA

/// 验证宽屏两栏导航（iPhone Duo 内屏）里不依赖界面的部分：路径拆分与合并、收成一栏时何时算返回到左栏、何时展开、
/// 语音入口的显示规则、自带底栏的页面、宽屏单栏的阅读宽度，以及右栏占位文案。
///
/// 路由枚举和这些纯函数默认隔离在主 actor 上，整个测试组跑在主 actor。
@Suite("宽屏两栏导航")
@MainActor
struct TabSplitNavigationTests {
    /// 测试用的流水标识。
    static let transactionID = UUID(uuidString: "3B0F6C1E-2D4A-4E8B-9C7D-5A1F2E3D4C5B")!

    /// 测试用的另一笔流水标识。
    static let otherTransactionID = UUID(uuidString: "8E2D4F6A-1C3B-4A5D-8F7E-9B0C1D2E3F4A")!

    // MARK: - 路径拆分与合并

    @Test("路径第一项是右栏根页面，其余各项在右栏里往下推")
    func splitsPathIntoHeadAndTail() {
        let path: [HomeRoute] = [.search, .transactionDetail(Self.transactionID)]

        #expect(TabSplitPath.head(of: path) == .search)
        #expect(TabSplitPath.tail(of: path) == [.transactionDetail(Self.transactionID)])
        #expect(TabSplitPath.head(of: [HomeRoute]()) == nil)
        #expect(TabSplitPath.tail(of: [HomeRoute]()).isEmpty)
        #expect(TabSplitPath.tail(of: [HomeRoute.search]).isEmpty)
    }

    @Test("右栏推入或返回后合并回完整路径，根页面不变")
    func mergesTailBackIntoPath() {
        let path: [HomeRoute] = [.search]

        // 右栏里推入一页
        let pushed = TabSplitPath.replacingTail(of: path, with: [.transactionDetail(Self.transactionID)])
        #expect(pushed == [.search, .transactionDetail(Self.transactionID)])

        // 右栏返回到根页面：tail 清空，根页面保留
        #expect(TabSplitPath.replacingTail(of: pushed, with: []) == [.search])

        // 没有根页面时 tail 无处挂，路径保持为空
        #expect(TabSplitPath.replacingTail(of: [HomeRoute](), with: [.search]).isEmpty)
    }

    @Test("从一级页面打开页面会换掉右栏，之前推入的页面一并收起")
    func openingReplacesHead() {
        #expect(TabSplitPath.opening(HomeRoute.transactionDetail(Self.transactionID)) == [.transactionDetail(Self.transactionID)])

        // 右栏原来是资产分析里推入的账户详情，从左栏点另一个账户：右栏只剩新账户
        var path: [AccountsRoute] = [.assetAnalysis, .detail(Self.transactionID)]
        path = TabSplitPath.opening(.detail(Self.otherTransactionID))
        #expect(path == [.detail(Self.otherTransactionID)])
        #expect(TabSplitPath.head(of: path) == .detail(Self.otherTransactionID))
        #expect(TabSplitPath.tail(of: path).isEmpty)
    }

    @Test("收成一栏时的首选栏只看路径：路径为空停在一级页面，否则显示右栏")
    func mapsCompactColumnToPath() {
        #expect(TabSplitPath.compactColumn(for: [ProfileRoute]()) == .sidebar)
        #expect(TabSplitPath.compactColumn(for: [ProfileRoute.settings]) == .detail)
        #expect(TabSplitPath.compactColumn(for: [ProfileRoute.settings, .accountSecurity]) == .detail)
    }

    // MARK: - 收成一栏时的返回判定

    /// 搜索页里点开的流水详情路径。
    private var searchDetailPath: [HomeRoute] {
        [.search, .transactionDetail(Self.transactionID)]
    }

    /// 收成一栏、从一级页面打开了一页并停了一会儿：左栏被盖住，右栏根页面在屏幕上，没有留着的请求。
    ///
    /// - Parameter route: 打开的页面。
    private func collapsedProbe<Route: Hashable>(showing route: Route) -> TabSplitBackProbe<Route> {
        let probe = TabSplitBackProbe<Route>()
        #expect(probe.sidebarAppear() == .keep)
        probe.wait(.seconds(5))
        probe.navigate(to: [route])
        probe.rootAppear()
        probe.wait(.milliseconds(550))
        #expect(probe.sidebarDisappear() == .keep)
        probe.wait(.seconds(3))
        return probe
    }

    /// 在搜索页里点开一笔流水：右栏里推入详情，根页面被盖住。
    private func pushSearchDetail(on probe: TabSplitBackProbe<HomeRoute>) {
        probe.navigate(to: searchDetailPath)
        probe.wait(.milliseconds(570))
        probe.rootDisappear()
        probe.wait(.seconds(2))
    }

    @Test("“我的”打开设置后返回：系统写回左栏、左栏出现时立刻清空，不等根页面滑出，左栏页面刷新也推不回右栏")
    func profileReturnClearsAtSidebarAppear() {
        // 模拟器日志里的顺序：写回左栏，3 毫秒后左栏出现
        let probe = collapsedProbe(showing: ProfileRoute.settings)
        #expect(probe.select(.sidebar) == .keep)
        probe.wait(.milliseconds(3))
        #expect(probe.sidebarAppear() == .clear)
        #expect(probe.path.isEmpty)
        // 根页面还在滑出，留着撤销
        #expect(probe.tracker.undoPath == [ProfileRoute.settings])
        #expect(probe.tracker.requestTime == nil)
    }

    @Test("清空后根页面滑出就算返回完成：之后左栏消失（切 Tab、打开新页面）不再撤销")
    func rootDisappearAfterClearCommits() {
        let probe = collapsedProbe(showing: ProfileRoute.settings)
        probe.select(.sidebar)
        probe.wait(.milliseconds(3))
        #expect(probe.sidebarAppear() == .clear)

        probe.wait(.milliseconds(520))
        probe.rootDisappear()
        #expect(probe.tracker.undoPath == nil)

        probe.wait(.seconds(20))
        #expect(probe.sidebarDisappear() == .keep)
        #expect(probe.path.isEmpty)
    }

    @Test("清空后右栏还是被推了回来（左栏先于根页面消失）：撤销清空，路径和屏幕一致，再点返回照样能清")
    func bounceAfterClearRestoresPath() {
        let probe = collapsedProbe(showing: ProfileRoute.settings)
        probe.select(.sidebar)
        probe.wait(.milliseconds(3))
        #expect(probe.sidebarAppear() == .clear)

        probe.wait(.milliseconds(850))
        #expect(probe.sidebarDisappear() == .restore([ProfileRoute.settings]))
        #expect(probe.path == [.settings])
        #expect(probe.tracker.undoPath == nil)
        #expect(probe.tracker.isDetailRootShown)

        // 撤销时请求已经用掉，光是左栏再出现不会清
        probe.wait(.seconds(3))
        #expect(probe.sidebarAppear() == .keep)
        probe.sidebarDisappear()
        probe.wait(.seconds(1))
        #expect(probe.select(.sidebar) == .keep)
        probe.wait(.milliseconds(4))
        #expect(probe.sidebarAppear() == .clear)
    }

    @Test("从右栏根页面返回到左栏：系统写回和左栏出现先后都行，配上对立刻清空，同一次返回只清一次", arguments: [true, false])
    func rootPopClearsInEitherOrder(requestFirst: Bool) {
        let probe = collapsedProbe(showing: HomeRoute.search)

        if requestFirst {
            #expect(probe.select(.sidebar) == .keep)
            probe.wait(.milliseconds(4))
            #expect(probe.sidebarAppear() == .clear)
        } else {
            #expect(probe.sidebarAppear() == .keep)
            probe.wait(.milliseconds(4))
            #expect(probe.select(.sidebar) == .clear)
        }
        #expect(probe.path.isEmpty)
        #expect(probe.tracker.undoPath == [HomeRoute.search])

        // 同一次返回里重复的事件：路径已经为空，什么都不做
        #expect(probe.select(.sidebar) == .keep)
        #expect(probe.sidebarAppear() == .keep)
        probe.rootDisappear()
        #expect(probe.path.isEmpty)
    }

    @Test("系统写回和左栏出现相隔不超过配对时限才算同一次返回，先后都一样", arguments: [true, false])
    func pairingWindowBoundary(requestFirst: Bool) {
        let window = TabSplitBackTracker<HomeRoute>.pairingWindow
        let cases: [(gap: Duration, shouldClear: Bool)] = [
            (window - Duration.milliseconds(100), true),
            (window, true),
            (window + Duration.milliseconds(100), false)
        ]

        for (gap, shouldClear) in cases {
            let probe = collapsedProbe(showing: HomeRoute.search)
            let first = requestFirst ? probe.select(.sidebar) : probe.sidebarAppear()
            #expect(first == .keep)
            probe.wait(gap)
            let second = requestFirst ? probe.sidebarAppear() : probe.select(.sidebar)
            let expected: TabSplitBackTracker<HomeRoute>.Action = shouldClear ? .clear : .keep
            #expect(second == expected, "相隔 \(gap)")
            #expect(probe.path.isEmpty == shouldClear)
        }
    }

    @Test("过期的写回不和之后的左栏出现配对，过期的左栏出现也不和之后的写回配对")
    func expiredRequestOrAppearanceDoesNotClear() {
        // 写回了左栏，2 秒后左栏才出现
        let lateSidebar = collapsedProbe(showing: HomeRoute.search)
        #expect(lateSidebar.select(.sidebar) == .keep)
        lateSidebar.wait(.seconds(2))
        #expect(lateSidebar.sidebarAppear() == .keep)
        #expect(lateSidebar.sidebarDisappear() == .keep)
        #expect(lateSidebar.path == [.search])

        // 左栏出现了，2 秒后系统才写回
        let lateRequest = collapsedProbe(showing: HomeRoute.search)
        #expect(lateRequest.sidebarAppear() == .keep)
        lateRequest.wait(.seconds(2))
        #expect(lateRequest.select(.sidebar) == .keep)
        #expect(lateRequest.path == [.search])
    }

    @Test("右栏里返回一层时系统误写的左栏永远不清空：等不到左栏出现，过一会儿自然失效")
    func spuriousNestedPopWriteNeverClears() {
        // 模拟器日志里的顺序：先写回左栏，再收起右栏路径，根页面重新露出
        let requestFirst = collapsedProbe(showing: HomeRoute.search)
        pushSearchDetail(on: requestFirst)
        #expect(requestFirst.select(.sidebar) == .keep)
        requestFirst.navigate(to: [.search])
        requestFirst.rootAppear()
        #expect(requestFirst.path == [.search])
        #expect(requestFirst.tracker.undoPath == nil)

        // 6 秒后真的返回到左栏：系统会再写一次，配上新的写回才清
        requestFirst.wait(.seconds(6))
        #expect(requestFirst.sidebarAppear() == .keep)
        requestFirst.wait(.milliseconds(4))
        #expect(requestFirst.select(.sidebar) == .clear)

        // 反过来的顺序：右栏路径先收起，系统随后才写回；之后侧滑到一半松手，左栏出现又消失
        let requestLast = collapsedProbe(showing: HomeRoute.search)
        pushSearchDetail(on: requestLast)
        requestLast.navigate(to: [.search])
        requestLast.rootAppear()
        #expect(requestLast.select(.sidebar) == .keep)
        requestLast.wait(.seconds(2))
        #expect(requestLast.sidebarAppear() == .keep)
        #expect(requestLast.sidebarDisappear() == .keep)
        #expect(requestLast.path == [.search])
    }

    @Test("账户详情里不走路径推入的流水详情删除后返回：路径不变，两种先后顺序都不清空")
    func nonPathPopKeepsPath() {
        let probe = collapsedProbe(showing: AccountsRoute.detail(Self.transactionID))
        // 推入流水详情：路径不变，根页面被盖住
        probe.wait(.milliseconds(500))
        probe.rootDisappear()
        probe.wait(.seconds(2))

        let requestFirst = probe.copy()
        #expect(requestFirst.select(.sidebar) == .keep)
        requestFirst.rootAppear()
        requestFirst.wait(.seconds(2))
        #expect(requestFirst.path == [.detail(Self.transactionID)])

        let requestLast = probe.copy()
        requestLast.rootAppear()
        #expect(requestLast.select(.sidebar) == .keep)
        requestLast.wait(.seconds(2))
        #expect(requestLast.path == [.detail(Self.transactionID)])

        // 之后从账户详情真的返回到左栏
        #expect(requestLast.select(.sidebar) == .keep)
        requestLast.wait(.milliseconds(4))
        #expect(requestLast.sidebarAppear() == .clear)
    }

    @Test("长按返回按钮从推入的页面直接跳回左栏：照样清空；根页面本来就被盖着，取消不了，不留撤销")
    func popToRootFromNestedPageClearsWithoutUndo() {
        let probe = collapsedProbe(showing: HomeRoute.search)
        pushSearchDetail(on: probe)

        #expect(probe.select(.sidebar) == .keep)
        probe.wait(.milliseconds(4))
        #expect(probe.sidebarAppear() == .clear)
        #expect(probe.path.isEmpty)
        #expect(probe.tracker.undoPath == nil)

        // 之后打开新页面、左栏被盖住，路径不会被改回去
        probe.wait(.seconds(2))
        probe.navigate(to: [.expenseEntry])
        #expect(probe.sidebarDisappear() == .keep)
        #expect(probe.path == [.expenseEntry])
    }

    @Test("侧滑返回松手取消、系统没写回：左栏出现又消失，路径不动，之后单独来的写回也不清")
    func cancelledSwipeWithoutRequestKeepsPath() {
        let probe = collapsedProbe(showing: HomeRoute.search)
        #expect(probe.sidebarAppear() == .keep)
        probe.wait(.milliseconds(400))
        #expect(probe.sidebarDisappear() == .keep)
        probe.wait(.milliseconds(100))
        #expect(probe.select(.sidebar) == .keep)
        #expect(probe.path == [.search])
    }

    @Test("侧滑返回开始时已经清空、松手取消：左栏先于根页面消失，撤销回原来的路径")
    func cancelledSwipeAfterClearRestoresPath() {
        let probe = collapsedProbe(showing: HomeRoute.search)
        #expect(probe.select(.sidebar) == .keep)
        #expect(probe.sidebarAppear() == .clear)
        #expect(probe.path.isEmpty)

        probe.wait(.milliseconds(300))
        #expect(probe.sidebarDisappear() == .restore([HomeRoute.search]))
        #expect(probe.path == [.search])

        // 右栏里返回一层留下的误写还没过期时开始侧滑：它和左栏出现配上对清空，松手取消照样撤销
        let leftover = collapsedProbe(showing: HomeRoute.search)
        pushSearchDetail(on: leftover)
        #expect(leftover.select(.sidebar) == .keep)
        leftover.navigate(to: [.search])
        leftover.rootAppear()
        leftover.wait(.seconds(1))
        #expect(leftover.sidebarAppear() == .clear)
        leftover.wait(.milliseconds(300))
        #expect(leftover.sidebarDisappear() == .restore([HomeRoute.search]))
        #expect(leftover.path == [.search])
    }

    @Test("点返回后动画没播完就切到别的 Tab：左栏先消失也不撤销，回来时停在一级页面", arguments: [true, false])
    func switchingTabDuringReturnKeepsClear(containerFirst: Bool) {
        // 切走 Tab 时左栏和整个容器同一批离开屏幕，先后不定；右栏根页面随后也离开
        let probe = collapsedProbe(showing: ProfileRoute.settings)
        probe.select(.sidebar)
        probe.wait(.milliseconds(3))
        #expect(probe.sidebarAppear() == .clear)
        probe.wait(.milliseconds(200))
        if containerFirst {
            probe.containerDisappear()
            #expect(probe.sidebarDisappear(confirmsRestore: false) == .keep)
        } else {
            #expect(probe.sidebarDisappear(confirmsRestore: false) == .confirmRestoreLater)
            probe.containerDisappear()
        }
        probe.rootDisappear()
        #expect(probe.confirmRestore() == .keep)
        #expect(probe.path.isEmpty)
        #expect(probe.tracker.undoPath == nil)
        #expect(!probe.tracker.isRestorePending)

        // 回到这个 Tab：左栏出现，没有留下的写回可配对，路径保持为空
        probe.wait(.seconds(2))
        #expect(probe.sidebarAppear() == .keep)
        #expect(probe.path.isEmpty)
    }

    @Test("左栏消失后、确认撤销前根页面也离开了屏幕：返回其实完成了，不撤销")
    func rootDisappearBeforeConfirmDropsRestore() {
        let probe = collapsedProbe(showing: HomeRoute.search)
        probe.select(.sidebar)
        #expect(probe.sidebarAppear() == .clear)
        probe.wait(.milliseconds(250))
        #expect(probe.sidebarDisappear(confirmsRestore: false) == .confirmRestoreLater)
        #expect(probe.tracker.isRestorePending)
        probe.rootDisappear()
        #expect(probe.confirmRestore() == .keep)
        #expect(probe.path.isEmpty)

        // 确认只做一次：再来一次也不会改路径
        #expect(probe.confirmRestore() == .keep)
        #expect(probe.path.isEmpty)
    }

    @Test("清空后、根页面滑出前就从一级页面打开了新页面：撤销作废，推入过程中的写回也不会把新页面关掉")
    func openingPageAfterClearDropsUndo() {
        let probe = collapsedProbe(showing: HomeRoute.search)
        probe.select(.sidebar)
        #expect(probe.sidebarAppear() == .clear)

        // 返回动画还没结束就点了「记一笔」
        probe.wait(.milliseconds(200))
        probe.navigate(to: [.expenseEntry])
        #expect(probe.tracker.undoPath == nil)
        // 左栏刚才的出现属于上一次返回，不能和推入过程中的写回配对
        #expect(probe.tracker.sidebarAppearTime == nil)
        probe.wait(.milliseconds(100))
        #expect(probe.select(.sidebar) == .keep)
        probe.rootDisappear()
        probe.rootAppear()
        probe.wait(.milliseconds(400))
        #expect(probe.sidebarDisappear() == .keep)
        #expect(probe.path == [.expenseEntry])
    }

    @Test("开合 iPhone Duo 时右栏是填到一半的记一笔：展开时的事件一律不算，合上时即使左栏一闪而过也会撤销回来")
    func layoutChangesKeepPath() {
        // 两栏展开、右栏是记一笔
        let probe = TabSplitBackProbe<HomeRoute>(isCollapsed: false)
        #expect(probe.sidebarAppear(collapsed: false) == .keep)
        probe.navigate(to: [.expenseEntry])
        probe.rootAppear(collapsed: false)
        #expect(probe.select(.sidebar, collapsed: false) == .keep)
        #expect(probe.tracker.sidebarAppearTime == nil)

        // 合上：收成一栏，左栏离开屏幕
        probe.wait(.seconds(10))
        #expect(probe.layout(collapsed: true))
        #expect(probe.sidebarDisappear() == .keep)
        #expect(probe.select(.sidebar) == .keep)
        #expect(probe.path == [.expenseEntry])

        // 假如合上时系统先把左栏露了一下又写回左栏：先清空，右栏定下来、左栏消失后撤销回来
        let flicker = TabSplitBackProbe<HomeRoute>(isCollapsed: false)
        flicker.navigate(to: [.expenseEntry])
        flicker.rootAppear(collapsed: false)
        #expect(flicker.layout(collapsed: true))
        #expect(flicker.sidebarAppear() == .keep)
        #expect(flicker.select(.sidebar) == .clear)
        flicker.wait(.milliseconds(300))
        #expect(flicker.sidebarDisappear() == .restore([HomeRoute.expenseEntry]))
        #expect(flicker.path == [.expenseEntry])

        // 再打开：左栏出现、系统写回，事件带着展开后的布局，都不算
        probe.wait(.seconds(10))
        #expect(probe.layout(collapsed: false))
        #expect(probe.sidebarAppear(collapsed: false) == .keep)
        #expect(probe.select(.sidebar, collapsed: false) == .keep)
        #expect(probe.path == [.expenseEntry])
        #expect(probe.tracker.requestTime == nil)
    }

    @Test("展开收起切换时作废留着的写回、左栏出现和撤销")
    func layoutChangeDropsPendingState() {
        // 留着写回：切换前后都在配对时限内，也不和切换后的左栏出现配对
        let pendingRequest = collapsedProbe(showing: HomeRoute.search)
        #expect(pendingRequest.select(.sidebar) == .keep)
        #expect(pendingRequest.layout(collapsed: false))
        #expect(pendingRequest.layout(collapsed: true))
        #expect(pendingRequest.tracker.requestTime == nil)
        #expect(pendingRequest.sidebarAppear() == .keep)
        #expect(pendingRequest.path == [.search])

        // 留着左栏出现：切换后来的写回不和它配对
        let pendingAppearance = collapsedProbe(showing: HomeRoute.search)
        #expect(pendingAppearance.sidebarAppear() == .keep)
        #expect(pendingAppearance.layout(collapsed: false))
        #expect(pendingAppearance.layout(collapsed: true))
        #expect(pendingAppearance.select(.sidebar) == .keep)
        #expect(pendingAppearance.path == [.search])

        // 留着撤销：清空后马上打开 Duo，撤销作废，左栏怎么消失都不改回去
        let pendingUndo = collapsedProbe(showing: HomeRoute.search)
        pendingUndo.select(.sidebar)
        #expect(pendingUndo.sidebarAppear() == .clear)
        #expect(pendingUndo.layout(collapsed: false))
        #expect(pendingUndo.tracker.undoPath == nil)
        #expect(pendingUndo.sidebarDisappear(collapsed: false) == .keep)
        #expect(pendingUndo.path.isEmpty)
    }

    @Test("开合之后真的返回到左栏仍会清空")
    func returnAfterLayoutChangeClears() {
        let probe = collapsedProbe(showing: HomeRoute.search)
        #expect(probe.layout(collapsed: false))
        probe.wait(.seconds(5))
        #expect(probe.layout(collapsed: true))
        probe.wait(.seconds(5))

        #expect(probe.select(.sidebar) == .keep)
        probe.wait(.milliseconds(4))
        #expect(probe.sidebarAppear() == .clear)
        #expect(probe.tracker.undoPath == [HomeRoute.search])
    }

    @Test("路径清空、从一级页面打开新页面时作废旧的写回，刚打开的页面不会被它关掉")
    func openingNewPageResetsStaleRequest() {
        // 搜索页里留下误写，随后页面自己关掉（路径清空），马上又打开记一笔
        let probe = collapsedProbe(showing: HomeRoute.search)
        #expect(probe.select(.sidebar) == .keep)
        probe.navigate(to: [])
        #expect(probe.tracker.requestTime == nil)
        #expect(probe.sidebarAppear() == .keep)
        probe.wait(.milliseconds(300))
        probe.navigate(to: [.expenseEntry])
        #expect(probe.tracker.requestTime == nil)
        #expect(probe.tracker.sidebarAppearTime == nil)

        // 推入过程中左栏还没消失，又露出一下（例如侧滑）也不会清
        probe.rootAppear()
        #expect(probe.sidebarAppear() == .keep)
        #expect(probe.path == [.expenseEntry])
    }

    @Test("系统写回右栏时作废写回；路径为空、页面自己关掉时什么都不清也不撤销")
    func detailSelectionAndEmptyPathNeverClear() {
        let probe = collapsedProbe(showing: HomeRoute.search)
        #expect(probe.select(.sidebar) == .keep)
        #expect(probe.select(.detail) == .keep)
        #expect(probe.tracker.requestTime == nil)
        #expect(probe.sidebarAppear() == .keep)
        #expect(probe.path == [.search])

        // 停在一级页面：系统写回左栏、左栏出现都只是常态
        let atRoot = TabSplitBackProbe<HomeRoute>()
        #expect(atRoot.select(.sidebar) == .keep)
        #expect(atRoot.tracker.requestTime == nil)
        #expect(atRoot.sidebarAppear() == .keep)

        // 右栏根页面自己关掉（删除、保存后）：容器直接清空，之后的返回事件不留撤销
        let closed = collapsedProbe(showing: HomeRoute.transactionDetail(Self.transactionID))
        closed.navigate(to: [])
        #expect(closed.select(.sidebar) == .keep)
        #expect(closed.sidebarAppear() == .keep)
        closed.wait(.milliseconds(100))
        #expect(closed.sidebarDisappear() == .keep)
        #expect(closed.path.isEmpty)
    }

    // MARK: - 是否展开成两栏

    @Test("只有 regular 尺寸类别且宽度不小于阈值时展开成两栏")
    func expandsOnlyWhenRegularAndWide() {
        let threshold = TabSplitLayout.minimumExpandedWidth
        #expect(threshold == 700)

        // compact：普通 iPhone、Duo 外屏、分屏半屏，再宽也是单栏
        #expect(!TabSplitLayout.isExpanded(containerWidth: 1_200, horizontalSizeClass: .compact))
        #expect(!TabSplitLayout.isExpanded(containerWidth: 1_200, horizontalSizeClass: nil))
        // regular 但不够宽：Duo 内屏竖着拿，按一部大 iPhone 显示单栏
        #expect(!TabSplitLayout.isExpanded(containerWidth: 640, horizontalSizeClass: .regular))
        // regular 且够宽：Duo 内屏横着拿
        #expect(TabSplitLayout.isExpanded(containerWidth: 1_000, horizontalSizeClass: .regular))
        // 阈值边界：等于阈值展开，差一点不展开
        #expect(TabSplitLayout.isExpanded(containerWidth: threshold, horizontalSizeClass: .regular))
        #expect(!TabSplitLayout.isExpanded(containerWidth: threshold - 0.5, horizontalSizeClass: .regular))
    }

    @Test("两栏阈值放得下理想宽度的左栏和最窄 iPhone 宽度的右栏")
    func thresholdFitsBothColumns() {
        #expect(TabSplitLayout.sidebarMinimumWidth <= TabSplitLayout.sidebarIdealWidth)
        #expect(TabSplitLayout.sidebarIdealWidth <= TabSplitLayout.sidebarMaximumWidth)
        #expect(TabSplitLayout.sidebarIdealWidth + 320 <= TabSplitLayout.minimumExpandedWidth)
    }

    // MARK: - 语音入口

    @Test("单栏时只有停在一级页面才显示语音入口")
    func collapsedShowsAccessoryOnlyAtRoot() {
        #expect(TabSplitLayout.showsRootAccessory(path: [HomeRoute](), isExpanded: false))
        #expect(!TabSplitLayout.showsRootAccessory(path: [HomeRoute.transactionDetail(Self.transactionID)], isExpanded: false))
        #expect(!TabSplitLayout.showsRootAccessory(path: [HomeRoute.expenseEntry], isExpanded: false))
        #expect(!TabSplitLayout.showsRootAccessory(path: [AccountsRoute.detail(Self.transactionID)], isExpanded: false))
        #expect(!TabSplitLayout.showsRootAccessory(path: [ProfileRoute.settings], isExpanded: false))
    }

    @Test("两栏时左栏一直是一级页面，只有右栏最上面的页面自带底栏时收起语音入口")
    func expandedHidesAccessoryOnlyForOwnBottomBar() {
        #expect(TabSplitLayout.showsRootAccessory(path: [HomeRoute](), isExpanded: true))
        #expect(TabSplitLayout.showsRootAccessory(path: [HomeRoute.transactionDetail(Self.transactionID)], isExpanded: true))
        #expect(TabSplitLayout.showsRootAccessory(
            path: [HomeRoute.search, .transactionDetail(Self.transactionID)],
            isExpanded: true
        ))
        #expect(!TabSplitLayout.showsRootAccessory(path: [HomeRoute.expenseEntry], isExpanded: true))
        #expect(!TabSplitLayout.showsRootAccessory(
            path: [HomeRoute.repeatEntry(DiningExpenseDraft(transactionDay: 20_261_123))],
            isExpanded: true
        ))

        #expect(TabSplitLayout.showsRootAccessory(path: [AccountsRoute.detail(Self.transactionID)], isExpanded: true))
        #expect(TabSplitLayout.showsRootAccessory(path: [ProfileRoute.settings], isExpanded: true))
        #expect(!TabSplitLayout.showsRootAccessory(path: [ProfileRoute.feedback], isExpanded: true))
        // 按右栏最上面的页面判断，而不是右栏根页面
        #expect(!TabSplitLayout.showsRootAccessory(path: [ProfileRoute.aiPoints, .aiProcessingConsent], isExpanded: true))
        #expect(TabSplitLayout.showsRootAccessory(path: [ProfileRoute.aiPoints, .aiModelTier], isExpanded: true))
    }

    @Test("记一笔和再记一笔自带保存栏，搜索和详情没有")
    func homeRoutesReportOwnBottomBar() {
        #expect(HomeRoute.expenseEntry.hasOwnBottomBar)
        #expect(HomeRoute.repeatEntry(DiningExpenseDraft(transactionDay: 20_261_123)).hasOwnBottomBar)
        #expect(!HomeRoute.search.hasOwnBottomBar)
        #expect(!HomeRoute.transactionDetail(Self.transactionID).hasOwnBottomBar)
    }

    @Test("账户的二级页面都没有底栏，“我的”只有意见反馈和 AI 记账说明有")
    func otherRoutesReportOwnBottomBar() {
        #expect(!AccountsRoute.detail(Self.transactionID).hasOwnBottomBar)
        #expect(!AccountsRoute.transactionDetail(Self.transactionID).hasOwnBottomBar)
        #expect(!AccountsRoute.assetAnalysis.hasOwnBottomBar)

        let withBottomBar: Set<ProfileRoute> = [.feedback, .aiProcessingConsent]
        let allProfileRoutes: [ProfileRoute] = [
            .bills, .categories, .recurringRules, .sync, .aiPoints, .aiPointLots, .aiCreditEntries, .aiModelTier,
            .aiTraceConsent, .aiProcessingConsent, .checkIn, .settings, .accountSecurity, .feedback, .moreProducts,
            .developer
        ]
        for route in allProfileRoutes {
            #expect(route.hasOwnBottomBar == withBottomBar.contains(route))
        }
    }

    // MARK: - 阅读宽度

    @Test("容器不宽于 620pt 时不改写边距，更宽时对称加外边距把内容居中排成 620pt")
    func readableWidthMargins() {
        let maxWidth = ReadableContentWidth.maxContentWidth
        #expect(maxWidth == 620)

        // 普通 iPhone、两栏里的左栏：不改写
        #expect(ReadableContentWidth.horizontalMargin(containerWidth: 440, sideMargin: 0) == nil)
        #expect(ReadableContentWidth.horizontalMargin(containerWidth: 375, sideMargin: ReadableContentWidth.listSideMargin) == nil)
        #expect(ReadableContentWidth.horizontalMargin(containerWidth: maxWidth, sideMargin: 0) == nil)

        // 宽屏单栏：自己带内边距的 ScrollView 只加居中所需的外边距
        #expect(ReadableContentWidth.horizontalMargin(containerWidth: 820, sideMargin: 0) == 100)
        // 分组列表的默认边距被改写，补回页面左右的 20pt
        #expect(ReadableContentWidth.horizontalMargin(containerWidth: 820, sideMargin: ReadableContentWidth.listSideMargin) == 120)
        // 刚超过 620pt 时外边距从 0 开始，内容宽度连续变化
        #expect(ReadableContentWidth.horizontalMargin(containerWidth: maxWidth + 2, sideMargin: 0) == 1)
    }

    // MARK: - 右栏占位文案

    @Test("右栏占位文案支持中英文")
    func placeholderLocalization() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")

        #expect(
            AccountLocalization.string("app.split.placeholder.home", locale: english)
                == "Select an entry to see its details here"
        )
        #expect(
            AccountLocalization.string("app.split.placeholder.home", locale: simplifiedChinese)
                == "选择一笔记账，在这里查看详情"
        )
        #expect(
            AccountLocalization.string("app.split.placeholder.accounts", locale: english)
                == "Select an account to see its details here"
        )
        #expect(
            AccountLocalization.string("app.split.placeholder.accounts", locale: simplifiedChinese)
                == "选择一个账户，在这里查看详情"
        )
        #expect(
            AccountLocalization.string("app.split.placeholder.profile", locale: english)
                == "Choose an item to open it here"
        )
        #expect(
            AccountLocalization.string("app.split.placeholder.profile", locale: simplifiedChinese)
                == "选择一项，在这里打开"
        )
    }
}

/// 测试里模拟两栏容器驱动 `TabSplitBackTracker`：持有路径和一只假时钟，按判定结果清空或撤销路径。
///
/// `#expect` 会把方法调用拆成闭包里对副本的调用，值类型上会改状态的方法直接放进去可能编译不过；经过引用调用就没有这个问题。
/// 路径变化后立刻通知判定状态；真实容器里这一步在 `onChange(of: path)` 里稍晚一点到，对判定没有影响。
/// 事件参数默认按收成一栏处理。
@MainActor
private final class TabSplitBackProbe<Route: Hashable> {
    /// 判定状态给出的动作。
    typealias Action = TabSplitBackTracker<Route>.Action

    /// 被测的判定状态。
    private(set) var tracker: TabSplitBackTracker<Route>

    /// 这个 Tab 的导航路径，从一级页面开始。
    private(set) var path: [Route] = []

    /// 假时钟的当前时间，只由 `wait(_:)` 往前拨。
    private(set) var now = ContinuousClock.now

    /// 创建探针。
    ///
    /// - Parameter isCollapsed: 初始布局是否收成一栏。
    init(isCollapsed: Bool = true) {
        tracker = TabSplitBackTracker(isCollapsed: isCollapsed)
    }

    /// 复制一份当前状态，从同一处分出不同的后续事件。
    func copy() -> TabSplitBackProbe<Route> {
        let copy = TabSplitBackProbe<Route>(isCollapsed: tracker.isCollapsed)
        copy.tracker = tracker
        copy.path = path
        copy.now = now
        return copy
    }

    /// 把假时钟往前拨。
    func wait(_ duration: Duration) {
        now = now.advanced(by: duration)
    }

    /// 路径变了：打开页面、右栏里推入或返回、页面自己关掉，或判定后的清空、撤销。
    func navigate(to newPath: [Route]) {
        let oldPath = path
        path = newPath
        tracker.pathChanged(from: oldPath, to: newPath)
    }

    /// 布局在展开和收起之间切换。
    @discardableResult
    func layout(collapsed: Bool) -> Bool {
        tracker.layoutChanged(isCollapsed: collapsed)
    }

    /// 系统写回首选栏。
    @discardableResult
    func select(_ column: NavigationSplitViewColumn, collapsed: Bool = true) -> Action {
        apply(tracker.systemSelectedColumn(column, isCollapsed: collapsed, path: path, now: now))
    }

    /// 左栏出现。
    @discardableResult
    func sidebarAppear(collapsed: Bool = true) -> Action {
        apply(tracker.sidebarAppeared(isCollapsed: collapsed, path: path, now: now))
    }

    /// 左栏消失。
    ///
    /// 容器遇到「稍后确认撤销」时会等一会儿再确认；默认当作这段时间里没有别的事件，立刻确认并返回确认的结果。
    /// 要在中间插入事件（切走 Tab、根页面离开）时传 `confirmsRestore: false`，之后自己调用 `confirmRestore()`。
    @discardableResult
    func sidebarDisappear(collapsed: Bool = true, confirmsRestore: Bool = true) -> Action {
        let action = apply(tracker.sidebarDisappeared(isCollapsed: collapsed, path: path))
        guard confirmsRestore, action == .confirmRestoreLater else { return action }
        return confirmRestore()
    }

    /// 左栏消失一会儿之后确认撤销。
    @discardableResult
    func confirmRestore() -> Action {
        apply(tracker.confirmRestore(path: path))
    }

    /// 整个两栏容器离开屏幕：切到别的 Tab。
    func containerDisappear() {
        tracker.containerDisappeared()
    }

    /// 右栏根页面出现。
    func rootAppear(collapsed: Bool = true) {
        tracker.detailRootAppeared(isCollapsed: collapsed)
    }

    /// 右栏根页面离开屏幕。
    func rootDisappear(collapsed: Bool = true) {
        tracker.detailRootDisappeared(isCollapsed: collapsed)
    }

    /// 像容器一样执行判定结果，并原样返回，方便断言。
    private func apply(_ action: Action) -> Action {
        switch action {
        case .keep:
            break
        case .clear:
            navigate(to: [])
        case let .restore(oldPath):
            navigate(to: oldPath)
        case .confirmRestoreLater:
            break
        }
        return action
    }
}
