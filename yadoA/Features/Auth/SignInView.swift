import SwiftUI

/// 登录 / 注册页：导航栏中的品牌、中央手绘芽豆插画和衬线标语、底部一列胶囊按钮。
///
/// 由 `SignInPresentation` 在 Tab 界面之上整屏显示，不属于任何 Tab 的导航栈，也不是 sheet 弹层；
/// 左上角关闭回到原来的页面。版式只留品牌、插画、标语、按钮四样，
/// 大面积留白，让手绘插画成为视觉中心。第三方按钮由 `AuthSocialProvider.displayed` 决定，
/// 未接通的方式只作占位，点击提示即将上线；账号密码按钮打开 Logto 托管页，App 不接触用户密码。
struct SignInView: View {
    @Environment(\.locale) private var locale
    @Environment(SignInPresentation.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AuthStore.self) private var authStore

    /// 显示的第三方登录方式，默认取 `AuthSocialProvider.displayed`；预览时可注入。
    private let providers: [AuthSocialProvider]

    /// 打开登录页的原因；有原因时在标语下说明为什么要登录。
    private let reason: SignInReason?

    /// 当前正在进行的登录方式，用于只在被点的那个按钮上转圈。
    @State private var pendingMethod: PendingMethod?
    /// 入场动画是否已触发。
    @State private var hasAppeared = false
    /// 按钮区上方的提示，如“即将上线”或登录失败。
    @State private var notice: Notice?
    /// 每次登录失败加一，驱动按钮区抖动与错误震动。
    @State private var failureCount = 0
    /// 登录成功后切换为成功态，写一笔对勾后关闭登录页。
    @State private var isSucceeded = false
    /// 成功态对勾的书写进度。
    @State private var successTickProgress: CGFloat = 0

    /// 正在进行的登录方式。
    private enum PendingMethod: Equatable {
        case password
        case social(AuthSocialProvider)
    }

    /// 按钮区上方的一条提示。
    private struct Notice: Equatable {
        /// 已本地化的提示文字。
        let message: String
        /// 是否为错误，错误使用账本红。
        let isError: Bool
        /// 区分连续两次相同文案的提示，保证自动隐藏只收掉自己那一条。
        let id = UUID()
    }

    /// - Parameters:
    ///   - reason: 打开登录页的原因，从“我的”主动登录时为 nil。
    ///   - providers: 要显示的第三方登录方式。
    init(reason: SignInReason? = nil, providers: [AuthSocialProvider] = AuthSocialProvider.displayed) {
        self.reason = reason
        self.providers = providers
    }

