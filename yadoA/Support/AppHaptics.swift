import SwiftUI
import UIKit

/// App 内触感的语义事件：按“发生了什么”命名，轻重由 `AppHaptics` 统一决定。
///
/// 只在完成、确认、越过阈值、选中变化、出错这几类时刻震动；越重要的操作越重，同一个动作只震一次。
/// 页面跳转、普通按钮、滚动和后台事件不震；系统控件自带触感的（如滑动删除拉到底）也不再叠加。
enum AppHaptic: CaseIterable, Equatable {
    /// 选中项变化或拖动越过阈值：切换选项、饼图换扇区、下拉切月到位。
    case selection
    /// 操作完成：保存流水、转账、导入、同步完成。
    case success
    /// 需要留意但没有失败：如余额不足提醒出现。
    case warning
    /// 操作失败。
    case error
    /// 确认破坏性操作：删除流水、分类、账户，清空数据。
    case destructive
    /// 撤销或恢复成功，比删除轻。
    case restore
    /// 开始一段持续操作：如按满时长开始收音。
    case begin
    /// 提交一段持续操作：如语音松手发送、拖动排序放下。
    case commit
    /// 放弃一段持续操作：如语音上滑取消。
    case dismiss
    /// 按下主要按钮的那一刻，柔和地给出“按到了”的感觉。
    case press
    /// 轻点装饰元素：如点按插画里的豆子。
    case tap
    /// 重要元素落定：如插画的豆子出现，是最重的一下。
    case landing

    /// 对应的 SwiftUI 系统触感，供 `appHaptic` 修饰符使用。
    var sensoryFeedback: SensoryFeedback {
        switch self {
        case .selection: .selection
        case .success: .success
        case .warning: .warning
        case .error: .error
        case .destructive: .impact(weight: .medium)
        case .restore: .impact(weight: .light)
        case .begin: .impact(weight: .medium)
        case .commit: .impact(weight: .light, intensity: 0.7)
        case .dismiss: .impact(flexibility: .soft, intensity: 0.5)
        case .press: .impact(flexibility: .soft, intensity: 0.6)
        case .tap: .impact(weight: .light)
        case .landing: .impact(weight: .heavy, intensity: 0.9)
        }
    }
}

/// App 触感的统一入口：所有触感都从这里或 `appHaptic` 修饰符发出，由设置里的总开关统一控制。
enum AppHaptics {
    /// 在本机保存的触感开关键；未设置时视为开启。
    static let storageKey = "app.haptics.enabled"

    /// 读取触感开关。
    ///
    /// - Parameter defaults: 保存偏好的本机存储，测试时可注入隔离实例。
    /// - Returns: 未设置或已开启时为 true。
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? true
    }

    /// 在非视图触发的场景（如异步保存完成后）直接播放一次触感；开关关闭时不播放。
    ///
    /// - Parameter haptic: 要播放的语义事件。
    static func play(_ haptic: AppHaptic) {
        guard isEnabled() else { return }
        switch haptic {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .destructive, .begin:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .restore, .tap:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .commit:
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
        case .dismiss:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
        case .press:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        case .landing:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 0.9)
        }
    }
}

/// 受总开关控制的 `sensoryFeedback`：开关关闭时不播放，其余行为与系统修饰符一致。
private struct AppHapticModifier<Trigger: Equatable>: ViewModifier {
    @AppStorage(AppHaptics.storageKey) private var isEnabled = true

    /// 触发触感的值，变化时调用 `feedback`。
    let trigger: Trigger

    /// 根据新旧值决定播放哪种触感；返回 nil 表示这次不震。
    let feedback: (Trigger, Trigger) -> AppHaptic?

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: trigger) { oldValue, newValue in
            guard isEnabled else { return nil }
            return feedback(oldValue, newValue)?.sensoryFeedback
        }
    }
}

extension View {
    /// `trigger` 变化时播放触感，受设置里的触感开关控制。
    ///
    /// - Parameters:
    ///   - haptic: 要播放的语义事件。
    ///   - trigger: 触发触感的值。
    func appHaptic<T: Equatable>(_ haptic: AppHaptic, trigger: T) -> some View {
        modifier(AppHapticModifier(trigger: trigger) { _, _ in haptic })
    }

    /// `trigger` 变化且满足条件时播放触感，受设置里的触感开关控制。
    ///
    /// - Parameters:
    ///   - haptic: 要播放的语义事件。
    ///   - trigger: 触发触感的值。
    ///   - condition: 根据新旧值判断这次是否播放。
    func appHaptic<T: Equatable>(
        _ haptic: AppHaptic,
        trigger: T,
        condition: @escaping (_ oldValue: T, _ newValue: T) -> Bool
    ) -> some View {
        modifier(AppHapticModifier(trigger: trigger) { condition($0, $1) ? haptic : nil })
    }

    /// `trigger` 变化时按新旧值决定播放哪种触感，受设置里的触感开关控制。
    ///
    /// - Parameters:
    ///   - trigger: 触发触感的值。
    ///   - haptic: 根据新旧值返回要播放的语义事件；返回 nil 表示这次不震。
    func appHaptic<T: Equatable>(
        trigger: T,
        _ haptic: @escaping (_ oldValue: T, _ newValue: T) -> AppHaptic?
    ) -> some View {
        modifier(AppHapticModifier(trigger: trigger, feedback: haptic))
    }
}
