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

/// 聊天页底部的输入栏：左边加图片，中间打字，右边没有内容时按住说话、有内容时发送。
struct AIChatComposer: View {
    @Environment(\.locale) private var locale
    @Environment(AuthStore.self) private var authStore

    /// 与首页共享的语音状态。
    let voice: VoiceBookkeepingState

    /// 输入中的文字。
    @State private var text = ""

    /// 待发送的图片。
    @State private var pendingImages: [AIChatPendingImage] = []

    /// 相册里选中、等待读取的图片。
    @State private var photoSelection: [PhotosPickerItem] = []

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let hint = voice.input.transientHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
            if !pendingImages.isEmpty || isPreparingImages {
                pendingImageRow
                // 发图片之前说清楚：会发给 AI 服务，服务端不保存，扣点可能不同
                Text(localized("voice.chat.image.notice"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 8) {
                attachMenu
                TextField(
                    localized("voice.chat.placeholder"),
                    text: Binding(
                        get: { text },
                        set: { text = String($0.prefix(VoiceSessionLimits.maxUserTextLength)) }
                    ),
                    axis: .vertical
                )
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityIdentifier("voice-chat-field")
                if hasContent {
                    sendButton
                } else {
                    AIChatMicButton(voice: voice)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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

    /// 待发送图片的预览，点角上的叉移除。
    private var pendingImageRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { image in
                    Image(uiImage: image.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        }
        .scrollIndicators(.hidden)
    }

    /// 添加图片：相册、相机（有相机的设备）、剪贴板。
    private var attachMenu: some View {
        Menu {
            Button(localized("voice.chat.attach.library"), systemImage: "photo.on.rectangle") {
                isPhotoPickerPresented = true
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(localized("voice.chat.attach.camera"), systemImage: "camera") {
                    isCameraPresented = true
                }
            }
            Button(localized("voice.chat.attach.paste"), systemImage: "doc.on.clipboard") {
                pasteImage()
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(remainingImageCount > 0 ? Color.primary : Color.secondary)
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
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

    /// 说话时用强调色，准备取消时用红色，空闲时是浅底。
    private var iconBackground: Color {
        if controller.isCancelArmed { return Color(.ledgerRed) }
        return controller.isRecording ? Color.accentColor : Color.primary.opacity(0.06)
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

/// 一轮附带的图片：靠右排列，点开看大图；本机文件不在了时显示占位。
struct AIChatImageGrid: View {
    @Environment(\.locale) private var locale

    /// 图片文件名。
    let fileNames: [String]

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
