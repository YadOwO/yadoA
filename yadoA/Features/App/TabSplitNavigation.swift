import SwiftUI
#if DEBUG
import os
#endif

// MARK: - 路由约定

/// 能放进「列表 + 详情」两栏导航的二级页面路由。
///
/// 路径的第一项是右栏（详情栏）的根页面，其余各项在右栏里逐层推入；
/// 窄屏收成一栏时，整条路径照旧读作「一级页面 → 第一项 → 后续各项」，与原来的导航栈一致。
protocol TabSplitRoute: Hashable {
    /// 页面是否自带贴底的操作栏，例如记一笔的保存栏、意见反馈的输入栏。
    ///
    /// 宽屏两栏时左栏一直是一级页面，语音麦克风本可以常显；但 Tab Bar 附属栏横跨整个 Tab 内容、又不计入内容区的安全区，
    /// 会盖住右栏页面自己的底栏，所以右栏最上面是这类页面时收起麦克风，见 `TabSplitLayout.showsRootAccessory(path:isExpanded:)`。
    var hasOwnBottomBar: Bool { get }
}

// MARK: - 布局取舍

/// 两栏布局的取舍：什么时候展开成两栏、左栏多宽、语音入口什么时候露出。
///
/// 只按可用宽度和水平尺寸类别判断，不看横竖屏，也不看设备类型：iPhone Duo 是 iPhone（idiom 为 `.phone`），
/// 内屏横竖都是 regular，而且内屏不受 App 只支持竖屏的限制。
enum TabSplitLayout {
    /// 展开成两栏所需的最小可用宽度（pt）。
    ///
    /// 两栏都要放得下 iPhone 竖屏的版式：左栏理想宽度 375pt，右栏至少留 320pt，合计约 700pt。
    /// 内屏竖着拿时按「一部大 iPhone」显示单栏，横过来宽度足够才展开；分屏多任务压到半屏时尺寸类别回到 compact，同样是单栏。
    static let minimumExpandedWidth: CGFloat = 700

    /// 左栏的最小宽度，与最窄的 iPhone 竖屏一致。
    static let sidebarMinimumWidth: CGFloat = 320

    /// 左栏的理想宽度，与常见 iPhone 竖屏的宽度一致，一级页面按原有版式排布。
    static let sidebarIdealWidth: CGFloat = 375

    /// 左栏的最大宽度，再宽一级页面的列表会显得空。
    static let sidebarMaximumWidth: CGFloat = 420

    /// 当前可用宽度下是否展开成两栏。
    ///
    /// - Parameters:
    ///   - containerWidth: Tab 内容区的可用宽度。
    ///   - horizontalSizeClass: 系统给出的水平尺寸类别；`nil` 按 compact 处理。
    /// - Returns: 只有尺寸类别是 regular、且宽度不小于 `minimumExpandedWidth` 时为 `true`。
    static func isExpanded(containerWidth: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        horizontalSizeClass == .regular && containerWidth >= minimumExpandedWidth
    }

    /// 语音麦克风和会话卡片是否该在这个 Tab 露出。
    ///
    /// 单栏时与原来一致：路径为空、停在一级页面才显示。两栏时左栏一直是一级页面，麦克风常显，
    /// 只有右栏最上面的页面自带底栏时收起，免得附属栏盖住它。
    /// - Parameters:
    ///   - path: 这个 Tab 的导航路径。
    ///   - isExpanded: 当前是否展开成两栏。
    /// - Returns: 是否显示语音入口。
    static func showsRootAccessory<Route: TabSplitRoute>(path: [Route], isExpanded: Bool) -> Bool {
        guard let topRoute = path.last else { return true }
        guard isExpanded else { return false }
        return !topRoute.hasOwnBottomBar
    }
}

// MARK: - 路径拆分

/// 把一个 Tab 的导航路径拆成右栏根页面和右栏里推入的页面，或者反过来合并；全是纯函数，方便单独测试。
///
/// 路径数组始终是唯一的数据来源：第一项（head）是右栏的根页面，其余各项（tail）是右栏导航栈的路径。
enum TabSplitPath {
    /// 右栏的根页面；路径为空时右栏显示占位。
    ///
    /// - Parameter path: Tab 的导航路径。
    /// - Returns: 路径的第一项。
    static func head<Route>(of path: [Route]) -> Route? {
        path.first
    }

    /// 右栏导航栈里推入的页面。
    ///
    /// - Parameter path: Tab 的导航路径。
    /// - Returns: 去掉第一项后的其余各项。
    static func tail<Route>(of path: [Route]) -> [Route] {
        Array(path.dropFirst())
    }

    /// 右栏导航栈的路径变化后（推入、返回）合并回完整路径。
    ///
    /// - Parameters:
    ///   - path: 变化前的完整路径。
    ///   - tail: 右栏导航栈的新路径。
    /// - Returns: 保留原来的根页面、换上新 tail 的路径；没有根页面时 tail 无处挂，保持为空。
    static func replacingTail<Route>(of path: [Route], with tail: [Route]) -> [Route] {
        guard let head = path.first else { return [] }
        return [head] + tail
    }

