import Foundation
import SwiftUI
import Testing
@testable import yadoA

@Suite("App 触感")
@MainActor
struct AppHapticsTests {
    @Test("触感开关未设置时默认开启，关闭后读到 false")
    func switchDefaultsToEnabled() throws {
        let suiteName = "AppHapticsTests.switch"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppHaptics.isEnabled(in: defaults))

        defaults.set(false, forKey: AppHaptics.storageKey)
        #expect(!AppHaptics.isEnabled(in: defaults))

        defaults.set(true, forKey: AppHaptics.storageKey)
        #expect(AppHaptics.isEnabled(in: defaults))
    }

    @Test("结果类事件沿用系统通知触感，选中变化沿用系统选择触感")
    func semanticEventsMapToSystemFeedback() {
        #expect(AppHaptic.selection.sensoryFeedback == .selection)
        #expect(AppHaptic.success.sensoryFeedback == .success)
        #expect(AppHaptic.warning.sensoryFeedback == .warning)
        #expect(AppHaptic.error.sensoryFeedback == .error)
        // 轻重层级：删除比撤销重，插画落定比轻点重
        #expect(AppHaptic.destructive.sensoryFeedback != AppHaptic.restore.sensoryFeedback)
        #expect(AppHaptic.landing.sensoryFeedback != AppHaptic.tap.sensoryFeedback)
    }

    @Test("设置里的触感开关文案已本地化")
    func switchTitleIsLocalized() {
        let english = Locale(identifier: "en")
        let simplifiedChinese = Locale(identifier: "zh-Hans")
        #expect(AccountLocalization.string("settings.haptics.title", locale: english) == "Haptics")
        #expect(AccountLocalization.string("settings.haptics.title", locale: simplifiedChinese) == "触感反馈")
    }
}
