import SwiftUI

/// 卡片、输入框和悬浮控件共用的底色：iOS 26 用 Liquid Glass，iOS 18 降级为常规材质。
///
/// 页面里不要再各自写一份 `#available(iOS 26, *)` + `glassEffect` 的降级修饰符，统一走
/// `glassSurface(in:isInteractive:)` 或 `floatingGlassSurface(in:isInteractive:)`。
private struct GlassSurface<SurfaceShape: Shape>: ViewModifier {
    /// 底色形状。
    let shape: SurfaceShape

    /// 是否使用可交互玻璃；按钮和输入框按下时有系统反馈。
    let isInteractive: Bool

    /// iOS 18 降级时是否补一层投影：悬浮在明细上的控件靠投影表达层级，嵌在页面里的卡片不需要。
    let hasFallbackShadow: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
        } else if hasFallbackShadow {
            content
                .background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    /// 给页面内的卡片或输入框加上玻璃或材质底色。
    ///
    /// - Parameters:
    ///   - shape: 底色形状。
    ///   - isInteractive: 是否使用可交互的玻璃效果。
    func glassSurface<SurfaceShape: Shape>(in shape: SurfaceShape, isInteractive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, isInteractive: isInteractive, hasFallbackShadow: false))
    }

    /// 给悬浮在内容上的控件（语音麦克风、会话卡片、聊天输入栏等）加上玻璃或材质底色；iOS 18 额外加投影表达层级。
    ///
    /// - Parameters:
    ///   - shape: 底色形状。
    ///   - isInteractive: 是否使用可交互的玻璃效果。
    func floatingGlassSurface<SurfaceShape: Shape>(in shape: SurfaceShape, isInteractive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, isInteractive: isInteractive, hasFallbackShadow: true))
    }
}
