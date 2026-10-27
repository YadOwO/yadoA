import Foundation
import Observation
import SwiftData

/// 首次引导在纸上依次写下的每一行；原始值用于保存进度，不能随意改名。
enum OnboardingStep: String, Codable, CaseIterable {
    /// 开场：写出品牌标记和产品名，豆子落到纸上。
    case opening
    /// 本地承诺：账本只存在这台手机上。
    case privacy
    /// 芽豆账号：认出老用户，或询问是否用过芽豆系列。
    case account
    /// 演示：说一句话，同时记两笔、删一笔。
    case voiceDemo
    /// 演示：钱花在哪、怎么变、还剩多少。
    case insight
    /// 启动页面：打开 App 先看记账还是账户。
    case startPage
    /// 建账户：钱放在哪。
    case accounts
    /// 小结与种下：一次写入前面所有回答。
    case plant
    /// 登录邀请：只在未登录时出现。
    case signIn
    /// 落地：撕下这页纸，豆子落到语音记账入口。
    case landing
}

/// 账号这一步的结果。
enum OnboardingAccountOutcome: String, Codable {
    /// 已登录芽豆账号：引导开始时就已登录，或在引导里登录成功。
    case signedIn
    /// 第一次用芽豆系列。
    case firstTime
    /// 想登录但没连上，先在本机用。
    case offline
}

/// 账本存在哪里。
enum OnboardingSyncChoice: String, Codable {
    /// 开启云同步。
    case cloud
    /// 只存在本机。
    case localOnly
}

/// 引导里可以直接建的账户：都是不用再选机构、名字也不用改的常见账户；银行卡等之后在账户页添加。
enum OnboardingAccountOption: String, Codable, CaseIterable, Identifiable {
    /// 现金。
    case cash
    /// 微信钱包。
    case wechat
    /// 支付宝。
    case alipay
    /// 花呗，记为信用账户，填的是欠款。
    case huabei

    /// 稳定标识。
    var id: String { rawValue }

    /// 对应的账户类型。
    var accountType: AccountType {
        switch self {
        case .cash: .cash
        case .wechat, .alipay: .virtualAccount
        case .huabei: .creditCard
        }
    }

    /// 对应的静态模板；现金没有模板。
    var template: AccountTemplate? {
        let id: String? = switch self {
        case .cash: nil
        case .wechat: "virtualAccount.wechat"
        case .alipay: "virtualAccount.alipay"
        case .huabei: "creditCard.huabei"
        }
        guard let id else { return nil }
        return accountType.templates.first { $0.id == id }
    }

    /// 选项上显示的名称，与建好后账户页上的名称一致。
    func title(locale: Locale) -> String {
        template?.name(locale: locale) ?? accountType.title(locale: locale)
    }

    /// 生成账户草稿；余额没填时按 0 建。
    ///
    /// - Parameters:
    ///   - amountText: 用户填的余额或欠款。
    ///   - locale: 解析金额与预填名称使用的语言环境。
    /// - Returns: 待保存的账户草稿。
    func accountDraft(amountText: String, locale: Locale) -> AccountDraft {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        return AccountDraft(
            accountType: accountType,
            template: template,
            amountText: trimmed.isEmpty ? "0" : trimmed,
            locale: locale
        )
    }

    /// 用户填的余额是否可以保存：没填或是合法金额。
    ///
    /// - Parameters:
    ///   - amountText: 用户填的余额或欠款。
    ///   - locale: 解析金额使用的语言环境。
    static func isValidAmount(_ amountText: String, locale: Locale) -> Bool {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || AccountAmountParser.amount(from: trimmed, locale: locale) != nil
    }
}

extension AppStartPage: Codable {}

/// 引导中的回答草稿；“种下”之前不写入账本和设置。
struct OnboardingDraft: Codable, Equatable {
    /// 账号这一步的结果；还没答时为 nil。
    var accountOutcome: OnboardingAccountOutcome?

    /// 账本存在哪里；没登录或还没答时为 nil，按只存在本机处理。
    var syncChoice: OnboardingSyncChoice?

