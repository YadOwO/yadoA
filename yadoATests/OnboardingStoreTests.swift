import Foundation
import SwiftData
import Testing
@testable import yadoA

@Suite("首次引导", .serialized)
@MainActor
struct OnboardingStoreTests {
    /// 每个用例一份隔离的本机存储。
    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let suiteName = "OnboardingStoreTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("未登录时第一页之前有登录邀请，已登录时没有；第一页总是最后一行；云端已有账户时跳过建账户")
    func sequenceFollowsSignInAndCloudAccounts() throws {
        let store = OnboardingStore(defaults: try makeDefaults("sequence"))

        #expect(store.sequence(isSignedIn: false) == [
            .opening, .privacy, .account, .voiceDemo, .insight, .startPage, .accounts, .signIn, .plant,
        ])
        #expect(!store.sequence(isSignedIn: true).contains(.signIn))

        store.draft.hasCloudAccounts = true
        #expect(!store.sequence(isSignedIn: true).contains(.accounts))
    }

    @Test("重看引导走完演示、设置和第一页，跳过账号和登录邀请")
    func replaySkipsAccountAndLanding() throws {
        let store = OnboardingStore(mode: .replay, defaults: try makeDefaults("replay"))

        #expect(store.sequence(isSignedIn: false) == [
            .opening, .privacy, .voiceDemo, .insight, .startPage, .accounts, .plant,
        ])
    }

    @Test("中途退出后从保存的那一行继续，草稿保留")
    func resumesFromSavedProgress() throws {
        let defaults = try makeDefaults("resume")
        let store = OnboardingStore(defaults: defaults)
        store.advance(isSignedIn: false)
        store.advance(isSignedIn: false)
        store.draft.accountOutcome = .firstTime

        let resumed = OnboardingStore(defaults: defaults)
        #expect(resumed.step == .account)
        #expect(resumed.draft.accountOutcome == .firstTime)
        #expect(resumed.answered == [.opening, .privacy])
    }

    @Test("回到前面改完后，直接回到原来写到的那一行")
    func revisionReturnsToFirstUnansweredStep() throws {
        let store = OnboardingStore(defaults: try makeDefaults("revision"))
        while store.step != .plant {
            store.advance(isSignedIn: true)
        }

        store.goBack(to: .startPage)
        #expect(store.step == .startPage)
        #expect(store.isGoingBack)

        store.advance(isSignedIn: true)
        #expect(store.step == .plant)
    }

    @Test("在登录邀请里登录后回到账号那一行补问同步，答完直接到第一页")
    func signInRevisitsAccountThenReturnsToFirstPage() throws {
        let store = OnboardingStore(defaults: try makeDefaults("revisit"))
        while store.step != .signIn {
            store.advance(isSignedIn: false)
        }

        store.revisit(.account)
        #expect(store.step == .account)
        #expect(!store.isGoingBack)

        store.advance(isSignedIn: true)
        #expect(store.step == .plant)
    }

    @Test("跳过只标记完成，不写入任何草稿")
    func skipWritesNothing() throws {
        let defaults = try makeDefaults("skip")
        let store = OnboardingStore(defaults: defaults)
        store.draft.startPage = .accounts
        store.draft.accounts = [.cash]

        store.skip()

        #expect(OnboardingStore.isCompleted(in: defaults))
        #expect(defaults.data(forKey: OnboardingStore.progressKey) == nil)
        #expect(defaults.string(forKey: AppStartPage.storageKey) == nil)
    }

    @Test("第一页点按钮时一次写入账户和启动页面，第一个账户成为默认记账账户")
    func commitWritesEverything() throws {
        let defaults = try makeDefaults("commit")
        let container = try AccountDataContainer.inMemory().modelContainer
        let store = OnboardingStore(defaults: defaults)
        store.draft.startPage = .accounts
        store.draft.accounts = [.wechat, .cash, .huabei]
        store.draft.balances = [
            OnboardingAccountOption.wechat.rawValue: "1050.5",
            OnboardingAccountOption.huabei.rawValue: "2300",
        ]

        try store.commit(container: container, locale: Locale(identifier: "en_US"))

        let repository = LocalAccountRepository(container: container)
        let accounts = try repository.accounts()
        #expect(accounts.count == 3)
        let wechat = try #require(accounts.first { $0.templateID == "virtualAccount.wechat" })
        #expect(wechat.balance == Decimal(string: "1050.5"))
        #expect(accounts.first { $0.typeRawValue == AccountType.cash.rawValue }?.balance == 0)
        #expect(accounts.first { $0.templateID == "creditCard.huabei" }?.balance == 2300)
        #expect(try repository.defaultResolution() == .valid(wechat.id))
        #expect(defaults.string(forKey: AppStartPage.storageKey) == AppStartPage.accounts.rawValue)
        #expect(OnboardingStore.isCompleted(in: defaults))
        #expect(defaults.data(forKey: OnboardingStore.progressKey) == nil)
        #expect(store.isCommitted)
    }

    @Test("写入失败时什么都不写，可以再点一次")
    func failedCommitWritesNothing() throws {
        let defaults = try makeDefaults("failedCommit")
        let container = try AccountDataContainer.inMemory().modelContainer
        let store = OnboardingStore(defaults: defaults)
        store.draft.startPage = .accounts
        store.draft.accounts = [.cash, .alipay]
        store.draft.balances = [OnboardingAccountOption.alipay.rawValue: "1.234"]

        #expect(throws: AccountValidationError.invalidAmount) {
            try store.commit(container: container, locale: Locale(identifier: "en_US"))
        }

        #expect(try LocalAccountRepository(container: container).accounts().isEmpty)
        #expect(defaults.string(forKey: AppStartPage.storageKey) == nil)
        #expect(!OnboardingStore.isCompleted(in: defaults))
        #expect(!store.isCommitted)
    }

    @Test("开启同步后云端已有账户时，写入时不再建账户")
    func commitSkipsAccountsWhenCloudHasThem() throws {
        let defaults = try makeDefaults("cloudAccounts")
        let container = try AccountDataContainer.inMemory().modelContainer
        let store = OnboardingStore(defaults: defaults)
        store.draft.syncChoice = .cloud
        store.draft.hasCloudAccounts = true
        store.draft.accounts = [.cash]

        try store.commit(container: container, locale: Locale(identifier: "en_US"))

        #expect(try LocalAccountRepository(container: container).accounts().isEmpty)
        #expect(OnboardingStore.isCompleted(in: defaults))
    }

    @Test("重看引导点按钮时不写入任何数据")
    func replayCommitWritesNothing() throws {
        let defaults = try makeDefaults("replayCommit")
        let container = try AccountDataContainer.inMemory().modelContainer
        let store = OnboardingStore(mode: .replay, defaults: defaults)
        store.draft.accounts = [.cash]

        try store.commit(container: container, locale: Locale(identifier: "en_US"))

        #expect(try LocalAccountRepository(container: container).accounts().isEmpty)
        #expect(!OnboardingStore.isCompleted(in: defaults))
    }

    @Test("余额没填或是合法金额才能继续")
    func validatesBalances() {
        let locale = Locale(identifier: "en_US")
        #expect(OnboardingAccountOption.isValidAmount("", locale: locale))
        #expect(OnboardingAccountOption.isValidAmount("12.5", locale: locale))
        #expect(!OnboardingAccountOption.isValidAmount("1.234", locale: locale))
    }

    @Test("小结写明账本存在哪里，并按回答列出其余各行")
    func summaryListsAnswers() {
        let locale = Locale(identifier: "zh-Hans")
        var draft = OnboardingDraft()
        draft.accountOutcome = .signedIn
        draft.syncChoice = .cloud
        draft.startPage = .accounts
        draft.accounts = [.wechat, .cash]
        draft.hasAnsweredAccounts = true

        let items = OnboardingSummary.items(draft: draft, displayName: "小豆", locale: locale)

        #expect(items.map(\.text) == ["账本：已开启云同步", "芽豆账号：小豆", "打开先看：账户", "账户：微信和现金"])
        #expect(items.map(\.step) == [.account, .account, .startPage, .accounts])
    }

    @Test("演示的结果提示与语音记账同一套文案")
    func voiceDemoSummaryMatchesVoiceBookkeeping() {
        let locale = Locale(identifier: "zh-Hans")
        let text = VoiceSessionSummary.text(forItems: OnboardingSamples.summaryItems(locale: locale), locale: locale)

        #expect(text.contains("已记 2 笔"))
        #expect(text.contains("已删除"))
    }
}