    /// 从一级页面打开一个二级页面：换掉右栏，而不是在右栏里继续往下推。
    ///
    /// 再点一次右栏当前的根页面会回到它本身，之前在右栏里推入的页面一并收起。
    /// - Parameter route: 要打开的页面。
    /// - Returns: 只含这一页的路径。
    static func opening<Route>(_ route: Route) -> [Route] {
        [route]
    }

    /// 收成一栏时该显示哪一栏：路径为空停在一级页面，否则显示右栏。
    ///
    /// 首选栏始终由路径决定；系统写回的值不直接改路径，交给 `TabSplitBackTracker` 判断用户是不是真的返回到了左栏。
    /// - Parameter path: Tab 的导航路径。
    /// - Returns: 传给 `NavigationSplitView` 的首选栏。
    static func compactColumn<Route>(for path: [Route]) -> NavigationSplitViewColumn {
        path.isEmpty ? .sidebar : .detail
    }
}

// MARK: - 收成一栏时的返回判定

/// 收成一栏时判断用户是不是真的从右栏返回到了左栏（一级页面），据此清空路径，返回取消时再撤销；纯值类型，不碰视图，
/// 时间由调用方传入，方便单独测试。
///
/// 收成一栏时系统会把首选栏写回 `.sidebar`，但不只在返回到左栏时写：右栏里推入的页面返回一层（点返回、删除后 `dismiss()`）时，
/// 右栏明明还在屏幕上，系统也会写 `.sidebar`。一收到就清空路径的话，返回一层会把整条路径清掉，右栏只剩占位。
/// 所以系统的写回只算「请求」，要和「左栏在收成一栏的状态下出现」配成一对才清空：
/// - 两件事先后不限，但相隔不超过 `pairingWindow`。返回一层时的误写等不到左栏出现，过一会儿自然失效；
///   真的返回到左栏时系统会再写一次，不靠留下来的旧请求。
/// - 配对成功立刻清空，不等右栏根页面滑出。路径一空，首选栏读出来就是 `.sidebar`，与屏幕一致；
///   若等到根页面滑出才清，中间这段时间首选栏仍读作 `.detail`，左栏页面这时一刷新（例如“我的”出现时刷新签到、点数），
///   分栏视图就会照 `.detail` 把右栏推回来，返回不了。
/// - 两栏时左栏一直在屏幕上，那时的出现不算；展开、收起一切换，之前的请求和出现都作废。
///
/// 清空后到右栏根页面滑出前可以撤销：这段时间里左栏又消失了（侧滑返回松手取消，或者右栏被推回来），
/// 就把清空前的路径还回去，让路径和屏幕保持一致。根页面滑出后返回才算完成，撤销作废；展开、收起切换时同样作废。
/// 清空时根页面本来就被推入的页面盖着（长按返回按钮直接跳回一级页面），这种返回取消不了，不留撤销。
///
/// 左栏消失后不马上撤销，等 `restoreConfirmDelay` 再确认：点返回后动画还没播完就切到别的 Tab 时，
/// 左栏也会先于右栏根页面消失，看起来和侧滑取消一样，但同一批里整个容器、根页面随后也会离开屏幕，
/// 撤销因此作废，回到这个 Tab 时停在一级页面，而不是又回到刚才返回的那一页。
struct TabSplitBackTracker<Route: Hashable> {
    /// 一次事件之后容器该对路径做什么。
    enum Action: Equatable {
        /// 路径不动。
        case keep
        /// 用户返回到了左栏：清空路径。
        case clear
        /// 刚才的返回取消了：把路径恢复成给出的值。
        case restore([Route])
        /// 返回可能取消了，等 `restoreConfirmDelay` 之后调用 `confirmRestore(path:)` 再定，期间别的消失事件可以让撤销作废。
        case confirmRestoreLater
    }

    /// 左栏消失后等多久再确认撤销：留给同一次切 Tab 里容器和右栏根页面的消失事件到齐。
    ///
    /// 侧滑取消时这段时间里路径仍是空的，和侧滑过程中一样，右栏一直在屏幕上，不影响显示。
    static var restoreConfirmDelay: Duration {
        .milliseconds(150)
    }

    /// 系统写回 `.sidebar` 和左栏出现最多相隔多久，才算同一次返回。
    ///
    /// 真的返回时两者只差几毫秒；返回一层时的误写之后，用户再动手返回通常远不止这么久。
    static var pairingWindow: Duration {
        .milliseconds(1_500)
    }

    /// 最近一次已知的布局是否收成一栏；每个事件都带上发生时的布局，和这里不同就按展开、收起切换处理。
    private(set) var isCollapsed: Bool

    /// 最近一次收成一栏、路径不为空时系统写回 `.sidebar` 的时间；配对用掉、作废后为 `nil`。
    private(set) var requestTime: ContinuousClock.Instant?

