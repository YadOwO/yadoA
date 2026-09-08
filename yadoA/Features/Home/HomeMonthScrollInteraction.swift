import Foundation

/// 首页边界拉动状态，只在主动拖动达到阈值后接受一次换月请求。
struct HomeMonthScrollInteraction {
    /// 上下边界对应的月份浏览方向。
    enum Direction: Equatable {
        /// 底部上拉，查看更早的最近有数据月份。
        case earlier
        /// 顶部下拉，查看更晚的最近有数据月份。
        case later
    }

    /// 几何数据归约后的提示状态，避免每个滚动像素都刷新列表。
    struct Pull: Equatable {
        /// 当前越过的滚动边界对应的月份方向。
        let direction: Direction
        /// 是否达到松手可提交的拉动距离。
        let isReady: Bool
    }

    /// 当前手势提示；回弹阶段保留松手时的状态。
    private(set) var pull: Pull?

    /// 是否正在接受手指拖动，而非惯性或程序滚动。
    private var isDragging = false

    /// 松手时锁定的目标方向，等待原生回弹结束后提交。
    private var pendingDirection: Direction?

    /// 从原生滚动几何计算边界拉动，短列表的底部至少与顶部重合。
    static func pull(
        offsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> Pull? {
        let top = -topInset
        let bottom = max(top, contentHeight + bottomInset - containerHeight)
        let topDistance = top - offsetY
        let bottomDistance = offsetY - bottom
        let distance = max(topDistance, bottomDistance)
        guard distance >= 8 else { return nil }
        return Pull(
            direction: topDistance > bottomDistance ? .later : .earlier,
            isReady: distance >= 64
        )
    }

    /// 新的主动拖动取消尚未完成的上一轮请求。
    mutating func beginDragging() {
        isDragging = true
        pendingDirection = nil
        pull = nil
    }

    /// 仅采纳手指拖动产生的状态，回弹越界不会触发换月。
    mutating func update(_ value: Pull?) {
        guard isDragging else { return }
        pull = value
    }

    /// 松手锁定请求；曾经越过阈值但又拉回的手势会取消。
    mutating func endDragging() {
        guard isDragging else { return }
        isDragging = false
        pendingDirection = pull?.isReady == true ? pull?.direction : nil
    }

    /// 回弹结束后消费请求，后续空闲回调不会重复切换。
    mutating func settle() -> Direction? {
        let direction = pendingDirection
        self = Self()
        return direction
    }
}
