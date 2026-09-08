import Foundation
import Testing
@testable import yadoA

@Suite("首页月份边界手势")
@MainActor
struct HomeMonthScrollInteractionTests {
    @Test("短列表静止和轻微回弹不会达到切换阈值")
    func shortContentNeedsActualOverscroll() {
        #expect(pull(offset: -20, height: 120) == nil)
        #expect(pull(offset: 10, height: 120) == .init(direction: .earlier, isReady: false))
        #expect(pull(offset: 44, height: 120) == .init(direction: .earlier, isReady: true))
        #expect(pull(offset: -84, height: 120) == .init(direction: .later, isReady: true))
    }

    @Test("长列表要超过含底部 inset 的真实边界")
    func longContentRespectsInsets() {
        #expect(pull(offset: 500, height: 1_000) == nil)
        #expect(pull(offset: 530, height: 1_000) == nil)
        #expect(pull(offset: 594, height: 1_000) == .init(direction: .earlier, isReady: true))
    }

    @Test("主动拉动松手后只提交一次，惯性回弹不改变方向")
    func commitsOnceAfterRelease() {
        var interaction = HomeMonthScrollInteraction()
        interaction.beginDragging()
        interaction.update(.init(direction: .earlier, isReady: true))
        interaction.endDragging()
        interaction.update(.init(direction: .later, isReady: true))
        #expect(interaction.settle() == .earlier)
        #expect(interaction.settle() == nil)
    }

    @Test("惯性越界及程序滚动不能单独触发换月")
    func ignoresMomentumWithoutArmedDrag() {
        var interaction = HomeMonthScrollInteraction()
        interaction.update(.init(direction: .earlier, isReady: true))
        interaction.endDragging()
        #expect(interaction.settle() == nil)
        interaction.beginDragging()
        interaction.update(nil)
        interaction.endDragging()
        interaction.update(.init(direction: .later, isReady: true))
        #expect(interaction.settle() == nil)
    }

    @Test("越过阈值后拉回会取消，未松手也不能提交")
    func retractingOrHoldingDoesNotCommit() {
        var interaction = HomeMonthScrollInteraction()
        interaction.beginDragging()
        interaction.update(.init(direction: .earlier, isReady: true))
        #expect(interaction.settle() == nil)
        interaction.beginDragging()
        interaction.update(.init(direction: .earlier, isReady: true))
        interaction.update(.init(direction: .earlier, isReady: false))
        interaction.endDragging()
        #expect(interaction.settle() == nil)
    }

    @Test("再次触摸拖动会取消尚在回弹的旧请求")
    func newDragCancelsPendingSwitch() {
        var interaction = HomeMonthScrollInteraction()
        interaction.beginDragging()
        interaction.update(.init(direction: .earlier, isReady: true))
        interaction.endDragging()
        interaction.beginDragging()
        interaction.endDragging()
        #expect(interaction.settle() == nil)
    }

    /// 模拟含顶部和底部安全边距的滚动区域。
    private func pull(offset: CGFloat, height: CGFloat) -> HomeMonthScrollInteraction.Pull? {
        HomeMonthScrollInteraction.pull(
            offsetY: offset,
            contentHeight: height,
            containerHeight: 500,
            topInset: 20,
            bottomInset: 30
        )
    }
}
