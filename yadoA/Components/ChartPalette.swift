import SwiftUI

/// 图表里区分类别用的配色：分类统计和资产分析的环形图共用。
///
/// 取自经过色觉辨识校验的分类色板前三位（蓝、橙、青绿），浅色、深色各一套色阶；
/// 这三色两两之间在常见色觉障碍下也分得开，在纸色背景上也校验过。超过三类时合并成「其他」并用次要灰，不再生成新颜色。
/// 浅色下橙、青绿与纸面对比不足 3:1，用这些颜色的地方旁边必须有文字（图例名称、百分比），不能只靠颜色认类别。
enum ChartPalette {
    /// 可用的颜色位数。
    static let slotCount = 3

    /// 第几位的颜色；超出范围时按位数取余，调用方应先把多余的类别合并成「其他」。
    ///
    /// - Parameters:
    ///   - slot: 从 0 开始的颜色位：0 蓝、1 橙、2 青绿。
    ///   - colorScheme: 当前外观，浅色和深色各用一套色阶。
    static func color(slot: Int, colorScheme: ColorScheme) -> Color {
        let (light, dark): (UInt32, UInt32) = switch ((slot % slotCount) + slotCount) % slotCount {
        case 1: (0xEB6834, 0xD95926)
        case 2: (0x1BAF7A, 0x199E70)
        default: (0x2A78D6, 0x3987E5)
        }
        let hex = colorScheme == .dark ? dark : light
        return Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// 合并出来的「其他」、以及开启「区分时不仅仅依赖颜色」时所有类别使用的语义灰。
    static var neutral: Color {
        Color(uiColor: .secondaryLabel)
    }
}
