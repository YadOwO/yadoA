import SwiftUI

/// 宽屏单栏时滚动内容的阅读宽度：内容居中排成约 620pt 一栏，纸色底和滚动条仍铺满整个容器。
///
/// 620pt 与表单页已有的 `.frame(maxWidth: 620)` 一致，算上页面左右各 20pt 的留白。
/// 普通 iPhone 宽度、两栏里的单栏都不超过这个宽度，不受影响。
enum ReadableContentWidth {
    /// 内容一栏的最大宽度，含页面自己的左右留白。
    static let maxContentWidth: CGFloat = 620

    /// 分组列表在普通宽度下的左右边距；宽屏时列表的边距由这里改写，需要把这段留白补回去，与 ScrollView 页面对齐。
    static let listSideMargin: CGFloat = 20

    /// 容器宽度对应的左右外边距。
    ///
    /// - Parameters:
    ///   - containerWidth: 滚动容器的宽度。
    ///   - sideMargin: 内容自己不带、要由外边距补上的左右留白；自己已经加了 20pt 内边距的 ScrollView 传 0，分组列表传 `listSideMargin`。
    /// - Returns: 容器宽于 `maxContentWidth` 时的左右外边距；不宽于它时为 `nil`，保持系统默认的边距。
    static func horizontalMargin(containerWidth: CGFloat, sideMargin: CGFloat) -> CGFloat? {
        guard containerWidth > maxContentWidth else { return nil }
        return (containerWidth - maxContentWidth) / 2 + sideMargin
    }
}

extension View {
    /// 给一级页面的滚动容器限定阅读宽度：宽屏时左右加上对称的内容外边距，把内容居中排成约 620pt 一栏。
    ///
    /// 用 `contentMargins(_:_:for: .scrollContent)` 而不是给容器加 frame：滚动条贴在屏幕边上，纸色底和滚动手势铺满整个宽度；
    /// 不够宽时不改写任何边距，列表保持系统默认的样子。外边距改变时不会重建滚动视图，滚动位置保留。
    /// - Parameter sideMargin: 内容自己不带、要由外边距补上的左右留白；分组列表传 `ReadableContentWidth.listSideMargin`，
    ///   自己已经加了 20pt 内边距的 ScrollView 用默认的 0。
    func readableContentWidth(sideMargin: CGFloat = 0) -> some View {
        modifier(ReadableContentWidthModifier(sideMargin: sideMargin))
    }
}

/// 量出滚动容器的宽度，宽屏时加上对称的内容外边距。
private struct ReadableContentWidthModifier: ViewModifier {
    /// 内容自己不带、要由外边距补上的左右留白。
    let sideMargin: CGFloat

    /// 滚动容器当前的宽度；首帧前为 0，按不够宽处理。
    @State private var containerWidth: CGFloat = 0

    func body(content: Content) -> some View {
        let margin = ReadableContentWidth.horizontalMargin(containerWidth: containerWidth, sideMargin: sideMargin)
        // 不够宽时边集为空：修饰符一直挂着、视图身份不变，但不改写系统默认的边距
        let edges: Edge.Set = margin == nil ? [] : .horizontal
        content
            .contentMargins(edges, margin ?? 0, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                containerWidth = width
            }
    }
}
