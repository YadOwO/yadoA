import Foundation
import Testing
@testable import yadoA

@Suite("隐私政策同意", .serialized)
@MainActor
struct PrivacyAgreementStoreTests {
    /// 每个用例一份隔离的本机存储。
    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let suiteName = "PrivacyAgreementStoreTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("只有中国大陆需要同意，港澳台、其他地区和取不到地区都不需要")
    func onlyChinaMainlandRequiresAgreement() {
        #expect(PrivacyAgreementStore.requiresAgreement(region: .chinaMainland))
        #expect(!PrivacyAgreementStore.requiresAgreement(region: .unitedStates))
        #expect(!PrivacyAgreementStore.requiresAgreement(region: Locale.Region("HK")))
        #expect(!PrivacyAgreementStore.requiresAgreement(region: Locale.Region("TW")))
        #expect(!PrivacyAgreementStore.requiresAgreement(region: nil))
    }

    @Test("不需要同意的地区总是允许联网，不弹同意卡")
    func unrestrictedRegionIsAlwaysOnline() throws {
        let store = PrivacyAgreementStore(defaults: try makeDefaults("unrestricted"), requiresAgreement: false)

        #expect(store.allowsNetwork)
        #expect(!store.needsDecision)
        #expect(!store.isCardPresented)
        #expect(!store.isOfflineMode)
    }

    @Test("需要同意的全新安装：要做选择，同意前不允许联网")
    func freshInstallNeedsDecision() throws {
        let store = PrivacyAgreementStore(defaults: try makeDefaults("fresh"), requiresAgreement: true)

        #expect(store.needsDecision)
        #expect(store.isCardPresented)
        #expect(!store.allowsNetwork)
    }

    @Test("同意后重新创建实例，不再要做选择，允许联网")
    func agreementPersists() throws {
        let defaults = try makeDefaults("agree")
        let store = PrivacyAgreementStore(defaults: defaults, requiresAgreement: true)
        store.agree()

        let restarted = PrivacyAgreementStore(defaults: defaults, requiresAgreement: true)
        #expect(!restarted.needsDecision)
        #expect(restarted.allowsNetwork)
        #expect(restarted.agreedVersion == PrivacyAgreementStore.currentVersion)
    }

    @Test("同意的是旧版本时视为没同意，重新弹出同意卡")
    func olderVersionAsksAgain() throws {
        let defaults = try makeDefaults("upgrade")
        defaults.set(PrivacyAgreementStore.currentVersion - 1, forKey: PrivacyAgreementStore.agreedVersionKey)

        let store = PrivacyAgreementStore(defaults: defaults, requiresAgreement: true)
        #expect(store.needsDecision)
        #expect(!store.allowsNetwork)
    }

    @Test("不同意后进入离线模式且以后不再弹卡；离线时可以重新弹出，同意后恢复联网")
    func declineThenReagree() throws {
        let defaults = try makeDefaults("decline")
        let store = PrivacyAgreementStore(defaults: defaults, requiresAgreement: true)
        store.decline()

        let restarted = PrivacyAgreementStore(defaults: defaults, requiresAgreement: true)
        #expect(!restarted.needsDecision)
        #expect(restarted.isOfflineMode)
        #expect(!restarted.isCardPresented)

        restarted.reviewAgain()
        #expect(restarted.isCardPresented)

        restarted.agree()
        #expect(restarted.allowsNetwork)
        #expect(!restarted.isReviewPresented)
        #expect(!restarted.isCardPresented)
        #expect(!restarted.isDeclined)
    }

    @Test("已经允许联网时 reviewAgain 什么都不做")
    func reviewAgainIgnoredWhenOnline() throws {
        let store = PrivacyAgreementStore(defaults: try makeDefaults("review-online"), requiresAgreement: false)
        store.reviewAgain()

        #expect(!store.isReviewPresented)
    }

    @Test("reset 清掉同意版本和不同意标记")
    func resetClearsBothKeys() throws {
        let defaults = try makeDefaults("reset")
        defaults.set(PrivacyAgreementStore.currentVersion, forKey: PrivacyAgreementStore.agreedVersionKey)
        defaults.set(true, forKey: PrivacyAgreementStore.declinedKey)

        PrivacyAgreementStore.reset(in: defaults)

        #expect(defaults.object(forKey: PrivacyAgreementStore.agreedVersionKey) == nil)
        #expect(defaults.object(forKey: PrivacyAgreementStore.declinedKey) == nil)
    }
}