    /// 左栏在收成一栏的状态下出现的时间；左栏消失、从一级页面打开新页面、展开收起切换后为 `nil`。
    private(set) var sidebarAppearTime: ContinuousClock.Instant?

    /// 右栏根页面是否在屏幕上：出现后为 `true`；被推入的页面盖住、返回时滑出、切到别的 Tab 后为 `false`。
    private(set) var isDetailRootShown = false

    /// 最近一次清空前的路径，右栏根页面滑出前用来撤销；返回完成、打开新页面、展开收起切换、切走 Tab 后为 `nil`。
    private(set) var undoPath: [Route]?

    /// 左栏已经消失、撤销等着确认；确认过、作废后为 `false`。
    private(set) var isRestorePending = false

    /// 创建判定状态。
    ///
    /// - Parameter isCollapsed: 初始布局是否收成一栏；普通 iPhone 上一开始就是一栏。
    init(isCollapsed: Bool = true) {
        self.isCollapsed = isCollapsed
    }

    /// 布局在展开和收起之间切换：之前的请求、左栏出现和撤销都作废。
    ///
    /// 开合 iPhone Duo 时系统会重排两栏，左栏、右栏都可能出现、消失，系统也可能写回首选栏，这些都不代表用户返回了。
    /// - Parameter isCollapsed: 切换后是否收成一栏。
    /// - Returns: 布局是否真的变了；没变时什么都不做。
    @discardableResult
    mutating func layoutChanged(isCollapsed: Bool) -> Bool {
        guard isCollapsed != self.isCollapsed else { return false }
        self.isCollapsed = isCollapsed
        requestTime = nil
        sidebarAppearTime = nil
        undoPath = nil
        isRestorePending = false
        return true
    }

    /// 系统写回了首选栏。
    ///
    /// - Parameters:
    ///   - column: 系统写回的栏。
    ///   - isCollapsed: 写回时是否收成一栏。
    ///   - path: 写回时的路径。
    ///   - now: 写回的时间。
    /// - Returns: 容器该对路径做什么。
    mutating func systemSelectedColumn(
        _ column: NavigationSplitViewColumn,
        isCollapsed: Bool,
        path: [Route],
        now: ContinuousClock.Instant
    ) -> Action {
        layoutChanged(isCollapsed: isCollapsed)
        // 两栏时两栏都在屏幕上，用户不可能返回到左栏；路径为空本来就停在左栏；写回 `.detail` 说明右栏还在
        guard isCollapsed, !path.isEmpty, column == .sidebar else {
            requestTime = nil
            return .keep
        }
        requestTime = now
        return pairRequestWithSidebar(path: path, now: now)
    }

    /// 左栏出现了。
    ///
    /// - Parameters:
    ///   - isCollapsed: 出现时是否收成一栏；两栏时的出现不算。
    ///   - path: 出现时的路径。
    ///   - now: 出现的时间。
    /// - Returns: 容器该对路径做什么。
    mutating func sidebarAppeared(isCollapsed: Bool, path: [Route], now: ContinuousClock.Instant) -> Action {
        layoutChanged(isCollapsed: isCollapsed)
        guard isCollapsed else { return .keep }
        sidebarAppearTime = now
        return pairRequestWithSidebar(path: path, now: now)
    }

    /// 左栏消失了：被右栏盖住、侧滑返回松手取消、切到别的 Tab。
    ///
    /// 清空之后、右栏根页面滑出之前左栏就消失，多半是返回没有完成，但也可能是返回动画中途切走了 Tab，
    /// 所以只记下待确认，由容器稍后调用 `confirmRestore(path:)`。
    /// - Parameters:
    ///   - isCollapsed: 消失时是否收成一栏。
    ///   - path: 消失时的路径；已经不是清空后的空路径（例如打开了新页面）时不撤销。
    /// - Returns: 容器该对路径做什么。
    mutating func sidebarDisappeared(isCollapsed: Bool, path: [Route]) -> Action {
        layoutChanged(isCollapsed: isCollapsed)
        sidebarAppearTime = nil
        guard undoPath != nil, path.isEmpty else { return .keep }
        isRestorePending = true
        return .confirmRestoreLater
    }

    /// 左栏消失 `restoreConfirmDelay` 之后确认撤销。
    ///
    /// 这段时间里撤销没有作废（没切走 Tab、根页面没离开屏幕、没打开新页面、没有展开收起）、路径仍为空，
    /// 才把清空前的路径还回去。
    /// - Parameter path: 确认时的路径。
    /// - Returns: 撤销时为 `.restore`，否则 `.keep`。
    mutating func confirmRestore(path: [Route]) -> Action {
        guard isRestorePending else { return .keep }
        isRestorePending = false
        guard let undoPath, path.isEmpty, isDetailRootShown else { return .keep }
        self.undoPath = nil
        return .restore(undoPath)
    }

