import SwiftUI

/// 意见反馈页：和芽豆团队一对一的对话，像聊天一样一直往下聊。
///
/// 只能在登录后使用，对话跟着账号走，换设备也能看到。打开期间每 15 秒拉一次新消息，看到团队回复即标记已读；
/// 登录失效时回到登录提示。
struct FeedbackView: View {
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthStore.self) private var authStore
    @Environment(SignInPresentation.self) private var signInPresentation
    /// 全局未读状态；预览中没有注入时为 nil。
    @Environment(FeedbackStore.self) private var feedbackStore: FeedbackStore?

    /// 当前账号的对话；未登录时为 nil。
    @State private var conversation: FeedbackConversation?

    /// 输入框里的文字；换账号时保留，方便登录后接着发。
    @State private var draft = ""

    /// 打开期间拉取新消息的间隔。
    static let pollInterval: Duration = .seconds(15)

    var body: some View {
        Group {
            if authStore.isAuthenticated, let conversation {
                FeedbackChatView(conversation: conversation, draft: $draft)
            } else if authStore.isAuthenticated {
                ProgressView()
            } else {
                signedOutView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperPage()
        .navigationTitle(text("feedback.title"))
        .navigationBarTitleDisplayMode(.inline)
        // 进入页面或换了账号时新建对话并加载第一页
        .task(id: authStore.userID) {
            guard let userID = authStore.userID else {
                conversation = nil
                return
            }
            let conversation = FeedbackConversation(
                api: FeedbackAPI(authStore: authStore),
                userID: userID,
                store: feedbackStore
            )
            self.conversation = conversation
            await conversation.refresh()
        }
        // 在前台时定时拉新消息；切到后台时停止，回到前台先拉一次
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                await conversation?.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await conversation?.refresh() }
        }
    }

    /// 未登录或登录失效时的提示与登录入口。
    private var signedOutView: some View {
        ContentUnavailableView {
            Label(text("feedback.title"), systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text(text("feedback.signIn.message"))
        } actions: {
            Button {
                signInPresentation.present(reason: .feedback)
            } label: {
                Text(text("auth.sign_in.action"))
                    .onAccentForeground()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("feedback-sign-in")
        }
    }

    /// 消息之间的时间：今天只显示时刻，今年的省略年份。
    ///
    /// - Parameters:
    ///   - date: 消息时间。
    ///   - locale: 格式使用的语言环境。
    ///   - now: 当前时间，测试可注入。
    /// - Returns: 例如“14:32”“10月28日 14:32”。
    static func formattedTime(_ date: Date, locale: Locale, now: Date = .now) -> String {
        let calendar = Calendar.current
        let style: Date.FormatStyle
        if calendar.isDate(date, inSameDayAs: now) {
            style = .dateTime.hour().minute()
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            style = .dateTime.month().day().hour().minute()
        } else {
            style = .dateTime.year().month().day().hour().minute()
        }
        return date.formatted(style.locale(locale))
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 对话内容：消息列表与底部输入栏。
private struct FeedbackChatView: View {
    @Environment(\.locale) private var locale

    /// 当前账号的对话。
    let conversation: FeedbackConversation

    /// 输入框里的文字。
    @Binding var draft: String

    /// 点了发送失败的消息后，等待选择重发或删除的那一条。
    @State private var failedMessage: FeedbackConversation.OutgoingMessage?

    /// 列表底部的锚点，有新消息时滚到这里。
    private static let bottomAnchorID = "feedback-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if conversation.hasOlder {
                        loadOlderButton(proxy: proxy)
                    } else if conversation.loadState == .loaded {
                        // 已经翻到对话开头：欢迎语只在本机显示，不存到服务端
                        FeedbackBubble(content: text("feedback.welcome"), sender: .team)
                    }
                    ForEach(FeedbackTimeline.rows(messages: conversation.messages, outgoing: conversation.outgoing)) { row in
                        rowView(row)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .overlay { stateOverlay }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FeedbackInputBar(draft: $draft) { send() }
            }
            .onChange(of: conversation.lastItemID) { _, _ in
                withAnimation {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
        }
        .confirmationDialog(
            text("feedback.message.failed"),
            isPresented: Binding(
                get: { failedMessage != nil },
                set: { if !$0 { failedMessage = nil } }
            ),
            titleVisibility: .visible,
            presenting: failedMessage
        ) { message in
            Button(text("feedback.message.resend")) {
                let clientInfo = FeedbackClientInfo.current(locale: locale)
                Task { await conversation.retry(message.id, clientInfo: clientInfo) }
            }
            Button(text("feedback.message.delete"), role: .destructive) {
                conversation.discard(message.id)
            }
        }
        // 发送失败的消息已在原处标出，只有限流需要额外说明为什么发不出去
        .alert(
            text("feedback.error.rateLimited"),
            isPresented: Binding(
                get: { conversation.sendFailure == .rateLimited },
                set: { if !$0 { conversation.dismissSendFailure() } }
            )
        ) {}
    }

    /// 首屏加载中或加载失败时盖在列表上的状态；已有消息后不再显示。
    @ViewBuilder
    private var stateOverlay: some View {
        if conversation.messages.isEmpty, conversation.outgoing.isEmpty {
            switch conversation.loadState {
            case .idle, .loading:
                ProgressView()
            case let .failed(error):
                ContentUnavailableView {
                    Label(text("feedback.load.failed"), systemImage: "exclamationmark.bubble")
                } description: {
                    Text(text(Self.messageKey(for: error)))
                } actions: {
                    Button(text("feedback.retry")) {
                        Task { await conversation.refresh() }
                    }
                }
            case .loaded:
                EmptyView()
            }
        }
    }

    /// 查看更早消息的按钮；加载后停在原来第一条消息的位置，不跳到底部。
    private func loadOlderButton(proxy: ScrollViewProxy) -> some View {
        Button {
            let anchorID = conversation.messages.first?.id.uuidString
            Task {
                await conversation.loadOlder()
                if let anchorID {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
        } label: {
            if conversation.isLoadingOlder {
                ProgressView().controlSize(.small)
            } else {
                Text(text("feedback.loadOlder"))
                    .font(.footnote)
            }
        }
        .buttonStyle(.borderless)
        .disabled(conversation.isLoadingOlder)
        .padding(.vertical, 4)
        .accessibilityIdentifier("feedback-load-older")
    }

    /// 对话中的一行。
    @ViewBuilder
    private func rowView(_ row: FeedbackTimelineRow) -> some View {
        switch row {
        case let .time(date):
            Text(FeedbackView.formattedTime(date, locale: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        case let .message(message):
            FeedbackBubble(content: message.content, sender: message.sender)
        case let .outgoing(message):
            outgoingRow(message)
        }
    }

    /// 还没被服务端确认的消息：发送中在气泡旁转圈，失败时显示红色感叹号，点它选择重发或删除。
    private func outgoingRow(_ message: FeedbackConversation.OutgoingMessage) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Spacer(minLength: 40)
            if message.isFailed {
                Button {
                    failedMessage = message
                } label: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color(.ledgerRed))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(text("feedback.message.failed"))
            } else {
                ProgressView().controlSize(.small)
            }
            FeedbackBubbleText(content: message.content, sender: .user)
                .opacity(message.isFailed ? 1 : 0.7)
        }
    }

    /// 发送输入框里的文字，发出后立即清空输入框。
    private func send() {
        let text = draft
        guard FeedbackComposer.canSend(text) else { return }
        draft = ""
        let clientInfo = FeedbackClientInfo.current(locale: locale)
        Task { await conversation.send(text, clientInfo: clientInfo) }
    }

    /// 加载失败原因对应的提示文案键。
    ///
    /// - Parameter error: 失败原因。
    /// - Returns: 文案键。
    static func messageKey(for error: FeedbackAPIError) -> String {
        switch error {
        case .network, .timeout:
            "feedback.error.network"
        case .notSignedIn, .sessionExpired:
            "feedback.error.sessionExpired"
        case .rateLimited:
            "feedback.error.rateLimited"
        case .unauthorized, .serviceUnavailable, .invalidContract:
            "feedback.error.unavailable"
        }
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 一条消息：自己的靠右，团队的靠左并带芽豆标记。
private struct FeedbackBubble: View {
    /// 正文。
    let content: String

    /// 发送方。
    let sender: FeedbackSender

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if sender == .user {
                Spacer(minLength: 40)
            } else {
                Image(.brandMark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
            }
            FeedbackBubbleText(content: content, sender: sender)
            if sender == .team {
                Spacer(minLength: 40)
            }
        }
    }
}

/// 气泡本身：自己的用强调色浅底，团队的用次级背景色；正文可以选中复制。
private struct FeedbackBubbleText: View {
    @Environment(\.locale) private var locale

    /// 正文。
    let content: String

    /// 发送方。
    let sender: FeedbackSender

    var body: some View {
        Text(content)
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            // 读屏先读发送方再读正文
            .accessibilityLabel(senderName)
            .accessibilityValue(content)
    }

    /// 气泡底色：两种外观下都使用语义色。
    private var background: AnyShapeStyle {
        sender == .user
            ? AnyShapeStyle(Color.accentColor.opacity(0.12))
            : AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
    }

    /// 读屏时的发送方名称。
    private var senderName: String {
        AccountLocalization.string(sender == .user ? "feedback.sender.me" : "app.name", locale: locale)
    }
}

/// 底部输入栏：多行输入框与发送按钮，超出字数时提示超出多少。
private struct FeedbackInputBar: View {
    @Environment(\.locale) private var locale

    /// 输入框里的文字。
    @Binding var draft: String

    /// 点发送。
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            let overflow = FeedbackComposer.overflow(of: draft)
            if overflow > 0 {
                Text(
                    AccountLocalization.formatted(
                        "feedback.input.overflow",
                        value: overflow.formatted(.number.locale(locale)),
                        locale: locale
                    )
                )
                .font(.caption)
                .foregroundStyle(Color(.ledgerRed))
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(text("feedback.input.placeholder"), text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .feedbackInputSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("feedback-input")
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                }
                .buttonStyle(.borderless)
                .disabled(!FeedbackComposer.canSend(draft))
                .accessibilityLabel(text("feedback.send"))
                .accessibilityIdentifier("feedback-send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .feedbackInputBarBackground()
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 输入框底色：iOS 26 用 Liquid Glass，iOS 18 用常规材质。
private struct FeedbackInputSurface<SurfaceShape: Shape>: ViewModifier {
    /// 底色形状。
    let shape: SurfaceShape

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// 输入栏背景：iOS 26 由系统的滚动边缘效果衬底，不再加底色；iOS 18 用工具栏材质，避免消息透到输入框后面。
private struct FeedbackInputBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.background(.bar)
        }
    }
}

private extension View {
    /// 给输入框加上玻璃或材质底色。
    func feedbackInputSurface<SurfaceShape: Shape>(in shape: SurfaceShape) -> some View {
        modifier(FeedbackInputSurface(shape: shape))
    }

    /// 给输入栏加上与系统版本匹配的背景。
    func feedbackInputBarBackground() -> some View {
        modifier(FeedbackInputBarBackground())
    }
}

#Preview {
    NavigationStack { FeedbackView() }
        .environment(AuthStore())
        .environment(SignInPresentation())
}
