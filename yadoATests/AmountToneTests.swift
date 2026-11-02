import Foundation
import Testing
@testable import yadoA

@Suite("全局正负颜色")
@MainActor
struct AmountToneTests {
    @Test("金额按正负取语义，零为中性")
    func toneFollowsSign() {
        #expect(AmountTone(signOf: 12.5) == .positive)
        #expect(AmountTone(signOf: -0.01) == .negative)
        #expect(AmountTone(signOf: 0) == .neutral)
    }

    @Test("正红负绿与正绿负红互为相反，中性不上色")
    func conventionMapsTonesToLedgerColors() {
        #expect(AmountColorConvention.positiveRed.usesRed(for: .positive) == true)
        #expect(AmountColorConvention.positiveRed.usesRed(for: .negative) == false)
        #expect(AmountColorConvention.positiveGreen.usesRed(for: .positive) == false)
        #expect(AmountColorConvention.positiveGreen.usesRed(for: .negative) == true)
        for convention in AmountColorConvention.allCases {
            #expect(convention.usesRed(for: .neutral) == nil)
            #expect(convention.color(for: .neutral) == nil)
        }
    }

    @Test("选项文案两种语言都有")
    func conventionTitlesAreLocalized() {
        for convention in AmountColorConvention.allCases {
            let key = convention.titleLocalizationKey
            #expect(AccountLocalization.string(key, locale: Locale(identifier: "zh-Hans")) != key)
            #expect(AccountLocalization.string(key, locale: Locale(identifier: "en")) != key)
        }
        #expect(
            AccountLocalization.string("settings.amount_colors.positive_red", locale: Locale(identifier: "zh-Hans"))
                == "正红负绿"
        )
    }
}