    /// 整个两栏容器离开了屏幕：切到了别的 Tab。
    ///
    /// 这时左栏、右栏的消失都是跟着 Tab 走的，不代表返回取消；之前的请求、左栏出现和撤销一并作废。
    mutating func containerDisappeared() {
        requestTime = nil
        sidebarAppearTime = nil
        undoPath = nil
        isRestorePending = false
    }

    /// 右栏根页面出现了。
    ///
    /// - Parameter isCollapsed: 出现时是否收成一栏。
    mutating func detailRootAppeared(isCollapsed: Bool) {
        layoutChanged(isCollapsed: isCollapsed)
        isDetailRootShown = true
    }

    /// 右栏根页面不在屏幕上了：返回时滑出、被推入的页面盖住、切到别的 Tab。
    ///
    /// 清空之后根页面滑出，返回就完成了，撤销作废。
    /// - Parameter isCollapsed: 消失时是否收成一栏。
    mutating func detailRootDisappeared(isCollapsed: Bool) {
        layoutChanged(isCollapsed: isCollapsed)
        isDetailRootShown = false
        undoPath = nil
    }

    /// 路径变了；容器在 `onChange(of: path)` 里调用，比引起变化的事件晚一点到。
    ///
    /// - 路径清空或从空变成有页面时，之前的请求说的是旧页面，作废；
    /// - 从一级页面打开新页面时，左栏马上要被盖住，它之前的出现属于上一次返回，不能再和推入过程中的写回配对；
    /// - 路径里有了页面（打开新页面、撤销清空）时，撤销作废。
    /// 右栏里推入、返回、根页面被代码直接换掉时都不动：留下的请求反正会过期。
    /// - Parameters:
    ///   - oldPath: 变化前的路径。
    ///   - newPath: 变化后的路径。
    mutating func pathChanged(from oldPath: [Route], to newPath: [Route]) {
        if oldPath.isEmpty || newPath.isEmpty {
            requestTime = nil
        }
        if oldPath.isEmpty, !newPath.isEmpty {
            sidebarAppearTime = nil
        }
        if !newPath.isEmpty {
            undoPath = nil
        }
    }

    /// 请求和左栏出现是否配成一对；配上时清空，请求随之用掉，同一次返回不会清空两次。
    ///
    /// 根页面还在屏幕上时记下清空前的路径，供返回取消时撤销。
    /// - Parameters:
    ///   - path: 当前路径；为空时没什么可清。
    ///   - now: 当前时间，也就是两件事里后到的那件的时间。
    /// - Returns: 容器该对路径做什么。
    private mutating func pairRequestWithSidebar(path: [Route], now: ContinuousClock.Instant) -> Action {
        guard isCollapsed,
              !path.isEmpty,
              let requestTime,
              let sidebarAppearTime,
              requestTime.duration(to: now) <= Self.pairingWindow,
              sidebarAppearTime.duration(to: now) <= Self.pairingWindow else { return .keep }
        self.requestTime = nil
        undoPath = isDetailRootShown ? path : nil
        return .clear
    }
}

#if DEBUG
extension TabSplitBackTracker {
    /// 调试日志里的一行判定状态；请求和左栏出现记为距现在的毫秒数，没有时记 `-`。
    ///
    /// - Parameter now: 当前时间。
    fileprivate func traceDescription(now: ContinuousClock.Instant) -> String {
        func age(_ time: ContinuousClock.Instant?) -> String {
            guard let time else { return "-" }
            let components = time.duration(to: now).components
            return "\(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)ms"
        }
        return "collapsed=\(isCollapsed ? 1 : 0) req=\(age(requestTime)) sidebar=\(age(sidebarAppearTime)) "
            + "root=\(isDetailRootShown ? 1 : 0) undo=\(undoPath.map { "\($0.count)" } ?? "-")"
            + (isRestorePending ? " restorePending" : "")
    }
}
#endif

/// 装 `TabSplitBackTracker` 的引用：放进 `@State` 后改它不会让两栏容器重绘。
///
/// 系统写回首选栏、页面出现消失时都要改判定状态，这些变化本身不影响界面；收成一栏返回的动画进行中若因此重绘，
/// 分栏视图会重新读首选栏，可能和系统刚写回的值打架。
private final class TabSplitBackTrackerBox<Route: Hashable> {
    /// 当前的判定状态。
    var tracker = TabSplitBackTracker<Route>()
}

private extension NavigationSplitViewColumn {
    /// 调试日志里的栏名；只在拼日志时用到。
    var traceName: String {
        if self == .sidebar {
            "sidebar"
        } else if self == .detail {
            "detail"
        } else {
            "content"
        }
    }
}

#if DEBUG
/// 两栏导航的调试日志：系统写回首选栏、右栏路径写回、左栏和右栏根页面出现消失、布局切换和清空路径的先后顺序。
///
/// 收成一栏返回出问题时在模拟器上抓：
/// `log stream --predicate 'subsystem == "top.yado1225.yadoA" AND category == "TabSplitNavigation"' --level debug`。
private enum TabSplitDiagnostics {
    /// 两栏导航的日志通道。
    static let logger = Logger(subsystem: "top.yado1225.yadoA", category: "TabSplitNavigation")
}
#endif