    var body: some View {
        ZStack {
            // 内容放得下时铺满一屏、上下留白；大字号等放不下时退回可滚动
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
            .opacity(isSucceeded ? 0 : 1)

            if isSucceeded {
                successView
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.9)))
            }
        }
        .paperPage()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 登录中或成功过渡时不能关闭，避免 Logto 页面回来时登录页已经不在
            if !authStore.isBusy && !isSucceeded {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        presentation.dismiss()
                    } label: {
                        Label(text("common.close"), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("sign-in-close")
                }
            }
            // 品牌放在导航栏标题位，与返回按钮处于同一水平线
            ToolbarItem(placement: .principal) {
                brand
                    .opacity(isSucceeded ? 0 : 1)
                    .reveal(hasAppeared, delay: 0, reduceMotion: reduceMotion)
            }
        }
        .sensoryFeedback(.error, trigger: failureCount)
        .sensoryFeedback(.success, trigger: isSucceeded) { _, succeeded in succeeded }
        .onAppear {
            hasAppeared = true
        }
        .onDisappear {
            authStore.dismissError()
        }
    }

    // MARK: - 版面

    /// 插画与标语、按钮、说明自上而下排开，插画上下的弹性留白把它推到视觉中心；品牌在导航栏标题位。
    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            SproutIllustration(size: 216)

            Text(text("auth.sign_in.headline"))
                .font(.system(size: 28, weight: .regular, design: .serif))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28)
                .accessibilityAddTraits(.isHeader)
                .reveal(hasAppeared, delay: 0.5, reduceMotion: reduceMotion)

            if let reason {
                Text(text(reason.messageLocalizationKey))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("sign-in-reason")
                    .reveal(hasAppeared, delay: 0.55, reduceMotion: reduceMotion)
            }

            Spacer(minLength: 40)

            buttons
                .overlay(alignment: .top) {
                    noticeView
                        .alignmentGuide(.top) { $0[.bottom] + 14 }
                }

            Text(text("auth.sign_in.local_note"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .padding(.horizontal, 8)
                .reveal(hasAppeared, delay: 0.85, reduceMotion: reduceMotion)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    /// 导航栏标题位的品牌：产品标记加衬线产品名，横向排开，高度不超出导航栏。
    private var brand: some View {
        HStack(spacing: 7) {
            Image(.brandMark)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text(text("app.name"))
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .lineLimit(1)
        }
        .accessibilityAddTraits(.isHeader)
        .accessibilityElement(children: .combine)
    }

    /// 底部按钮：第三方方式在前，账号密码收尾；失败时整组左右摇晃。
    private var buttons: some View {
        VStack(spacing: 10) {
            ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                pillButton(
                    title: text(provider.titleLocalizationKey),
                    systemImage: provider.systemImage,
                    isLoading: pendingMethod == .social(provider)
                ) {
                    if provider.isConnected {
                        startSignIn(.social(provider))
                    } else {
                        show(Notice(message: text("auth.sign_in.coming_soon"), isError: false))
                    }
                }
                .accessibilityIdentifier("sign-in-social-\(provider.rawValue)")
                .reveal(hasAppeared, delay: 0.65 + Double(index) * 0.08, reduceMotion: reduceMotion)
            }

            pillButton(
                title: text("auth.sign_in.password"),
                systemImage: "person.fill",
                isLoading: pendingMethod == .password
            ) {
                startSignIn(.password)
            }
            .accessibilityIdentifier("sign-in-password")
            .reveal(hasAppeared, delay: 0.65 + Double(providers.count) * 0.08, reduceMotion: reduceMotion)
        }
        .disabled(authStore.isBusy)
        .modifier(ShakeEffect(animatableData: CGFloat(failureCount)))
    }

    /// 墨色实底胶囊按钮：深色外观下自动反色为纸白底，登录中在原位转圈、宽度不变。
    private func pillButton(
        title: String,
        systemImage: String,
        isLoading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Label(title, systemImage: systemImage)
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .tint(Color(.onAccent))
                }
            }
            .font(.body.weight(.semibold))
            .onAccentForeground()
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(Color.accentColor))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(SignInPressStyle())
    }

    /// 按钮区上方的提示胶囊，出现时从下方浮起，不挤动版面。
    @ViewBuilder
    private var noticeView: some View {
        if let notice {
            Text(notice.message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(notice.isError ? Color(.ledgerRed) : Color.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .id(notice.id)
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 8)))
                .accessibilityIdentifier(notice.isError ? "sign-in-error" : "sign-in-notice")
        }
    }

    /// 登录成功后的过渡：写一笔账本红对勾，配上欢迎语和账号名称。
    private var successView: some View {
        VStack(spacing: 18) {
            HandDrawnTick(progress: successTickProgress)
                .frame(width: 112)

            Text(text("auth.sign_in.success"))
                .font(.system(.title2, design: .serif, weight: .semibold))

            if let name = authStore.displayName {
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sign-in-success")
    }

    // MARK: - 操作

    /// 发起登录；结束后根据结果进入成功态或抖动提示失败，用户主动取消时什么都不做。
    private func startSignIn(_ method: PendingMethod) {
        guard !authStore.isBusy, !isSucceeded else { return }
        pendingMethod = method
        withAnimation { notice = nil }

        Task {
            switch method {
            case .password:
                await authStore.signIn()
            case let .social(provider):
                await authStore.signIn(provider: provider)
            }
            pendingMethod = nil

            if authStore.isAuthenticated {
                await celebrateAndDismiss()
            } else if let errorMessage = authStore.errorMessage {
                authStore.dismissError()
                withAnimation(reduceMotion ? nil : .linear(duration: 0.42)) {
                    failureCount += 1
                }
                show(Notice(
                    message: "\(text("auth.sign_in.failed"))\n\(errorMessage)",
                    isError: true
                ))
            }
        }
    }

    /// 显示一条提示，约 2.5 秒后自动收起；期间若被新提示替换则不再收起新提示。
    private func show(_ newNotice: Notice) {
        withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
            notice = newNotice
        }
        Task {
            try? await Task.sleep(for: .seconds(newNotice.isError ? 4 : 2.5))
            guard notice?.id == newNotice.id else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                notice = nil
            }
        }
    }

    /// 切到成功态、写完对勾，停留片刻后关闭登录页，回到打开前的界面。
    private func celebrateAndDismiss() async {
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
            isSucceeded = true
        }
        if reduceMotion {
            successTickProgress = 1
        } else {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeInOut(duration: 0.5)) {
                successTickProgress = 1
            }
        }
        try? await Task.sleep(for: .milliseconds(1100))
        presentation.dismiss()
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

// MARK: - 动效

/// 登录页按钮的按压反馈：轻微缩小并在按下瞬间给一次柔和震动。
private struct SignInPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: configuration.isPressed) { _, pressed in
                pressed
            }
    }
}

/// 左右摇晃，用于登录失败时提示；`animatableData` 每加 1 摇一轮。
private struct ShakeEffect: GeometryEffect {
    /// 摇晃的动画进度，取整数变化。
    var animatableData: CGFloat

    /// 单侧最大位移。
    private let travel: CGFloat = 8

    /// 每轮来回摇晃的次数。
    private let shakesPerUnit: CGFloat = 3

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: travel * sin(animatableData * .pi * 2 * shakesPerUnit), y: 0)
        )
    }
}

private extension View {
    /// 入场时淡入并上浮到位，按 `delay` 错开形成依次出现的节奏。
    ///
    /// - Parameters:
    ///   - isVisible: 是否已入场。
    ///   - delay: 相对入场开始的延迟，单位为秒。
    ///   - reduceMotion: 开启“减弱动态效果”时只淡入、不位移。
    func reveal(_ isVisible: Bool, delay: Double, reduceMotion: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 16)
            .animation(.spring(duration: 0.55, bounce: 0.18).delay(reduceMotion ? 0 : delay), value: isVisible)
    }
}

#Preview {
    NavigationStack {
        SignInView(reason: .voiceBookkeeping)
    }
    .environment(AuthStore())
    .environment(SignInPresentation())
}
