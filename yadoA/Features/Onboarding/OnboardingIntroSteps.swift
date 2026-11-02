import SwiftData
import SwiftUI

// MARK: - 开场

/// 开场：空白的纸上写出对勾品牌标和“芽豆资产”，画一道地面，豆子从上方落下，然后只给一个按钮。
struct OnboardingOpeningStep: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 触感。
    let haptics: OnboardingHaptics

    /// 让豆子从纸外落到地面上。
    let onDropBean: () -> Void

    /// 进入下一行。
    let onContinue: () -> Void

    /// 对勾的书写进度。
    @State private var tickProgress: CGFloat = 0

    /// 地面墨线的书写进度。
    @State private var groundProgress: CGFloat = 0

    /// 按钮是否出现。
    @State private var isButtonVisible = false

    /// 产品名开始书写的时刻，相对开场出现。
    private static let titleDelay: Double = 0.85

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                HandDrawnTick(progress: tickProgress)
                    .frame(width: 84)
                    .accessibilityHidden(true)

                OnboardingInkText(
                    text: AccountLocalization.string("app.name", locale: locale),
                    font: .system(size: 38, weight: .semibold, design: .serif),
                    delay: Self.titleDelay,
                    haptics: haptics
                )
                .accessibilityAddTraits(.isHeader)

                // 豆子落在这道地面上
                VStack(spacing: 0) {
                    Color.clear
                        .frame(width: 26, height: 26)
                        .onboardingBeanSlot()
                    HandDrawnRule(seed: 41)
                        .trim(from: 0, to: groundProgress)
                        .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 180, height: 3)
                }
                .accessibilityHidden(true)
            }
            Spacer()
            Button(AccountLocalization.string("onboarding.opening.enter", locale: locale), action: onContinue)
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(!isButtonVisible)
                .onboardingReveal(isButtonVisible)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .accessibilityIdentifier("onboarding-enter")
        }
        .task {
            await play()
        }
    }

    /// 对勾 → 产品名 → 地面 → 豆子落下 → 按钮；每一步按开场出现那一刻的绝对时间等待，避免误差累积。
    private func play() async {
        guard tickProgress == 0 else { return }
        if reduceMotion {
            tickProgress = 1
            groundProgress = 1
            onDropBean()
            isButtonVisible = true
            return
        }
        let clock = ContinuousClock()
        let origin = clock.now
        /// 等到相对开场的某一时刻。
        func wait(until offset: Double) async {
            try? await clock.sleep(until: origin + .seconds(offset), tolerance: .milliseconds(1))
        }

        await wait(until: 0.25)
        haptics.pen(duration: 0.6)
        withAnimation(.easeInOut(duration: 0.6)) {
            tickProgress = 1
        }
        let groundStart = Self.titleDelay + OnboardingInkText.duration(for: AccountLocalization.string("app.name", locale: locale))
        await wait(until: groundStart)
        haptics.pen(duration: 0.45)
        withAnimation(.easeOut(duration: 0.45)) {
            groundProgress = 1
        }
        await wait(until: groundStart + 0.4)
        onDropBean()
        await wait(until: groundStart + 1.1)
        isButtonVisible = true
    }
}

// MARK: - 本地承诺