// MARK: - 环境中的导航动作

/// 一级页面打开二级页面的动作：由两栏容器提供给左栏，把右栏换成这一页。
///
/// 只在两栏容器的左栏里有值；其他地方取到 `nil`，`TabRouteLink` 此时退回普通的 `NavigationLink(value:)`。
struct TabRouteOpenAction {
    /// 容器收到路由后的处理；路由类型不是这个 Tab 的时忽略。
    fileprivate let handler: (AnyHashable) -> Void

    /// 打开一个二级页面。
    ///
    /// - Parameter route: 这个 Tab 的路由值。
    func callAsFunction<Route: Hashable>(_ route: Route) {
        handler(AnyHashable(route))
    }
}

/// 右栏根页面关掉自己的动作：清空这个 Tab 的路径。
///
/// 两栏展开时右栏根页面调用 `dismiss()` 没有效果，需要关掉自己的页面（例如删除流水、保存记一笔之后）改用它；
/// 收成一栏时同样有效，效果与返回一致。只提供给右栏的根页面：右栏里推入的页面、弹层里的页面都取到 `nil`，应继续用 `dismiss()`。
struct TabDetailCloseAction {
    /// 容器清空路径的处理。
    fileprivate let handler: () -> Void

    /// 关掉右栏根页面。
    func callAsFunction() {
        handler()
    }
}

/// `TabRouteOpenAction` 的环境键。
private nonisolated struct TabRouteOpenKey: EnvironmentKey {
    static var defaultValue: TabRouteOpenAction? { nil }
}

/// 右栏当前根页面路由的环境键。
private nonisolated struct TabRouteSelectionKey: EnvironmentKey {
    static var defaultValue: AnyHashable? { nil }
}

/// `TabDetailCloseAction` 的环境键。
private nonisolated struct TabDetailCloseKey: EnvironmentKey {
    static var defaultValue: TabDetailCloseAction? { nil }
}

extension EnvironmentValues {
    /// 一级页面打开二级页面的动作；只在两栏容器的左栏里有值。
    nonisolated var tabRouteOpen: TabRouteOpenAction? {
        get { self[TabRouteOpenKey.self] }
        set { self[TabRouteOpenKey.self] = newValue }
    }

    /// 两栏展开时右栏正在显示的根页面路由，左栏据此标出当前打开的那一行；收成一栏时为 `nil`。
    nonisolated var tabRouteSelection: AnyHashable? {
        get { self[TabRouteSelectionKey.self] }
        set { self[TabRouteSelectionKey.self] = newValue }
    }

    /// 右栏根页面关掉自己的动作；只有右栏的根页面取得到，其他页面为 `nil`。
    nonisolated var tabDetailClose: TabDetailCloseAction? {
        get { self[TabDetailCloseKey.self] }
        set { self[TabDetailCloseKey.self] = newValue }
    }
}

// MARK: - 一级页面的入口

/// 一级页面上进入二级页面的入口：在两栏容器里点了换掉右栏，其他地方退回 `NavigationLink(value:)`。
///
/// 在两栏容器里是一个 `Button`（UI 测试仍按 `app.buttons[...]` 找到它），外观、无障碍标识和其他修饰符由调用方照旧挂在外面；
/// 两栏展开时右栏正显示这一页，会在标签底下垫一层浅色，并带上「已选中」的无障碍特征。
struct TabRouteLink<Route: Hashable, Content: View>: View {
    @Environment(\.tabRouteOpen) private var openRoute
    @Environment(\.tabRouteSelection) private var selectedRoute

    /// 要打开的页面。
    private let route: Route

    /// 两栏展开时是否标出当前打开的这一行；导航栏按钮、汇总卡片这类入口不标。
    private let marksSelection: Bool

    /// 选中底色比标签外扩的距离；列表行贴得很紧时外扩一点，卡片里自带内边距的行可以传负值往里收。
    ///
    /// 外扩时可点区域跟着外扩：原来的 `NavigationLink` 整行都能点，换成 `.plain` 样式的按钮后只有标签本身能点，行的上下留白靠它补回来。
    private let selectionOutset: CGFloat

    /// 入口的标签。
    private let content: Content

    /// 创建一级页面的入口。
    ///
    /// - Parameters:
    ///   - route: 要打开的页面。
    ///   - marksSelection: 两栏展开时是否标出当前打开的这一行。
    ///   - selectionOutset: 选中底色比标签外扩的距离。
    ///   - label: 入口的标签。
    init(
        value route: Route,
        marksSelection: Bool = true,
        selectionOutset: CGFloat = 0,
        @ViewBuilder label: () -> Content
    ) {
        self.route = route
        self.marksSelection = marksSelection
        self.selectionOutset = selectionOutset
        content = label()
    }

    /// 右栏当前是否正显示这一页。
    private var isSelected: Bool {
        marksSelection && selectedRoute == AnyHashable(route)
    }

