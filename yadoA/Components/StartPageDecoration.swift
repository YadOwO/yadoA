import SwiftUI

/// 一小段和纸胶带：长边平直，两条短边是撕出来的锯齿。
///
/// 填充使用，用来把启动页的汇总框“贴”在纸面上。
struct HandDrawnTape: Shape {
    /// 笔迹种子，决定锯齿的深浅。
    var seed: UInt64 = 0

    /// 每条短边上的锯齿数量。
    private let toothCount = 3

    func path(in rect: CGRect) -> Path {
        var jitter = HandDrawnJitter(seed: seed)
        let toothDepth = min(rect.width * 0.08, 3)
        let toothHeight = rect.height / CGFloat(toothCount)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // 右侧撕口：自上而下，齿尖向内。
        for index in 0..<toothCount {
            let top = rect.minY + toothHeight * CGFloat(index)
            path.addLine(to: CGPoint(
                x: rect.maxX - toothDepth * (1 + jitter.next() * 0.4),
                y: top + toothHeight / 2
            ))
            path.addLine(to: CGPoint(x: rect.maxX, y: top + toothHeight))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        // 左侧撕口：自下而上。
        for index in 0..<toothCount {
            let bottom = rect.maxY - toothHeight * CGFloat(index)
            path.addLine(to: CGPoint(
                x: rect.minX + toothDepth * (1 + jitter.next() * 0.4),
                y: bottom - toothHeight / 2
            ))
            path.addLine(to: CGPoint(x: rect.minX, y: bottom - toothHeight))
        }
        path.closeSubpath()
        return path
    }
}

/// 启动页汇总框的装饰：框后垫一张错开的淡色纸，左上角贴一段胶带。
///
/// 只改变观感，不增加任何信息；关闭时不占用空间，页面与未装饰时完全一致。
private struct StartPageDecoration: ViewModifier {
    /// 当前页面是否为用户选择的启动页面。
    let isEnabled: Bool

    /// 被装饰汇总框的圆角，垫纸沿用同样的圆角。
    let cornerRadius: CGFloat

    /// 垫纸与胶带的笔迹种子。
    let seed: UInt64

    /// 垫纸相对汇总框向右下错开的距离。
    private static let backingOffset = CGSize(width: 6, height: 7)

    func body(content: Content) -> some View {
        content
            // 左上角贴一段胶带，一半压在框上、一半落在纸面上。
            .overlay(alignment: .topLeading) {
                tape(seed: seed, angle: -5).offset(x: 22, y: -9)
            }
            .background {
                HandDrawnBox(cornerRadius: cornerRadius, seed: seed &+ 1)
                    .fill(Color.accentColor.opacity(0.24))
                    .offset(Self.backingOffset)
                    .opacity(isEnabled ? 1 : 0)
                    .accessibilityHidden(true)
            }
            // 垫纸错开的部分计入布局，避免被列表行或顶部栏裁掉。
            .padding(.trailing, isEnabled ? Self.backingOffset.width : 0)
            .padding(.bottom, isEnabled ? Self.backingOffset.height : 0)
            // 给伸出框顶的胶带留出位置。
            .padding(.top, isEnabled ? 6 : 0)
    }

    /// 一段倾斜的胶带。
    ///
    /// - Parameters:
    ///   - seed: 撕口的笔迹种子。
    ///   - angle: 倾斜角度，单位为度。
    private func tape(seed: UInt64, angle: Double) -> some View {
        HandDrawnTape(seed: seed)
            .fill(Color.accentColor.opacity(0.45))
            .frame(width: 56, height: 18)
            .rotationEffect(.degrees(angle))
            .opacity(isEnabled ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// 给汇总框加上启动页专属的装饰；需放在汇总框自身的底色和描边之后调用。
    ///
    /// - Parameters:
    ///   - isEnabled: 当前页面是否为启动页面，为 `false` 时不显示任何装饰。
    ///   - cornerRadius: 汇总框的圆角。
    ///   - seed: 装饰的笔迹种子，不同页面传不同的值。
    func startPageDecoration(isEnabled: Bool, cornerRadius: CGFloat, seed: UInt64) -> some View {
        modifier(StartPageDecoration(isEnabled: isEnabled, cornerRadius: cornerRadius, seed: seed))
    }
}

#Preview {
    VStack(spacing: 32) {
        ForEach([true, false], id: \.self) { isEnabled in
            Text(verbatim: "¥ 1,234.00")
                .font(.system(.largeTitle, design: .serif, weight: .medium))
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(.paperBackground))
                    HandDrawnBox(cornerRadius: 22, seed: 7)
                        .stroke(
                            Color.primary.opacity(0.85),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
                }
                .startPageDecoration(isEnabled: isEnabled, cornerRadius: 22, seed: 7)
        }
    }
    .padding(24)
    .paperPage()
}
