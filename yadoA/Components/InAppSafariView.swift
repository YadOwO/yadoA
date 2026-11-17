import SafariServices
import SwiftUI

/// 包装 `SFSafariViewController`：App 内打开网页，自带关闭按钮，页面跟随系统浅色和深色外观。
///
/// 法律文档和「更多芽豆产品」的产品介绍页都用它；放在 `sheet` 里并加 `.ignoresSafeArea()` 铺满。
struct InAppSafariView: UIViewControllerRepresentable {
    /// 要打开的网页地址。
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