    var body: some View {
        if let openRoute {
            Button {
                openRoute(route)
            } label: {
                content
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                                .padding(-selectionOutset)
                        }
                    }
                    // 与原来的 NavigationLink 一样整块可点，留白处也算；只放大点按区域，长按预览仍按标签本身的形状
                    .contentShape(.interaction, Rectangle().inset(by: -max(selectionOutset, 0)))
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            NavigationLink(value: route) {
                content
            }
        }
    }
}

// MARK: - 两栏容器

/// 记账、账户、“我的”三个 Tab 共用的两栏导航：左栏是 Tab 原有的一级页面，右栏是二级页面。
///
/// 所有 iPhone 上都用同一个 `NavigationSplitView`，不按宽度在导航栈和两栏之间切换：切换会重建页面，
/// iPhone Duo 打开、合上时正在填写的记一笔等内容会丢；同一个分栏视图由系统展开、收起，页面一直保留。
/// 宽度不够时把水平尺寸类别改成 compact，让分栏视图收成一栏，行为与原来的导航栈一致（推入动画、返回按钮、侧滑返回）。
/// 两栏里的页面也都按 compact 排版，保持 iPhone 的版式。
///
/// 路径数组是唯一的数据来源，拆分方式见 `TabSplitPath`。左栏通过 `TabRouteLink`（环境里的 `tabRouteOpen`）换掉右栏；
/// 右栏根页面要关掉自己时用环境里的 `tabDetailClose`。收成一栏时系统写回的首选栏不直接改路径，
/// 由 `TabSplitBackTracker` 确认用户真的返回到了左栏才清空。
struct TabSplitNavigation<Route: TabSplitRoute, Sidebar: View, Placeholder: View, Destination: View>: View {
    /// 系统给出的水平尺寸类别；两栏展开时原样交给分栏视图。
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// 这个 Tab 的导航路径，由根导航持有。
    @Binding private var path: [Route]

    /// 展开、收起变化时通知根导航，用于语音入口的显示规则；首次出现时也会通知一次。
    private let onExpandedChange: @MainActor (Bool) -> Void

    /// 左栏：Tab 的一级页面。
    private let sidebar: Sidebar

    /// 两栏展开、右栏还没打开任何页面时的占位。
    private let placeholder: Placeholder

    /// 路由对应的页面；右栏根页面和右栏里推入的页面共用。
    private let destination: (Route) -> Destination

    /// 两栏展开时始终两栏都显示；去掉了侧栏开关，系统改了也会改回来。
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// 收成一栏时最近一次显示过的右栏根页面。
    ///
    /// 路径清空时右栏根页面可能还在屏幕上（页面自己关掉、正在滑出），要等它离开屏幕再换成占位，
    /// 否则返回动画里会闪一下占位；根页面露在屏幕上时绝不清掉，见 `dropRetainedHeadWhenHidden()`。
    @State private var retainedHead: Route?

    /// 收成一栏时判断用户是否真的返回到了左栏，见 `TabSplitBackTracker`；装在引用里，改它不会让视图重绘。
    @State private var backTracker = TabSplitBackTrackerBox<Route>()

    /// 创建两栏导航。
    ///
    /// - Parameters:
    ///   - path: 这个 Tab 的导航路径。
    ///   - onExpandedChange: 展开、收起变化时的通知。
    ///   - sidebar: 左栏的一级页面。
    ///   - placeholder: 右栏没有页面时的占位。
    ///   - destination: 路由对应的页面。
    init(
        path: Binding<[Route]>,
        onExpandedChange: @escaping @MainActor (Bool) -> Void = { _ in },
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder placeholder: () -> Placeholder,
        @ViewBuilder destination: @escaping (Route) -> Destination
    ) {
        _path = path
        self.onExpandedChange = onExpandedChange
        self.sidebar = sidebar()
        self.placeholder = placeholder()
        self.destination = destination
    }

    var body: some View {
        // 用 GeometryReader 而不是 onGeometryChange：首帧就拿到宽度，内屏打开时启动不会先收成一栏再展开
        GeometryReader { proxy in
            let isExpanded = TabSplitLayout.isExpanded(
                containerWidth: proxy.size.width,
                horizontalSizeClass: horizontalSizeClass
            )
            splitView(isExpanded: isExpanded)
                .onChange(of: isExpanded, initial: true) { _, expanded in
                    onExpandedChange(expanded)
                    if backTracker.tracker.layoutChanged(isCollapsed: !expanded) {
                        trace("layout \(expanded ? "expanded" : "collapsed")")
                    }
                }
        }
        // 切到别的 Tab：左栏、右栏随之消失都不算返回取消
        .onDisappear {
            backTracker.tracker.containerDisappeared()
            trace("container disappear")
        }
    }