    /// 开启同步后云端已经有账户，跳过建账户这一步，避免和云端的账户重复。
    var hasCloudAccounts = false

    /// 打开 App 先看哪一页；还没答时为 nil。
    var startPage: AppStartPage?

    /// 选中的账户，按选择顺序排列；第一个可记账的会成为默认记账账户。
    var accounts: [OnboardingAccountOption] = []

    /// 各账户填的余额，键为 `OnboardingAccountOption.rawValue`。
    var balances: [String: String] = [:]

    /// 建账户这一步是否答过；什么都不选直接继续也算答过。
    var hasAnsweredAccounts = false
}

/// 保存在本机的引导进度，中途退出后下次从这一行继续。
struct OnboardingProgress: Codable, Equatable {
    /// 当前这一行。
    var step: OnboardingStep = .opening

    /// 回答草稿。
    var draft = OnboardingDraft()

    /// 已经答过的行，按答题顺序排列。
    var answered: [OnboardingStep] = []
}

/// 首次引导的状态：当前写到哪一行、回答草稿，以及跳过、回改、种下、完成。
///
/// 中途退出时进度保存在本机，下次从同一行继续；“种下”时才一次写入账户、启动页面并标记完成。
/// 重看引导时只演示，不保存进度、不写入任何数据。
@MainActor
@Observable
final class OnboardingStore {
    /// 引导的用途。
    enum Mode: Equatable {
        /// 第一次打开 App。
        case firstLaunch
        /// 从设置里重看：只演示，不写入数据，也不触发登录。
        case replay
    }

    /// 引导是否已完成或跳过的本机标记；为 true 时启动不再出现引导。
    static let completedKey = "onboarding.completed"

    /// 引导进度的本机存储键。
    static let progressKey = "onboarding.progress"

    /// 读取引导是否已完成。
    ///
    /// - Parameter defaults: 保存标记的本机存储，测试时可注入隔离实例。
    static func isCompleted(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    /// 引导的用途。
    let mode: Mode

    /// 当前这一行。
    private(set) var step: OnboardingStep

    /// 回答草稿；每次修改都保存进度。
    var draft: OnboardingDraft {
        didSet { save() }
    }

    /// 已经答过的行，按答题顺序排列。
    private(set) var answered: [OnboardingStep]

    /// 是否已经种下：写入完成后不能再回到前面改答案。
    private(set) var isCommitted = false

    /// 最近一次换行是否是回到前面的某一行，决定过渡方向。
    private(set) var isGoingBack = false

    private let defaults: UserDefaults

    /// 创建引导状态；首次引导读取上次没走完的进度。
    ///
    /// - Parameters:
    ///   - mode: 引导用途。
    ///   - defaults: 保存进度的本机存储。
    init(mode: Mode = .firstLaunch, defaults: UserDefaults = .standard) {
        self.mode = mode
        self.defaults = defaults
        let progress = mode == .firstLaunch
            ? defaults.data(forKey: Self.progressKey).flatMap { try? JSONDecoder().decode(OnboardingProgress.self, from: $0) }
            : nil
        // 种下之后的行依赖已写入的数据，进度里不应出现；万一出现就从小结重新开始
        let savedStep = progress?.step ?? .opening
        step = [.signIn, .landing].contains(savedStep) ? .plant : savedStep
        draft = progress?.draft ?? OnboardingDraft()
        answered = progress?.answered ?? []
    }

    /// 本次引导依次要写的行。
    ///
    /// - Parameter isSignedIn: 当前是否已登录；已登录时不再出现登录邀请。
    /// - Returns: 从开场到落地的行。
    func sequence(isSignedIn: Bool) -> [OnboardingStep] {
        if mode == .replay {
            return [.opening, .privacy, .voiceDemo, .insight]
        }
        var steps: [OnboardingStep] = [.opening, .privacy, .account, .voiceDemo, .insight, .startPage]
        if !draft.hasCloudAccounts {
            steps.append(.accounts)
        }
        steps.append(.plant)
        // 在登录邀请这一行登录成功时仍保留它，后面的行才找得到位置
        if !isSignedIn || step == .signIn {
            steps.append(.signIn)
        }
        steps.append(.landing)
        return steps
    }

    /// 当前这一行在整个引导中的进度，0 为开场，1 为最后一行。
    ///
    /// - Parameter isSignedIn: 当前是否已登录。
    func progress(isSignedIn: Bool) -> Double {
        let steps = sequence(isSignedIn: isSignedIn)
        guard steps.count > 1, let index = steps.firstIndex(of: step) else { return 0 }
        return Double(index) / Double(steps.count - 1)
    }

    /// 写完这一行，换到下一行；回改完前面某一行时，直接回到原来写到的地方（后面第一个还没答的行）。
    ///
    /// - Parameter isSignedIn: 当前是否已登录。
    /// - Returns: 已经是最后一行、引导该结束时返回 false。
    @discardableResult
    func advance(isSignedIn: Bool) -> Bool {
        let steps = sequence(isSignedIn: isSignedIn)
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return false }
        if !answered.contains(step) {
            answered.append(step)
        }
        let rest = steps[(index + 1)...]
        isGoingBack = false
        step = rest.first { !answered.contains($0) } ?? steps[index + 1]
        save()
        return true
    }

