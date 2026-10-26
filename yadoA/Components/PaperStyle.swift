import SwiftUI

extension View {
    /// 把页面底色换成账本的纸色，并让页面内的系统列表、表单透出这层纸色。
    ///
    /// 纸色与应用图标的底色一致：浅色外观是暖白的纸，深色外观是墨底。
    /// 卡片和列表行继续使用系统分组色，保证与原生控件的层级关系不变。
    func paperPage() -> some View {
        scrollContentBackground(.hidden)
            .background(Color(.paperBackground).ignoresSafeArea())
    }

    /// 把一栏内容固定在滚动内容顶部，内容从它下方滑过并在边缘柔和淡出。
    ///
    /// - Parameters:
    ///   - isEnabled: 是否启用顶部栏；关闭时不占用任何空间。
    ///   - bar: 顶部栏内容。
    func paperTopBar<Bar: View>(isEnabled: Bool = true, @ViewBuilder bar: @escaping () -> Bar) -> some View {
        modifier(PaperTopBar(isEnabled: isEnabled, bar: bar))
    }

    /// 让列表行直接落在纸面上：去掉系统行底和分隔线，在行底画一条账本细线。
    ///
    /// - Parameters:
    ///   - seed: 细线的笔迹种子，同一行每次画成同一个样子。
    ///   - showsRule: 一段里的最后一行传 `false`，不画线。
    func ledgerRow(seed: UInt64, showsRule: Bool = true) -> some View {
        listRowBackground(
            HandDrawnRule(seed: seed)
                .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .frame(height: 3)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 2)
                .opacity(showsRule ? 1 : 0)
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 9, leading: 2, bottom: 9, trailing: 2))
    }

    /// 一段明细开头的重线，放在衬线标题下方，与首页日期标题下的那条一致。
    func ledgerHeadingRule(seed: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            self
            HandDrawnRule(seed: seed)
                .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(height: 3)
                .accessibilityHidden(true)
        }
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 2, trailing: 2))
    }
}

/// 固定在滚动内容顶部的纸面栏。
///
/// iOS 26 使用系统的 `safeAreaBar`，由滚动边缘效果处理内容淡出；
/// 更早的系统用 `safeAreaInset` 加一层向下渐隐的纸色底得到相近的效果。
private struct PaperTopBar<Bar: View>: ViewModifier {
    /// 是否启用顶部栏；关闭时不占用任何空间。
    let isEnabled: Bool

    /// 顶部栏内容。
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .safeAreaBar(edge: .top, spacing: 0) {
                    if isEnabled {
                        bar()
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                if isEnabled {
                    bar().background {
                        // 上方是实的纸色，靠近内容的一小段渐隐，让列表滑入时不出现硬边。
                        LinearGradient(
                            stops: [
                                .init(color: Color(.paperBackground), location: 0),
                                .init(color: Color(.paperBackground), location: 0.86),
                                .init(color: Color(.paperBackground).opacity(0), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
            }
        }
    }
}