    /// 分栏视图本体。
    ///
    /// - Parameter isExpanded: 是否展开成两栏。
    private func splitView(isExpanded: Bool) -> some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: compactColumn(isExpanded: isExpanded)
        ) {
            sidebar
                .environment(\.tabRouteOpen, TabRouteOpenAction { value in
                    guard let route = value.base as? Route else { return }
                    update(to: TabSplitPath.opening(route))
                })
                .environment(\.tabRouteSelection, isExpanded ? path.first.map { AnyHashable($0) } : nil)
                // 左栏保持 iPhone 的版式
                .environment(\.horizontalSizeClass, .compact)
                .navigationSplitViewColumnWidth(
                    min: TabSplitLayout.sidebarMinimumWidth,
                    ideal: TabSplitLayout.sidebarIdealWidth,
                    max: TabSplitLayout.sidebarMaximumWidth
                )
                .toolbar(removing: .sidebarToggle)
                // 收成一栏时左栏真的露出来，才可能是用户返回到了一级页面
                .onAppear { sidebarAppeared(isExpanded: isExpanded) }
                .onDisappear { sidebarDisappeared(isExpanded: isExpanded) }
        } detail: {
            NavigationStack(path: tailPath) {
                detailRoot(isExpanded: isExpanded)
                    .navigationDestination(for: Route.self) { route in
                        destination(route)
                            // 右栏里推入的页面不是根页面，关掉自己要用 dismiss
                            .environment(\.tabDetailClose, nil)
                    }
            }
            // 右栏的页面同样按 iPhone 的版式排布
            .environment(\.horizontalSizeClass, .compact)
        }
        .navigationSplitViewStyle(.balanced)
        // 宽度不够时让分栏视图按 compact 收成一栏；够宽时交还系统的尺寸类别
        .environment(\.horizontalSizeClass, isExpanded ? horizontalSizeClass : .compact)
        .onChange(of: path) { oldPath, newPath in
            backTracker.tracker.pathChanged(from: oldPath, to: newPath)
            trace("path \(oldPath.count)->\(newPath.count)")
        }
        .onChange(of: path.first, initial: true) { _, head in
            if let head {
                retainedHead = head
            } else if isExpanded {
                // 两栏时右栏直接换成占位，不需要等滑出
                retainedHead = nil
            } else {
                dropRetainedHeadWhenHidden()
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            if visibility != .all {
                columnVisibility = .all
            }
        }
    }

    /// 右栏的根页面：路径第一项对应的页面；没有时两栏显示占位，一栏时先留着刚返回的页面等它滑出。
    ///
    /// - Parameter isExpanded: 是否展开成两栏。
    @ViewBuilder
    private func detailRoot(isExpanded: Bool) -> some View {
        if let head = path.first ?? (isExpanded ? nil : retainedHead) {
            destination(head)
                .environment(\.tabDetailClose, TabDetailCloseAction {
                    trace("clear: detail root closed itself")
                    update(to: [])
                })
                // 换一页就是一个新页面，不沿用上一页的状态
                .id(head)
                .onAppear { detailRootAppeared(isExpanded: isExpanded) }
                .onDisappear { detailRootDisappeared(isExpanded: isExpanded) }
        } else {
            placeholder
        }
    }

    /// 右栏导航栈的路径：完整路径去掉第一项。
    private var tailPath: Binding<[Route]> {
        Binding(
            get: { TabSplitPath.tail(of: path) },
            set: { newTail in
                trace("tail write \(TabSplitPath.tail(of: path).count)->\(newTail.count)")
                update(to: TabSplitPath.replacingTail(of: path, with: newTail))
            }
        )
    }

    /// 收成一栏时的首选栏：读取时始终按路径给出，系统写回时只交给判定状态，与左栏出现配上对才清空路径。
    ///
    /// 系统写回的值不会原样反映到读取上，免得右栏里返回一层时界面被一次误写带走。
    /// - Parameter isExpanded: 是否展开成两栏；展开时系统写回的值一律不算。
    private func compactColumn(isExpanded: Bool) -> Binding<NavigationSplitViewColumn> {
        Binding(
            get: { TabSplitPath.compactColumn(for: path) },
            set: { column in
                let now = ContinuousClock.now
                let action = backTracker.tracker.systemSelectedColumn(
                    column,
                    isCollapsed: !isExpanded,
                    path: path,
                    now: now
                )
                trace("system column=\(column.traceName)", now: now)
                apply(action)
            }
        )
    }

    // MARK: 返回判定的事件

    /// 左栏出现：收成一栏时可能是用户返回到了一级页面，交给判定状态和系统写回配对。
    ///
    /// - Parameter isExpanded: 出现时是否展开成两栏。
    private func sidebarAppeared(isExpanded: Bool) {
        let now = ContinuousClock.now
        let action = backTracker.tracker.sidebarAppeared(isCollapsed: !isExpanded, path: path, now: now)
        trace("sidebar appear", now: now)
        apply(action)
    }

    /// 左栏消失：被右栏盖住、侧滑返回松手取消、切到别的 Tab；刚清空、返回还没完成时稍后确认是否撤销清空。
    ///
    /// - Parameter isExpanded: 消失时是否展开成两栏。
    private func sidebarDisappeared(isExpanded: Bool) {
        let action = backTracker.tracker.sidebarDisappeared(isCollapsed: !isExpanded, path: path)
        trace("sidebar disappear")
        apply(action)
    }

    /// 右栏根页面出现。
    ///
    /// - Parameter isExpanded: 出现时是否展开成两栏。
    private func detailRootAppeared(isExpanded: Bool) {
        backTracker.tracker.detailRootAppeared(isCollapsed: !isExpanded)
        trace("detail root appear")
    }

    /// 右栏根页面离开屏幕：清空之后到这里返回才算完成；路径为空时顺带换成占位。
    ///
    /// - Parameter isExpanded: 离开时是否展开成两栏。
    private func detailRootDisappeared(isExpanded: Bool) {
        backTracker.tracker.detailRootDisappeared(isCollapsed: !isExpanded)
        trace("detail root disappear")
        // 根页面已经滑出屏幕，路径为空时可以换成占位；右栏里推入了页面、切到别的 Tab 时路径不为空，保留
        if path.isEmpty {
            retainedHead = nil
        }
    }

    /// 按判定结果改路径：清空，或者把取消了的返回撤销回去；撤销要等一会儿确认时，到点再问一次判定状态。
    ///
    /// 撤销时右栏根页面一直没离开屏幕，`retainedHead` 还是它，页面不会重建。
    /// - Parameter action: 判定状态给出的动作。
    private func apply(_ action: TabSplitBackTracker<Route>.Action) {
        switch action {
        case .keep:
            break
        case .clear:
            trace("clear: returned to sidebar")
            update(to: [])
        case let .restore(oldPath):
            trace("restore: return cancelled, back to \(oldPath.count)")
            update(to: oldPath)
        case .confirmRestoreLater:
            Task {
                try? await Task.sleep(for: TabSplitBackTracker<Route>.restoreConfirmDelay)
                let confirmed = backTracker.tracker.confirmRestore(path: path)
                if confirmed == .keep {
                    trace("restore dropped")
                }
                apply(confirmed)
            }
        }
    }

    /// 收成一栏、路径清空后把右栏换成占位，但绝不在右栏根页面还露在屏幕上时换。
    ///
    /// 根页面还在屏幕上（返回到左栏、页面自己关掉，正在滑出）时什么也不做，等它离开屏幕后的 `onDisappear`；
    /// 返回中途取消、路径被撤销回去时也就不会换掉它。
    /// 已经不在屏幕上（被推入的页面盖着时整条收起、在别的 Tab 里被清空）时，
    /// 稍等返回动画结束再换，免得动画进行中改掉右栏的根页面；到时再确认一次路径仍为空、根页面仍不在屏幕上。
    private func dropRetainedHeadWhenHidden() {
        guard retainedHead != nil, !backTracker.tracker.isDetailRootShown else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if path.isEmpty, !backTracker.tracker.isDetailRootShown {
                retainedHead = nil
            }
        }
    }

    /// 只在路径真的变了时写回，系统重复写入同样的值时不触发多余的刷新。
    ///
    /// - Parameter newPath: 新路径。
    private func update(to newPath: [Route]) {
        guard newPath != path else { return }
        path = newPath
    }

    /// 记一条调试日志：路由类型（区分三个 Tab）、事件、当前路径层数和判定状态。只在 DEBUG 包里输出。
    ///
    /// - Parameters:
    ///   - event: 事件描述；只在 DEBUG 包里求值。
    ///   - now: 事件发生的时间，用来算请求和左栏出现过去了多久；不传时取当前时间。
    private func trace(_ event: @autoclosure () -> String, now: ContinuousClock.Instant = .now) {
        #if DEBUG
        let state = backTracker.tracker.traceDescription(now: now)
        let message = "\(Route.self) \(event()) path=\(path.count) \(state)"
        TabSplitDiagnostics.logger.debug("\(message, privacy: .public)")
        #endif
    }
}

// MARK: - 右栏占位

/// 两栏展开、右栏还没打开任何页面时的占位：一幅手绘插画加一行提示，底色仍是纸色。
struct TabDetailPlaceholder<Illustration: View>: View {
    @Environment(\.locale) private var locale

    /// 提示文案的本地化键。
    private let messageKey: String

    /// 提示上方的插画。
    private let illustration: Illustration

    /// 创建右栏占位。
    ///
    /// - Parameters:
    ///   - messageKey: 提示文案的本地化键。
    ///   - illustration: 提示上方的插画。
    init(messageKey: String, @ViewBuilder illustration: () -> Illustration) {
        self.messageKey = messageKey
        self.illustration = illustration()
    }

    var body: some View {
        ContentUnavailableView {
            illustration
        } description: {
            Text(AccountLocalization.string(messageKey, locale: locale))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperPage()
        .navigationBarTitleDisplayMode(.inline)
        // 先声明为容器，标识才落在整个占位上
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-detail-placeholder")
    }
}