    /// 点上方的灰色小字，回到那一行改答案；后面答过的保留。种下之后不能再回去。
    ///
    /// - Parameter target: 要回到的行，必须是已经答过的。
    func goBack(to target: OnboardingStep) {
        guard !isCommitted, answered.contains(target), target != step else { return }
        isGoingBack = true
        step = target
        save()
    }

    /// 跳过引导：不写入任何草稿，标记完成，下次启动不再出现。
    func skip() {
        guard mode == .firstLaunch else { return }
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.progressKey)
    }

    /// 种下：一次写入账户和启动页面，并标记引导完成；任何一步失败都不写入。
    ///
    /// 重看引导时什么都不写。
    /// - Parameters:
    ///   - container: 应用持有的本地财务容器。
    ///   - locale: 解析余额与预填账户名称使用的语言环境。
    /// - Throws: 账户校验或保存失败时抛出，此时设置和完成标记都不变。
    func commit(container: ModelContainer, locale: Locale) throws {
        guard mode == .firstLaunch, !isCommitted else { return }
        try OnboardingCommit.apply(draft, container: container, defaults: defaults, locale: locale)
        isCommitted = true
    }

    /// 保存进度；种下之后和重看引导时不保存。
    private func save() {
        guard mode == .firstLaunch, !isCommitted else { return }
        let progress = OnboardingProgress(step: step, draft: draft, answered: answered)
        if let data = try? JSONEncoder().encode(progress) {
            defaults.set(data, forKey: Self.progressKey)
        }
    }
}

/// 种下时的一次性写入。
enum OnboardingCommit {
    /// 写入账户与启动页面，并标记引导完成。
    ///
    /// 账户在同一个 context 里一次保存，全部成功后才写设置和完成标记；失败时什么都不变，可以再按一次。
    /// 账本存在哪里在账号那一步已经按用户的选择生效，这里不再改动。
    /// - Parameters:
    ///   - draft: 回答草稿。
    ///   - container: 应用持有的本地财务容器。
    ///   - defaults: 保存设置与完成标记的本机存储。
    ///   - locale: 解析余额与预填账户名称使用的语言环境。
    /// - Throws: 账户校验或保存失败。
    static func apply(
        _ draft: OnboardingDraft,
        container: ModelContainer,
        defaults: UserDefaults,
        locale: Locale
    ) throws {
        let accountDrafts = draft.hasCloudAccounts ? [] : draft.accounts.map { option in
            option.accountDraft(amountText: draft.balances[option.rawValue] ?? "", locale: locale)
        }
        try LocalAccountRepository(container: container).save(accountDrafts, locale: locale)
        defaults.set((draft.startPage ?? .home).rawValue, forKey: AppStartPage.storageKey)
        defaults.set(true, forKey: OnboardingStore.completedKey)
        defaults.removeObject(forKey: OnboardingStore.progressKey)
    }
}
