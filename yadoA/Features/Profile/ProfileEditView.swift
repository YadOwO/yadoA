import SwiftUI

/// 修改个人资料的底部弹层：大头像、名字与用户名两个胶囊输入框、说明文字、保存与取消。
///
/// 只提交有变化的字段；用户名变化时先弹出密码框验证身份（Logto 的要求），再一并保存。
/// 头像目前只读，暂不提供更换入口。
struct ProfileEditView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthStore.self) private var authStore

    /// 打开弹层时的资料快照，用于判断哪些字段有变化。
    private let original: AccountProfile

    /// 名字输入框内容。
    @State private var name: String
    /// 用户名输入框内容。
    @State private var username: String
    /// 修改用户名时输入的当前密码，仅在验证弹框中使用，保存结束即清空。
    @State private var password = ""
    @State private var isPasswordPromptPresented = false
    @State private var isSaving = false
    /// 最近一次保存失败的原因，显示在保存按钮上方。
    @State private var error: AccountProfileError?

    /// 弹层内容的实际高度，用作弹层高度，让弹层刚好包住内容而不是铺满全屏。
    @State private var contentHeight: CGFloat = 560

    /// 当前聚焦的输入框，保存时收起键盘。
    @FocusState private var focusedField: Field?

    /// 弹层中的输入框。
    private enum Field {
        case name
        case username
    }

    /// 以当前资料初始化输入框。
    init(profile: AccountProfile) {
        original = profile
        _name = State(initialValue: profile.name ?? "")
        _username = State(initialValue: profile.username ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ProfileAvatarView(url: original.avatarURL, size: 112)
                    .padding(.top, 32)
                    .padding(.bottom, 24)

                VStack(alignment: .leading, spacing: 22) {
                    field("profile.edit.name.title") {
                        TextField(text("profile.edit.name.placeholder"), text: $name)
                            .textContentType(.nickname)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .name)
                            .onSubmit { focusedField = .username }
                            .accessibilityIdentifier("profile-edit-name")
                    }

                    field("profile.edit.username.title") {
                        TextField(text("profile.edit.username.placeholder"), text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($focusedField, equals: .username)
                            .onSubmit(save)
                            .accessibilityIdentifier("profile-edit-username")
                    }
                }

                Text(text("profile.edit.footnote"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
                    .padding(.horizontal, 12)

                if let message = validationMessage ?? error.map({ text($0.localizationKey) }) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                        .accessibilityIdentifier("profile-edit-error")
                }

                saveButton
                    .padding(.top, 24)

                Button(text("common.cancel")) {
                    dismiss()
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .disabled(isSaving)
                .accessibilityIdentifier("profile-edit-cancel")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                contentHeight = height
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        // 高度随内容变化（如出现错误提示时自动长高）；超过屏幕时系统会截到最大高度，内容可滚动
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving || hasChanges)
        .onChange(of: name) { error = nil }
        .onChange(of: username) { error = nil }
        .alert(text("profile.edit.password.title"), isPresented: $isPasswordPromptPresented) {
            SecureField(text("profile.edit.password.placeholder"), text: $password)
                .textContentType(.password)
                .accessibilityIdentifier("profile-edit-password")
            Button(text("profile.edit.password.confirm")) {
                submit(password: password)
            }
            .accessibilityIdentifier("profile-edit-password-confirm")
            Button(text("common.cancel"), role: .cancel) {
                password = ""
            }
        } message: {
            Text(text("profile.edit.password.message"))
        }
    }

    // MARK: - 子视图

    /// 黑色胶囊主按钮；深色外观下自动反色，保存中显示转圈。
    private var saveButton: some View {
        Button(action: save) {
            ZStack {
                Text(text("profile.edit.save"))
                    .opacity(isSaving ? 0 : 1)
                if isSaving {
                    ProgressView()
                        .tint(Color(uiColor: .systemBackground))
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(uiColor: .systemBackground))
            .padding(.horizontal, 36)
            .padding(.vertical, 16)
            .background(Capsule().fill(Color.primary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(canSave || isSaving ? 1 : 0.35)
        .disabled(!canSave)
        .accessibilityIdentifier("profile-edit-save")
    }

    /// 标题加胶囊输入框的一组字段。
    private func field<Content: View>(_ titleKey: String, @ViewBuilder input: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text(titleKey))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)

            input()
                .font(.title3)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .disabled(isSaving)
        }
    }

    // MARK: - 状态

    /// 去掉首尾空白后的名字；空字符串表示清空昵称。
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉首尾空白后的用户名。
    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 名字变化：外层 nil 表示未变，内层 nil 表示清空。
    private var nameChange: String?? {
        let newValue: String? = trimmedName.isEmpty ? nil : trimmedName
        let oldValue = original.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOld: String? = (oldValue?.isEmpty ?? true) ? nil : oldValue
        return newValue == normalizedOld ? .none : .some(newValue)
    }

    /// 用户名变化：nil 表示未变。
    private var usernameChange: String? {
        trimmedUsername == (original.username ?? "") ? nil : trimmedUsername
    }

    /// 是否有未保存的修改。
    private var hasChanges: Bool {
        nameChange != nil || usernameChange != nil
    }

    /// 本地即可判断的输入问题；没有问题时为 nil。
    private var validationMessage: String? {
        if trimmedName.count > AccountProfile.nameMaxLength {
            return text("profile.edit.error.name_too_long")
        }
        if usernameChange != nil, !AccountProfile.isValidUsername(trimmedUsername) {
            return text("profile.edit.error.username_invalid")
        }
        return nil
    }

    /// 有修改、输入合法且不在保存中时才允许保存。
    private var canSave: Bool {
        hasChanges && validationMessage == nil && !isSaving
    }

    // MARK: - 操作

    /// 点击保存：改了用户名先要密码，否则直接提交。
    private func save() {
        guard canSave else { return }
        focusedField = nil
        if usernameChange != nil {
            password = ""
            isPasswordPromptPresented = true
        } else {
            submit(password: nil)
        }
    }

    /// 提交修改，成功后关闭弹层，失败时在按钮上方提示原因。
    private func submit(password: String?) {
        let nameChange = nameChange
        let usernameChange = usernameChange
        isSaving = true
        error = nil
        Task {
            defer {
                isSaving = false
                self.password = ""
            }
            do {
                try await authStore.updateProfile(name: nameChange, username: usernameChange, password: password)
                dismiss()
            } catch let profileError as AccountProfileError {
                error = profileError
            } catch {
                self.error = .unknown(nil)
            }
        }
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

/// 圆形头像：有头像地址时加载网络图片，没有或加载失败时显示系统人像图标。
struct ProfileAvatarView: View {
    /// 头像地址；nil 时直接显示占位图标。
    let url: URL?
    /// 头像直径。
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    /// 无头像时的占位：主题色人像图标。
    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .fontWeight(.light)
            .foregroundStyle(Color.accentColor)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ProfileEditView(profile: AccountProfile(name: "Yado", username: "yado_async"))
                .environment(AuthStore())
        }
}
