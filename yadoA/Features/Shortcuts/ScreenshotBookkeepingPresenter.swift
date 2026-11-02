import SwiftData
import SwiftUI
import UIKit

/// 从当前最上层页面展示截图录入，保留已有 Sheet 及其中未完成的表单。
/// 根视图直接使用 fullScreenCover 会替换已经展示的个人设置等 Sheet。
struct ScreenshotBookkeepingPresenter: UIViewControllerRepresentable {
    let request: ScreenshotBookkeepingRequest?
    let container: ModelContainer
    let onFinish: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> PresentationAnchor {
        PresentationAnchor()
    }

    func updateUIViewController(_ controller: PresentationAnchor, context: Context) {
        let coordinator = context.coordinator
        controller.onAppear = { [weak controller, weak coordinator] in
            guard let controller, let request else { return }
            coordinator?.present(request, from: controller, container: container, onFinish: onFinish)
        }
        controller.onAppear?()
    }

    /// 冷启动时等待根控制器进入窗口，避免在尚未挂载时丢失展示请求。
    final class PresentationAnchor: UIViewController {
        var onAppear: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }

    /// 仅持有本次录入控制器，关闭时不影响其下方的原页面。
    final class Coordinator {
        private var presentedController: UIViewController?

        func present(
            _ request: ScreenshotBookkeepingRequest,
            from anchor: UIViewController,
            container: ModelContainer,
            onFinish: @escaping @MainActor () -> Void
        ) {
            guard presentedController == nil,
                  var presenter = anchor.view.window?.rootViewController else { return }
            while let presented = presenter.presentedViewController {
                presenter = presented
            }

            // 如果调用恰好撞上页面转场，在同一转场完成后继续，不强制关闭原流程。
            if let transition = presenter.transitionCoordinator {
                let isScheduled = transition.animate(alongsideTransition: nil) { [weak self, weak anchor] _ in
                    // 下一轮主线程任务再查询控制器，确保已结束的转场协调器被移除。
                    Task { @MainActor in
                        guard let anchor else { return }
                        self?.present(request, from: anchor, container: container, onFinish: onFinish)
                    }
                }
                if isScheduled { return }
            }

            let content = NavigationStack {
                DiningExpenseEntryView(screenshot: request.image, onFinish: { [weak self] in
                    self?.presentedController?.dismiss(animated: true) {
                        self?.presentedController = nil
                        onFinish()
                    }
                }) { draft in
                    try LocalExpenseRepository(container: container).save(draft)
                }
            }
            .modelContainer(container)
            let hosting = UIHostingController(rootView: content)
            hosting.modalPresentationStyle = .fullScreen
            presentedController = hosting
            presenter.present(hosting, animated: true)
        }
    }
}