/// 本地承诺：墨线画出一部手机，把纸上的账本圈在里面，豆子落进圈里。
struct OnboardingPrivacyStep: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 触感。
    let haptics: OnboardingHaptics

    /// 豆子在新位置落定。
    let onBeanLanded: () -> Void

    /// 进入下一行。
    let onContinue: () -> Void

    /// 标题写完后出现说明、插画和按钮。
    @State private var isDetailVisible = false

    /// 手机轮廓的书写进度。
    @State private var outlineProgress: CGFloat = 0

    /// 轮廓是否已经首尾合上；合上后豆子才落进来。
    @State private var isPhoneClosed = false

    var body: some View {
        OnboardingPage {
            OnboardingInkText(
                text: text("onboarding.privacy.title"),
                haptics: haptics,
                onWritten: { isDetailVisible = true }
            )
            .accessibilityAddTraits(.isHeader)

            Text(text("onboarding.privacy.message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .onboardingReveal(isDetailVisible)

            phone
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } actions: {
            Button(text("onboarding.continue"), action: onContinue)
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .onboardingReveal(isDetailVisible, delay: 0.5)
                .disabled(!isDetailVisible)
        }
        .onChange(of: isDetailVisible) { _, isVisible in
            guard isVisible else { return }
            Task { await drawPhone() }
        }
    }

    /// 一部手画的手机，里面是几行账本横线；轮廓合上后豆子落进来。
    private var phone: some View {
        ZStack {
            VStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { index in
                    HandDrawnRule(seed: UInt64(60 + index))
                        .stroke(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, 22)
            .opacity(outlineProgress > 0.3 ? 1 : 0)
            .animation(.easeOut(duration: 0.4), value: outlineProgress > 0.3)

            HandDrawnBox(cornerRadius: 26, seed: 9)
                .trim(from: 0, to: outlineProgress)
                .stroke(Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

            VStack {
                Capsule()
                    .stroke(Color.primary.opacity(0.5), lineWidth: 1.2)
                    .frame(width: 34, height: 8)
                    .padding(.top, 12)
                    .opacity(isPhoneClosed ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: isPhoneClosed)
                Spacer()
                Color.clear
                    .frame(width: 22, height: 22)
                    .onboardingBeanSlot(isActive: isPhoneClosed)
                    .padding(.bottom, 26)
            }
        }
        .frame(width: 128, height: 214)
        .accessibilityHidden(true)
    }

    /// 画手机轮廓；首尾合上时一下，随后豆子落进来。
    private func drawPhone() async {
        guard outlineProgress == 0 else { return }
        if reduceMotion {
            outlineProgress = 1
            isPhoneClosed = true
            onBeanLanded()
            return
        }
        haptics.pen(duration: 1)
        withAnimation(.easeInOut(duration: 1)) {
            outlineProgress = 1
        }
        try? await Task.sleep(for: .seconds(1))
        haptics.tick()
        isPhoneClosed = true
        try? await Task.sleep(for: OnboardingBean.landingDelay)
        onBeanLanded()
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

// MARK: - 芽豆账号

/// 芽豆账号：认出已登录的芽豆账号，或询问是否用过芽豆系列；登录后询问一次账本要不要同步到云端。
///
/// 登录、同步失败或没有网络都不阻塞：写一行小字，按“先在本机用”继续。
struct OnboardingAccountStep: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthStore.self) private var authStore
    @Environment(SignInPresentation.self) private var signInPresentation
    @Environment(SyncEngine.self) private var syncEngine: SyncEngine?
    @Environment(SyncLifecycle.self) private var syncLifecycle: SyncLifecycle?

    /// 引导状态。
    let store: OnboardingStore

    /// 触感。
    let haptics: OnboardingHaptics

    /// 进入下一行。
    let onContinue: () -> Void

    /// 这一行当前写到哪里。
    private enum Phase: Equatable {
        /// 问是否用过芽豆系列。
        case ask
        /// 已经打开登录页，等它关上。
        case waitingForSignIn
        /// 登录没成功，先在本机用。
        case offline
        /// 认出已登录的芽豆账号。
        case welcome
        /// 问账本要不要同步到云端。
        case sync
        /// 正在开启同步、拉取云端数据。
        case syncing
        /// 同步已开启；附带从云端拉下来的账户名称。
        case synced(accountNames: [String])
        /// 同步没开成，账本先存在本机。
        case syncFailed
    }

    @State private var phase: Phase?

    /// 标题写完后出现说明和按钮。
    @State private var isDetailVisible = false

    var body: some View {
        OnboardingPage {
            if let phase {
                OnboardingInkText(
                    text: title(for: phase),
                    haptics: haptics,
                    onWritten: { isDetailVisible = true }
                )
                .accessibilityAddTraits(.isHeader)

                if let message = message(for: phase) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(phase == .offline || phase == .syncFailed ? Color(.ledgerRed) : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                        .onboardingReveal(isDetailVisible)
                }

                if phase == .syncing {
                    ProgressView()
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity)
                }
            }
        } actions: {
            if let phase {
                actions(for: phase)
                    .onboardingReveal(isDetailVisible, delay: 0.2)
                    .disabled(!isDetailVisible)
            }
        }
        .onAppear {
            guard phase == nil else { return }
            phase = initialPhase
        }
        .onChange(of: phase) { oldPhase, newPhase in
            // 标题换了才重新写，写完再出现说明和按钮；标题不变时只换说明
            if let oldPhase, let newPhase, title(for: oldPhase) != title(for: newPhase) {
                isDetailVisible = false
            }
        }
        .onChange(of: signInPresentation.isPresented) { _, isPresented in
            guard !isPresented, phase == .waitingForSignIn else { return }
            if authStore.isAuthenticated {
                store.draft.accountOutcome = .signedIn
                haptics.success()
                show(.sync)
            } else {
                store.draft.accountOutcome = .offline
                show(.offline)
            }
        }
    }

    /// 进入这一行时的状态：已登录的认出来，没登录的先问。
    private var initialPhase: Phase {
        guard authStore.isAuthenticated else { return .ask }
        // 在这一行登录过、又回来改时直接问同步
        return store.draft.accountOutcome == .signedIn ? .sync : .welcome
    }

    /// 各状态的标题。
    private func title(for phase: Phase) -> String {
        switch phase {
        case .ask, .waitingForSignIn, .offline:
            text("onboarding.account.ask.title")
        case .welcome:
            authStore.displayName.map {
                AccountLocalization.formatted("onboarding.account.welcome.title", value: $0, locale: locale)
            } ?? text("onboarding.account.welcome.title.noname")
        case .sync, .syncing:
            text("onboarding.sync.title")
        case .synced:
            text("onboarding.sync.synced.title")
        case .syncFailed:
            text("onboarding.sync.failed.title")
        }
    }

    /// 各状态标题下的说明。
    private func message(for phase: Phase) -> String? {
        switch phase {
        case .ask, .waitingForSignIn:
            text("onboarding.account.ask.message")
        case .offline:
            text("onboarding.account.offline")
        case .welcome:
            text("onboarding.account.welcome.message")
        case .sync:
            text("onboarding.sync.message")
        case .syncing:
            text("onboarding.sync.syncing")
        case let .synced(names):
            names.isEmpty
                ? text("onboarding.sync.synced.empty")
                : AccountLocalization.formatted("onboarding.sync.synced.accounts", value: list(names), locale: locale)
        case .syncFailed:
            text("onboarding.sync.failed.message")
        }
    }

    /// 各状态的按钮。
    @ViewBuilder
    private func actions(for phase: Phase) -> some View {
        switch phase {
        case .ask, .waitingForSignIn:
            HStack(spacing: 12) {
                Button(text("onboarding.account.ask.used")) {
                    haptics.selection()
                    if phase != .waitingForSignIn {
                        beginSignIn()
                    }
                }
                .buttonStyle(OnboardingChoiceButtonStyle(seed: 11))
                .accessibilityIdentifier("onboarding-account-used")

                Button(text("onboarding.account.ask.firstTime")) {
                    haptics.selection()
                    store.draft.accountOutcome = .firstTime
                    store.draft.syncChoice = nil
                    onContinue()
                }
                .buttonStyle(OnboardingChoiceButtonStyle(seed: 12))
                .accessibilityIdentifier("onboarding-account-first-time")
            }
        case .offline, .syncFailed:
            Button(text("onboarding.account.localContinue"), action: onContinue)
                .buttonStyle(OnboardingPrimaryButtonStyle())
        case .welcome:
            Button(text("onboarding.continue")) {
                store.draft.accountOutcome = .signedIn
                syncLifecycle?.refreshState()
                // 这个账号之前就开着同步时不再问
                if let state = syncLifecycle?.state, state.isEnabled, !(syncLifecycle?.isBoundToAnotherAccount(than: authStore.userID) ?? true) {
                    store.draft.syncChoice = .cloud
                    onContinue()
                } else {
                    show(.sync)
                }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
        case .sync:
            VStack(spacing: 10) {
                // 两个选项同样醒目，也不预先选中任何一个
                HStack(spacing: 12) {
                    Button(text("onboarding.sync.enable")) {
                        haptics.selection()
                        Task { await enableSync() }
                    }
                    .buttonStyle(OnboardingChoiceButtonStyle(isSelected: store.draft.syncChoice == .cloud, seed: 13))
                    .accessibilityIdentifier("onboarding-sync-enable")

                    Button(text("onboarding.sync.localOnly")) {
                        haptics.selection()
                        Task { await keepLocal() }
                    }
                    .buttonStyle(OnboardingChoiceButtonStyle(isSelected: store.draft.syncChoice == .localOnly, seed: 14))
                    .accessibilityIdentifier("onboarding-sync-local")
                }
                Text(text("onboarding.sync.footnote"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .syncing:
            EmptyView()
        case .synced:
            Button(text("onboarding.continue"), action: onContinue)
                .buttonStyle(OnboardingPrimaryButtonStyle())
        }
    }

    /// 换到另一个状态，标题重新写。
    private func show(_ next: Phase) {
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) {
            phase = next
        }
    }

    /// 打开现有的整屏登录页；登录页关上后按结果继续。
    private func beginSignIn() {
        phase = .waitingForSignIn
        signInPresentation.present()
    }

    /// 用当前账号开启同步，等第一轮同步结束；云端已有账户时跳过建账户。
    private func enableSync() async {
        guard let syncLifecycle, let userID = authStore.userID else {
            store.draft.syncChoice = .localOnly
            show(.syncFailed)
            return
        }
        show(.syncing)
        let existingIDs = activeAccountIDs()
        do {
            try await syncLifecycle.enable(userID: userID)
            store.draft.syncChoice = .cloud
            await waitForFirstSync()
            let pulled = activeAccounts().filter { !existingIDs.contains($0.id) }
            store.draft.hasCloudAccounts = !pulled.isEmpty
            haptics.success()
            show(.synced(accountNames: pulled.map { AccountListPresentation.row(for: $0, locale: locale).name }))
        } catch {
            // 同步没开成不阻塞，后面照常建账户
            store.draft.syncChoice = .localOnly
            store.draft.hasCloudAccounts = false
            show(.syncFailed)
        }
    }

    /// 只存在本机；之前在这一行开过同步、回来改主意时关掉同步。
    private func keepLocal() async {
        store.draft.syncChoice = .localOnly
        store.draft.hasCloudAccounts = false
        if syncLifecycle?.state.isEnabled == true {
            await syncLifecycle?.disable()
        }
        onContinue()
    }

    /// 等第一轮同步结束，最多等 10 秒；拉取失败或超时都按“云端没有数据”继续，之后由同步按现有规则重试。
    private func waitForFirstSync() async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        // 引擎恢复后才开始这一轮，先等它进入同步中
        try? await Task.sleep(for: .milliseconds(300))
        while clock.now < deadline, syncEngine?.status == .syncing {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// 本机所有启用中的账户。
    private func activeAccounts() -> [Account] {
        ((try? modelContext.fetch(FetchDescriptor<Account>())) ?? []).filter(\.isActive)
    }

    /// 本机所有启用中账户的标识。
    private func activeAccountIDs() -> Set<UUID> {
        Set(activeAccounts().map(\.id))
    }

    /// 按当前语言把名称连成一串。
    private func list(_ names: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

// MARK: - 登录邀请

/// 登录邀请：只在未登录时出现，排在第一页之前。列出登录后能做的事，并说明登录不会上传账本；可以以后再说。
struct OnboardingSignInStep: View {
    @Environment(\.locale) private var locale
    @Environment(AuthStore.self) private var authStore
    @Environment(SignInPresentation.self) private var signInPresentation

    /// 触感。
    let haptics: OnboardingHaptics

    /// 登录成功、登录页关上后调用，由外层补问要不要同步。
    let onSignedIn: () -> Void

    /// 以后再说，进入下一行。
    let onContinue: () -> Void

    /// 标题写完后依次画出权益图标。
    @State private var isDetailVisible = false

    var body: some View {
        OnboardingPage {
            OnboardingInkText(
                text: text("auth.sign_in.headline"),
                haptics: haptics,
                onWritten: { isDetailVisible = true }
            )
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(SignInBenefit.allCases.enumerated()), id: \.element) { index, benefit in
                    HStack(spacing: 12) {
                        ZStack {
                            if isDetailVisible {
                                Image(systemName: benefit.systemImage)
                                    .foregroundStyle(Color(.ledgerRed))
                                    .transition(OnboardingSymbolTransition.drawOn)
                            }
                        }
                        .frame(width: 24, height: 24)
                        .animation(.easeOut(duration: 0.5).delay(Double(index) * 0.12), value: isDetailVisible)
                        Text(text(benefit.titleLocalizationKey))
                            .fixedSize(horizontal: false, vertical: true)
                            .onboardingReveal(isDetailVisible, delay: Double(index) * 0.12)
                    }
                    .font(.subheadline)
                }
            }
            .padding(.top, 28)

            Text(text("onboarding.signIn.note"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
                .onboardingReveal(isDetailVisible, delay: 0.45)
        } actions: {
            Button(text("auth.sign_in.action")) {
                signInPresentation.present()
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .accessibilityIdentifier("onboarding-sign-in")

            Button(text("onboarding.signIn.later"), action: onContinue)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("onboarding-sign-in-later")
        }
        .onChange(of: signInPresentation.isPresented) { _, isPresented in
            // 登录成功、登录页关上后补问同步；没登录就留在这一行
            if !isPresented, authStore.isAuthenticated {
                haptics.success()
                onSignedIn()
            }
        }
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 图标画出来的过渡：iOS 26 是一笔一笔画出，更早的系统是淡入放大。
enum OnboardingSymbolTransition {
    /// 图标出现时的过渡。
    static var drawOn: AnyTransition {
        if #available(iOS 26, *) {
            return AnyTransition(.symbolEffect(.drawOn))
        }
        return AnyTransition(.symbolEffect(.appear))
    }
}
