import SwiftUI

// MARK: - 启动页面

/// 打开 App 先看哪一页；下方的小 Tab 栏实时按选择重排，与设置里的“启动页面”是同一个偏好。
struct OnboardingStartPageStep: View {
    @Environment(\.locale) private var locale

    /// 引导状态；选择写进草稿，第一页点按钮时才生效。
    let store: OnboardingStore

    /// 触感。
    let haptics: OnboardingHaptics

    /// 进入下一行。
    let onContinue: () -> Void

    /// 标题写完后出现选项和按钮。
    @State private var isDetailVisible = false

    private var selection: AppStartPage {
        store.draft.startPage ?? .home
    }

    var body: some View {
        OnboardingPage {
            OnboardingInkText(
                text: text("onboarding.startPage.title"),
                haptics: haptics,
                onWritten: { isDetailVisible = true }
            )
            .accessibilityAddTraits(.isHeader)

            HStack(spacing: 12) {
                ForEach(Array(AppStartPage.allCases.enumerated()), id: \.element) { index, page in
                    Button {
                        select(page)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: page.tab.symbolName)
                                .font(.title2)
                                .foregroundStyle(selection == page ? Color(.ledgerRed) : Color.primary)
                            Text(page.tab.title(locale: locale))
                                .font(.headline)
                            Text(text(subtitleKey(for: page)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 18)
                    }
                    .buttonStyle(OnboardingChoiceButtonStyle(isSelected: selection == page, seed: UInt64(21 + index)))
                    .accessibilityAddTraits(selection == page ? .isSelected : [])
                    .accessibilityIdentifier("onboarding-start-page-\(page.rawValue)")
                }
            }
            .padding(.top, 28)
            .onboardingReveal(isDetailVisible)

            tabBarPreview
                .padding(.top, 36)
                .onboardingReveal(isDetailVisible, delay: 0.15)

            Text(text("onboarding.startPage.note"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .onboardingReveal(isDetailVisible, delay: 0.2)
        } actions: {
            Button(text("onboarding.continue")) {
                // 没动过也记下默认的记账页，小结里才有这一行
                store.draft.startPage = selection
                onContinue()
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .onboardingReveal(isDetailVisible, delay: 0.3)
            .disabled(!isDetailVisible)
        }
    }

    /// 底部导航的缩略预览：启动页面排第一，“我的”始终在最右，切换时图标滑到新位置。
    private var tabBarPreview: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.ordered(startingWith: selection.tab), id: \.self) { tab in
                VStack(spacing: 3) {
                    Image(systemName: tab.symbolName)
                        .font(.body)
                    Text(tab.title(locale: locale))
                        .font(.caption2)
                }
                .foregroundStyle(tab == selection.tab ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .floatingGlassSurface(in: Capsule())
        .animation(.spring(duration: 0.5, bounce: 0.3), value: selection)
        .accessibilityHidden(true)
    }

    private func select(_ page: AppStartPage) {
        guard page != store.draft.startPage else { return }
        haptics.selection()
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
            store.draft.startPage = page
        }
    }

    private func subtitleKey(for page: AppStartPage) -> String {
        switch page {
        case .home: "onboarding.startPage.home.subtitle"
        case .accounts: "onboarding.startPage.accounts.subtitle"
        }
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

// MARK: - 建账户

/// 钱放在哪：多选几个常用账户，选中的卡片一张张拍到纸上、贴上胶带，可以顺手填余额。
struct OnboardingAccountsStep: View {
    @Environment(\.locale) private var locale
    @Environment(\.ledgerCurrencyCode) private var ledgerCurrencyCode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 引导状态；选择和余额写进草稿，第一页点按钮时才建账户。
    let store: OnboardingStore

    /// 触感。
    let haptics: OnboardingHaptics

    /// 进入下一行。
    let onContinue: () -> Void

    /// 标题写完后出现选项和按钮。
    @State private var isDetailVisible = false

    /// 正在输入余额的账户。
    @FocusState private var focusedOption: OnboardingAccountOption?

    /// 是否打开记账币种选择。
    @State private var isPresentingCurrencyPicker = false

    /// 这一步要建账户用的币种：用户在这一步选过就用选的，否则沿用环境里的账本币种（手机地区的默认值）。
    private var currencyCode: String {
        store.draft.currencyCode ?? ledgerCurrencyCode
    }

    /// 余额输入允许的小数位数：按这一步的币种，无小数的币种（JPY、KRW 等）不能输小数。
    private var fractionDigits: Int {
        BookkeepingCurrency.inputFractionDigits(for: currencyCode)
    }

    var body: some View {
        OnboardingPage {
            OnboardingInkText(
                text: text("onboarding.accounts.title"),
                haptics: haptics,
                onWritten: { isDetailVisible = true }
            )
            .accessibilityAddTraits(.isHeader)

            Text(text("onboarding.accounts.message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .onboardingReveal(isDetailVisible)

            currencyRow
                .padding(.top, 14)
                .onboardingReveal(isDetailVisible, delay: 0.05)

            LedgerFlowLayout(spacing: 10) {
                ForEach(Array(OnboardingAccountOption.allCases.enumerated()), id: \.element) { index, option in
                    let isSelected = store.draft.accounts.contains(option)
                    Button {
                        toggle(option)
                    } label: {
                        HStack(spacing: 6) {
                            AccountIconView(presentation: presentation(for: option).icon)
                                .scaleEffect(0.75)
                                .frame(width: 28, height: 28)
                            Text(option.title(locale: locale))
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(OnboardingChoiceButtonStyle(isSelected: isSelected, seed: UInt64(31 + index), fillsWidth: false))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("onboarding-account-\(option.rawValue)")
                }
            }
            .padding(.top, 22)
            .onboardingReveal(isDetailVisible, delay: 0.1)

            VStack(spacing: 18) {
                ForEach(Array(store.draft.accounts.enumerated()), id: \.element) { index, option in
                    card(for: option, seed: UInt64(41 + index))
                        .transition(slapTransition)
                }
            }
            .padding(.top, 28)
        } actions: {
            Button(text(store.draft.accounts.isEmpty ? "onboarding.accounts.none" : "onboarding.accounts.done")) {
                focusedOption = nil
                store.draft.hasAnsweredAccounts = true
                onContinue()
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(!isDetailVisible || !areAmountsValid)
            .onboardingReveal(isDetailVisible, delay: 0.3)
            .accessibilityIdentifier("onboarding-accounts-done")
        }
        .sheet(isPresented: $isPresentingCurrencyPicker) {
            LedgerCurrencyPicker(selection: currencyCode) { code in
                selectCurrency(code)
                isPresentingCurrencyPicker = false
            }
        }
    }

    /// 「记账币种：美元 US$ · 更改」：账户按它建；点「更改」打开币种选择。
    private var currencyRow: some View {
        HStack(spacing: 6) {
            Text(AccountLocalization.formatted(
                "onboarding.accounts.currency",
                value: "\(BookkeepingCurrency.displayName(for: currencyCode, locale: locale)) "
                    + BookkeepingCurrency.symbol(for: currencyCode, locale: locale),
                locale: locale
            ))
            .foregroundStyle(.secondary)
            Text(verbatim: "·")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Button(text("onboarding.accounts.currency.change")) {
                focusedOption = nil
                isPresentingCurrencyPicker = true
            }
            .accessibilityIdentifier("onboarding-currency-change")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 选了新币种：只记进引导草稿，最后一页写入时才生效；没有小数的币种同时去掉已经填了的小数部分。
    ///
    /// - Parameter code: 选中的币种代码。
    private func selectCurrency(_ code: String) {
        store.draft.currencyCode = code
        guard BookkeepingCurrency.inputFractionDigits(for: code) == 0 else { return }
        let separator = locale.decimalSeparator ?? "."
        store.draft.balances = store.draft.balances.mapValues { amount in
            amount.components(separatedBy: separator).first ?? amount
        }
    }

    /// 选中账户的卡片：与账户页的账户行同样的图标和名称，右边填余额；左上角贴一段胶带。
    private func card(for option: OnboardingAccountOption, seed: UInt64) -> some View {
        let row = presentation(for: option)
        let isValid = OnboardingAccountOption.isValidAmount(
            balance(for: option).wrappedValue, locale: locale, fractionDigits: fractionDigits
        )
        return HStack(spacing: 12) {
            AccountIconView(presentation: row.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.headline)
                Text(row.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(option.accountType.amountLabel(locale: locale))
                    .font(.caption)
                    .foregroundStyle(isValid ? Color.secondary : Color(.ledgerRed))
                TextField(text("onboarding.accounts.amount.placeholder"), text: balance(for: option))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .serif).monospacedDigit())
                    .focused($focusedOption, equals: option)
                    .frame(maxWidth: 120)
                    .accessibilityLabel(AccountLocalization.formatted(
                        "onboarding.accounts.amount.accessibility", value: row.name, locale: locale
                    ))
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.paperBackground))
            HandDrawnBox(cornerRadius: 22, seed: seed)
                .stroke(
                    isValid ? Color.primary.opacity(0.85) : Color(.ledgerRed),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
        }
        .overlay(alignment: .topLeading) {
            HandDrawnTape(seed: seed)
                .fill(Color.accentColor.opacity(0.45))
                .frame(width: 56, height: 18)
                .rotationEffect(.degrees(seed % 2 == 0 ? -6 : 5))
                .offset(x: 22, y: -9)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// 卡片拍到纸上：从稍大、微微倾斜的样子落下来，弹一下贴平。
    private var slapTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .modifier(
                    active: OnboardingSlapEffect(progress: 0),
                    identity: OnboardingSlapEffect(progress: 1)
                ),
                removal: .opacity.combined(with: .scale(scale: 0.92))
            )
    }

    /// 所有填了的余额都是合法金额。
    private var areAmountsValid: Bool {
        store.draft.accounts.allSatisfy {
            OnboardingAccountOption.isValidAmount(
                store.draft.balances[$0.rawValue] ?? "", locale: locale, fractionDigits: fractionDigits
            )
        }
    }

    /// 选中或取消一个账户；选中时卡片落定那一刻一下。
    private func toggle(_ option: OnboardingAccountOption) {
        if let index = store.draft.accounts.firstIndex(of: option) {
            haptics.selection()
            withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                _ = store.draft.accounts.remove(at: index)
            }
        } else {
            withAnimation(.spring(duration: 0.5, bounce: 0.45)) {
                store.draft.accounts.append(option)
            }
            Task {
                // 弹簧第一次落到原位时
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 180))
                haptics.slap()
            }
        }
    }

    /// 账户的行展示，与账户页同一套写法。
    private func presentation(for option: OnboardingAccountOption) -> AccountRowPresentation {
        AccountListPresentation.row(
            id: UUID(),
            accountType: option.accountType,
            templateID: option.template?.id,
            name: option.title(locale: locale),
            lastFourDigits: nil,
            balance: 0,
            currencyCode: currencyCode,
            locale: locale
        )
    }

    /// 某个账户余额输入的绑定，只保留数字和小数点；没有小数的币种不让输小数点。
    private func balance(for option: OnboardingAccountOption) -> Binding<String> {
        Binding(
            get: { store.draft.balances[option.rawValue] ?? "" },
            set: { newValue in
                let separator = locale.decimalSeparator ?? "."
                let allowsSeparator = fractionDigits > 0
                store.draft.balances[option.rawValue] = newValue.filter {
                    $0.isWholeNumber || (allowsSeparator && String($0) == separator)
                }
            }
        )
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 卡片拍到纸上的过程：0 时偏大、倾斜、透明，1 时贴平。
private struct OnboardingSlapEffect: ViewModifier {
    /// 落下的进度。
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + 0.16 * (1 - progress))
            .rotationEffect(.degrees(-5 * (1 - progress)))
            .offset(y: -18 * (1 - progress))
            .opacity(Double(min(1, progress * 2)))
    }
}
