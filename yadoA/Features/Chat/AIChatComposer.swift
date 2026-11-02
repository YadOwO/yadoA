import PhotosUI
import SwiftUI
import UIKit

/// 待发送的一张图片。
private struct AIChatPendingImage: Identifiable {
    /// 稳定标识。
    let id = UUID()

    /// 压缩好的 JPEG。
    let data: Data

    /// 输入栏上显示的预览。
    let preview: UIImage
}

/// 聊天页底部：下一步建议和悬浮的输入栏。
///
/// 输入栏上面一行打字；下面一行左边加图片，右边是对话模型，最右边没有内容时按住说话、有内容时发送。
/// 按住说话时整条输入栏变成声波；麦克风不换位置，也不重建，否则手指还按着触摸就断了。
struct AIChatComposer: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AuthStore.self) private var authStore

    /// 与首页共享的语音状态。
    let voice: VoiceBookkeepingState

    /// 输入栏上方的建议。
    let suggestions: [AIChatSuggestion]

    /// 是否正在等用户回答追问；输入框提示跟着变。
    let isAwaitingAnswer: Bool

    /// 打开 AI 对话的模型比较页；弹层由聊天页统一管理，点数不够时的“换个模型”也打开它。
    let onCompareModels: () -> Void

    /// 输入中的文字。
    @State private var text = ""

    /// 输入框是否聚焦。
    @FocusState private var isFieldFocused: Bool

    /// 待发送的图片。
    @State private var pendingImages: [AIChatPendingImage] = []

    /// 相册里选中、等待读取的图片。
    @State private var photoSelection: [PhotosPickerItem] = []

    /// 是否展开了添加图片的选项。
    @State private var isAttachOpen = false

    /// 是否打开相册。
    @State private var isPhotoPickerPresented = false

    /// 是否打开相机。
    @State private var isCameraPresented = false

    /// 是否正在读取和压缩图片。
    @State private var isPreparingImages = false

    /// 去掉首尾空白后的文字。
    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否有内容可以发送；有内容时右边的按钮是发送，否则是麦克风。
    private var hasContent: Bool {
        !trimmedText.isEmpty || !pendingImages.isEmpty
    }

    /// 还能再加几张图片。
    private var remainingImageCount: Int {
        VoiceSessionLimits.maxImages - pendingImages.count
    }

    /// 是否正在按住说话。
    private var isRecording: Bool {
        voice.input.isRecording
    }

    /// 是否显示建议；已经在打字、加图片时不打岔。
    private var showsSuggestions: Bool {
        !suggestions.isEmpty && !hasContent && !isAttachOpen && !isPreparingImages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let hint = voice.input.transientHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
            if isAttachOpen {
                attachOptions
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: 16)))
            } else if showsSuggestions {
                suggestionRow
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: 10)))
            }
            composerSurface
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background {
            LinearGradient(
                stops: [.init(color: Color(.paperBackground).opacity(0), location: 0), .init(color: Color(.paperBackground), location: 0.3)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.25), value: suggestions)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.25), value: isAttachOpen)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: isRecording)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: voice.input.isCancelArmed)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2), value: hasContent)
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $photoSelection,
            maxSelectionCount: max(remainingImageCount, 1),
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task { await addPhotos(items) }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            AIChatCameraPicker { image in
                guard let data = image.jpegData(compressionQuality: 0.9) else { return }
                Task { await addImages([data]) }
            }
            .ignoresSafeArea()
        }
    }

    /// 悬浮的输入栏：上面一行打字，下面一行是加图片、对话模型和麦克风或发送，与常见的 AI 对话输入栏一致。
    private var composerSurface: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            if !pendingImages.isEmpty || isPreparingImages {
                pendingImageRow
                // 发图片之前说清楚：会发给 AI 服务，服务端不保存，扣点可能不同
                Text(localized("voice.chat.image.notice"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                TextField(
                    localized(isAwaitingAnswer ? "voice.chat.placeholder.answer" : "voice.chat.placeholder"),
                    text: Binding(
                        get: { text },
                        set: { text = String($0.prefix(VoiceSessionLimits.maxUserTextLength)) }
                    ),
                    axis: .vertical
                )
                .focused($isFieldFocused)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .opacity(isRecording ? 0 : 1)
                .allowsHitTesting(!isRecording)
                .accessibilityIdentifier("voice-chat-field")
                HStack(spacing: 4) {
                    plusButton
                    // 点两个按钮之间的空白也能开始打字；Color 会占满给它的高度，必须写死高度，否则整个输入栏被撑高
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture { isFieldFocused = true }
                        .accessibilityHidden(true)
                    AIChatModelMenu(onCompare: onCompareModels)
                }
                .opacity(isRecording ? 0 : 1)
                .allowsHitTesting(!isRecording)
                // 麦克风不跟着上面几个按钮隐藏，按着说话时手指一直在它上面
                .padding(.trailing, 48)
                .overlay(alignment: .trailing) {
                    if hasContent {
                        sendButton
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else {
                        AIChatMicButton(voice: voice)
                    }
                }
            }
            .overlay {
                if isRecording {
                    recordingContent
                        .transition(.opacity)
                }
            }
        }
        .padding(6)
        .background(recordingFill, in: shape)
        .voiceFloatingSurface(in: shape)
        .scaleEffect(isRecording && !reduceMotion ? 1.02 : 1)
    }

    /// 输入栏的底色：说话时是墨色，准备取消时是红色，平时透出玻璃。
    private var recordingFill: Color {
        guard isRecording else { return .clear }
        return voice.input.isCancelArmed ? Color(.ledgerRed) : Color.accentColor
    }

    /// 按住说话时盖在输入栏上的声波和提示：上面一行是声波，下面一行左边是松手的提示，右边让出麦克风。
    private var recordingContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            AIChatWaveform(recognizer: voice.input.recognizer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14)
            Text(localized(voice.input.isCancelArmed ? "voice.recording.releaseToCancel" : "voice.mic.releaseToSend"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(.onAccent))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.leading, 14)
                .padding(.trailing, 56)
        }
        .allowsHitTesting(false)
    }

    /// 下一步建议，放不下时横向滑动。
    private var suggestionRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button(suggestion.title) {
                        perform(suggestion)
                    }
                    .font(.subheadline)
                    .foregroundStyle(suggestion.isUndo ? Color(.ledgerRed) : Color.primary)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 13)
                    .frame(minHeight: 36)
                    .voiceFloatingSurface(in: Capsule(), isInteractive: true)
                    .contentShape(Capsule())
                    .accessibilityIdentifier("voice-chat-suggestion")
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    /// 添加图片的选项：相册、相机（有相机的设备）、剪贴板。
    private var attachOptions: some View {
        HStack(spacing: 8) {
            attachOption("voice.chat.attach.library", symbol: "photo.on.rectangle") {
                isPhotoPickerPresented = true
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                attachOption("voice.chat.attach.camera", symbol: "camera") {
                    isCameraPresented = true
                }
            }
            attachOption("voice.chat.attach.paste", symbol: "doc.on.clipboard") {
                pasteImage()
            }
        }
    }

    /// 一个添加图片的选项。
    ///
    /// - Parameters:
    ///   - key: 文字的本地化键。
    ///   - symbol: 图标。
    ///   - action: 点选后执行。
    private func attachOption(_ key: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            isAttachOpen = false
            action()
        } label: {
            Label(localized(key), systemImage: symbol)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 42)
                .voiceFloatingSurface(in: Capsule(), isInteractive: true)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 待发送图片的预览，点角上的叉移除。
    private var pendingImageRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { image in
                    Image(uiImage: image.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                pendingImages.removeAll { $0.id == image.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.white, Color.black.opacity(0.6))
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(localized("voice.chat.image.remove"))
                        }
                }
                if isPreparingImages {
                    ProgressView()
                        .frame(width: 64, height: 64)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }

    /// 加号：展开或收起添加图片的选项。
    private var plusButton: some View {
        Button {
            isFieldFocused = false
            isAttachOpen.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.regular))
                .foregroundStyle(remainingImageCount > 0 ? Color.secondary : Color.secondary.opacity(0.4))
                .rotationEffect(.degrees(isAttachOpen ? 45 : 0))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(remainingImageCount <= 0 || isPreparingImages)
        .accessibilityLabel(localized("voice.chat.attach"))
        .accessibilityIdentifier("voice-chat-attach")
    }

    /// 发送按钮；上一句还在处理时不能发，内容留在输入栏。
    private var sendButton: some View {
        let isEnabled = !voice.isProcessing && !isPreparingImages
        return Button {
            send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(isEnabled ? Color(.onAccent) : Color.secondary)
                .frame(width: 44, height: 44)
                .background(isEnabled ? Color.accentColor : Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(localized("voice.chat.send"))
        .accessibilityIdentifier("voice-chat-send")
    }

    // MARK: - 动作

    /// 执行一条建议。
    private func perform(_ suggestion: AIChatSuggestion) {
        switch suggestion.action {
        case let .send(message):
            guard !voice.isProcessing else { return }
            AppHaptics.play(.commit)
            voice.send(message)
        case let .fill(content):
            text = content
            isFieldFocused = true
        case .attachImage:
            isAttachOpen = true
        case .undo:
            AppHaptics.play(.restore)
            voice.session?.undoLatestTurn()
        }
    }

    /// 发送文字和图片，清空输入栏；图片存到本机，聊天记录据此显示。
    private func send() {
        guard hasContent, !voice.isProcessing else { return }
        let store = AIChatImageStore.production
        var uploads: [VoiceImageUpload] = []
        do {
            for image in pendingImages {
                uploads.append(VoiceImageUpload(fileName: try store.save(image.data), data: image.data))
            }
        } catch {
            voice.input.transientHint = localized("voice.chat.image.failed")
            return
        }
        AppHaptics.play(.commit)
        voice.send(trimmedText, images: uploads)
        text = ""
        pendingImages = []
    }

    /// 读取相册里选中的图片。
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        isPreparingImages = true
        var loaded: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                loaded.append(data)
            }
        }
        if loaded.count < items.count {
            voice.input.transientHint = localized("voice.chat.image.failed")
        }
        await addImages(loaded)
    }

    /// 从剪贴板取一张图片；只在用户点选时读取，避免无故触发系统的粘贴提示。
    private func pasteImage() {
        guard let data = UIPasteboard.general.image?.jpegData(compressionQuality: 0.9) else {
            voice.input.transientHint = localized("voice.chat.image.noPaste")
            return
        }
        Task { await addImages([data]) }
    }

    /// 在后台压缩图片并放进待发送列表；超出张数上限的不再添加。
    ///
    /// - Parameter sources: 原始图片数据。
    private func addImages(_ sources: [Data]) async {
        isPreparingImages = true
        defer { isPreparingImages = false }
        let limit = remainingImageCount
        let compressed = await Task.detached(priority: .userInitiated) {
            sources.prefix(limit).map(AIChatImageProcessor.compressedJPEG(from:))
        }.value
        let images = compressed.compactMap { data -> AIChatPendingImage? in
            guard let data, let preview = UIImage(data: data) else { return nil }
            return AIChatPendingImage(data: data, preview: preview)
        }
        if images.count < compressed.count {
            voice.input.transientHint = localized("voice.chat.image.failed")
        }
        pendingImages.append(contentsOf: images)
    }

    private func localized(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 输入栏里的麦克风：按住说话、松手发送、上滑取消，规则与首页的麦克风相同。
private struct AIChatMicButton: View {
    @Environment(\.locale) private var locale
    @Environment(AuthStore.self) private var authStore

    /// 与首页共享的语音状态。
    let voice: VoiceBookkeepingState

    private var controller: VoiceInputController { voice.input }

    /// 是否不接受新的按下。
    private var isBusy: Bool {
        voice.isProcessing || controller.isFinishing
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(iconBackground)
            if isBusy {
                ProgressView()
            } else {
                Image(systemName: controller.isCancelArmed ? "xmark" : "mic.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(controller.isRecording ? Color(.onAccent) : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 44, height: 44)
        .overlay {
            VoiceMicTouchArea(
                onPressBegan: {
                    guard !isBusy, !controller.isPressing else { return false }
                    voice.beginPress(isSignedIn: authStore.isAuthenticated, locale: locale)
                    return controller.isPressing
                },
                onPressMoved: { controller.pressMoved(verticalTranslation: $0) },
                onPressEnded: { controller.pressEnded(onText: { voice.send($0) }) },
                onPressCancelled: { controller.cancel() }
            )
            .accessibilityHidden(true)
        }
        .appHaptic(.selection, trigger: controller.isCancelArmed)
        .accessibilityElement()
        .accessibilityLabel(AccountLocalization.string("voice.mic.label", locale: locale))
        .accessibilityHint(AccountLocalization.string("voice.mic.hint", locale: locale))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) {
            voice.toggleRecording(isSignedIn: authStore.isAuthenticated, locale: locale)
        }
        .accessibilityIdentifier("voice-chat-mic")
    }

    /// 说话时压在墨色或红色的输入栏上，只留一层淡底；空闲时是浅底。
    private var iconBackground: Color {
        controller.isRecording ? Color(.onAccent).opacity(0.16) : Color.primary.opacity(0.06)
    }
}

/// 输入栏里的对话模型：显示当前档位的名称，点开列出各档位和每句扣几点，勾选的就是本页在用的，最下面可以比较模型。
///
/// 只改聊天页发出的话，快捷语音的模型不受影响。档位列表还没取到、或可选的档位不到两个时不显示。
private struct AIChatModelMenu: View {
    @Environment(\.locale) private var locale
    /// 当前账号的 AI 点数，提供档位列表和 AI 对话所选的档位；预览中没有注入时为 nil。
    @Environment(AIPointsStore.self) private var aiPoints: AIPointsStore?

    /// 打开模型比较页。
    let onCompare: () -> Void

    var body: some View {
        if let aiPoints, let tierList = aiPoints.tierList, tierList.selectableTiers.count > 1 {
            let current = aiPoints.displayTier(for: .chat)
            Menu {
                Picker(
                    text(AIModelScope.chat.titleKey),
                    selection: Binding(
                        get: { current },
                        set: { tier in
                            if let tier { aiPoints.selectTier(tier, for: .chat) }
                        }
                    )
                ) {
                    ForEach(tierList.selectableTiers) { tier in
                        Label(title(of: tier, in: tierList), systemImage: tier.symbol)
                            .tag(Optional(tier))
                    }
                }
                .pickerStyle(.inline)

                Button(action: onCompare) {
                    Label(text("ai.tier.chat.compare"), systemImage: "info.circle")
                }
            } label: {
                HStack(spacing: 4) {
                    // 客户端不认识服务端默认档位时不冒充成别的档位，只写“对话模型”
                    Text(text(current?.titleKey ?? AIModelScope.chat.titleKey))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 32)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(text(AIModelScope.chat.titleKey))
            .accessibilityValue(current.map { text($0.titleKey) } ?? "")
            .accessibilityIdentifier("voice-chat-model")
            // 只跟用户的选择震动；刷新后默认档位变化不震
            .appHaptic(.selection, trigger: aiPoints.selectedTier(for: .chat))
        }
    }

    /// 菜单里一个档位的文字，例如“精准 · 每句 2 点”；服务端没给点数时只有名称。
    ///
    /// - Parameters:
    ///   - tier: 档位。
    ///   - tierList: 服务端的档位列表，用来取每句点数。
    private func title(of tier: AIModelTier, in tierList: AIModelTierList) -> String {
        let name = text(tier.titleKey)
        guard let points = tierList.pointsPerTurn(for: tier.rawValue) else { return name }
        let perTurn = AccountLocalization.formatted(
            "ai.tier.perTurn", value: points.formatted(.number.locale(locale)), locale: locale
        )
        return "\(name) · \(perTurn)"
    }

    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 拍照：系统相机界面，拍完回传一张图片。
private struct AIChatCameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    /// 拍到一张图片。
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onFinish: { dismiss() })
    }

    /// 接收系统相机的回调。
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onImage: (UIImage) -> Void
        private let onFinish: () -> Void

        /// 创建回调对象。
        ///
        /// - Parameters:
        ///   - onImage: 拍到一张图片。
        ///   - onFinish: 拍完或取消后关闭相机。
        init(onImage: @escaping (UIImage) -> Void, onFinish: @escaping () -> Void) {
            self.onImage = onImage
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}

/// 一轮附带的图片：靠右排列，点开看大图；本机文件不在了时显示占位。等模型看图时有一道扫描线来回扫。
struct AIChatImageGrid: View {
    @Environment(\.locale) private var locale

    /// 图片文件名。
    let fileNames: [String]

    /// 是否正在等模型看图。
    var isScanning = false

    /// 正在查看的图片。
    @State private var previewFileName: AIChatPreviewImage?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(fileNames, id: \.self) { fileName in
                Button {
                    previewFileName = AIChatPreviewImage(id: fileName)
                } label: {
                    AIChatStoredImage(fileName: fileName, contentMode: .fill)
                        .frame(width: 96, height: 96)
                        .overlay {
                            if isScanning {
                                AIChatScanLine()
                                    .transition(.opacity)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AccountLocalization.string("voice.chat.image.label", locale: locale))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .sheet(item: $previewFileName) { image in
            NavigationStack {
                AIChatStoredImage(fileName: image.id, contentMode: .fit)
                    .padding(16)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(AccountLocalization.string("common.done", locale: locale)) {
                                previewFileName = nil
                            }
                        }
                    }
            }
        }
    }
}

/// 图片上来回扫的墨红扫描线；开启“减弱动态效果”时不显示，文字状态已经说明在看图。
private struct AIChatScanLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 扫描线是否在图片底部一端。
    @State private var isAtBottom = false

    /// 扫描线上方拖出的淡影高度。
    private static let trailHeight: CGFloat = 28

    var body: some View {
        if !reduceMotion {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color(.ledgerRed).opacity(0), Color(.ledgerRed).opacity(0.22)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: Self.trailHeight)
                    Rectangle()
                        .fill(Color(.ledgerRed))
                        .frame(height: 1.5)
                }
                .offset(y: isAtBottom ? proxy.size.height - Self.trailHeight : -Self.trailHeight)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    isAtBottom = true
                }
            }
        }
    }
}

/// 正在查看的图片。
private struct AIChatPreviewImage: Identifiable {
    /// 图片文件名。
    let id: String
}

/// 显示一张保存在本机的对话图片，在后台读取，不卡住滚动。
private struct AIChatStoredImage: View {
    /// 图片文件名。
    let fileName: String

    /// 缩放方式。
    let contentMode: ContentMode

    /// 读取到的图片。
    @State private var image: UIImage?

    /// 是否已经读取过。
    @State private var isLoaded = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.primary.opacity(0.06)
                    .overlay {
                        if isLoaded {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .task(id: fileName) {
            let fileName = fileName
            image = await Task.detached(priority: .userInitiated) {
                AIChatImageStore.production.data(for: fileName).flatMap { UIImage(data: $0) }
            }.value
            isLoaded = true
        }
    }
}
