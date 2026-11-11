import SwiftUI

/// 芽豆资产的法律文档：用户协议、隐私政策、第三方信息共享清单。
///
/// 正文放在 yado_run 网站上（`src/content/legal/yadoa/`），App 只负责按当前语言拼出地址并在 App 内打开；
/// 改条款只需重新部署网站，不用发版。路径同时填在 App Store Connect 里，网站那边约定不改路径。
enum LegalDocument: String, CaseIterable, Identifiable {
    /// 用户协议。
    case terms
    /// 隐私政策。
    case privacy
    /// 第三方信息共享清单：AI 服务商、云服务和 SDK 的完整列表，换服务商时只改这一页。
    case sharing

    /// 网站根地址。
    static let baseURL = URL(string: "https://my.yado1225.top")!

    /// 登录页同意文案里的链接 scheme；点击时由 `LegalDocument(linkURL:)` 认出是哪份文档，不会真的交给系统打开。
    static let linkScheme = "yadoa-legal"

    /// 选择项的稳定标识。
    var id: String { rawValue }

    /// 标题的本地化键，设置页行标题使用。
    var titleLocalizationKey: String {
        "legal.\(rawValue).title"
    }

    /// 设置页行首图标。
    var systemImage: String {
        switch self {
        case .terms: "doc.text"
        case .privacy: "hand.raised"
        case .sharing: "list.bullet.rectangle"
        }
    }

    /// 文档的网页地址：中文界面打开 `/zh/legal/yadoa/<文档>/`，其他语言打开英文版 `/legal/yadoa/<文档>/`。
    ///
    /// - Parameter locale: App 当前的语言环境（设置里选的语言，跟随系统时是系统语言）。
    /// - Returns: 网站上对应语言版本的地址。
    func url(locale: Locale) -> URL {
        let isChinese = locale.language.languageCode == .chinese
        let path = (isChinese ? "zh/" : "") + "legal/yadoa/\(rawValue)/"
        return Self.baseURL.appending(path: path)
    }

    /// 同意文案中链接用的地址，例如 `yadoa-legal://privacy`。
    var linkURL: URL {
        URL(string: "\(Self.linkScheme)://\(rawValue)")!
    }

    /// 从同意文案里的链接地址认出文档；不是本 scheme 或不认识的文档返回 nil。
    ///
    /// - Parameter linkURL: 文案中 Markdown 链接的地址。
    init?(linkURL: URL) {
        guard linkURL.scheme == Self.linkScheme, let host = linkURL.host() else { return nil }
        self.init(rawValue: host)
    }
}

extension View {
    /// 在 App 内用 Safari 视图弹出法律文档，地址按当前语言选中文或英文版。
    ///
    /// - Parameter document: 要打开的文档，置为 nil 时收起。
    func legalDocumentSheet(_ document: Binding<LegalDocument?>) -> some View {
        modifier(LegalDocumentSheetModifier(document: document))
    }
}

/// `legalDocumentSheet(_:)` 的实现：读取当前语言，弹出整页的 Safari 视图。
private struct LegalDocumentSheetModifier: ViewModifier {
    @Environment(\.locale) private var locale

    /// 正在打开的文档。
    @Binding var document: LegalDocument?

    func body(content: Content) -> some View {
        content.sheet(item: $document) { document in
            InAppSafariView(url: document.url(locale: locale))
                .ignoresSafeArea()
        }
    }
}
