import SwiftUI
import UIKit

/// 应用锁的门：包在 App 主界面外面，决定主界面渲染与否，并把锁屏和遮挡放进独立窗口。
///
/// - 开了锁的冷启动，验证通过前只渲染纸色底，不挂载 `content`（`ContentView` 和本地数据引导都不启动）。
/// - 首次解锁之后 `content` 一直留在视图树里；重新上锁只用独立窗口盖住，不卸载、不重建，
///   所以同步引擎、后台同步和正在填写的表单都不受影响。
/// - 锁屏和遮挡放在高于系统弹窗的独立 `UIWindow` 里，才盖得住主窗口里已经弹出的
///   sheet、fullScreenCover 和 UIKit 展示的截图记账录入页。
struct AppLockGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase

    /// 应用锁状态机。
    let controller: AppLockController

    /// 被保护的主界面。
    private let content: () -> Content

    /// 创建应用锁的门。
    ///
    /// - Parameters:
    ///   - controller: 应用锁状态机。
    ///   - content: 被保护的主界面，只在 `controller.shouldRenderContent` 为 true 时才会创建。
    init(controller: AppLockController, @ViewBuilder content: @escaping () -> Content) {
        self.controller = controller
        self.content = content
    }

    var body: some View {
        // 在 body 里读好再传给窗口宿主，状态变化才会驱动 updateUIView
        let isOverlayVisible = controller.isOverlayVisible
        let isLocked = controller.isLocked
        Group {
            if controller.shouldRenderContent {
                content()
            } else {
                Color(.paperBackground)
                    .ignoresSafeArea()
            }
        }
        .background {
            AppLockWindowHost(controller: controller, isVisible: isOverlayVisible, isLocked: isLocked)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            controller.handleScenePhase(phase)
        }
    }
}

/// 把锁屏和遮挡放进独立高层级窗口的桥接视图；自身是一个不可见的占位 UIView，只用来找到所在的 `UIWindowScene`。
private struct AppLockWindowHost: UIViewRepresentable {
    /// 应用锁状态机，传给窗口里的 SwiftUI 根视图。
    let controller: AppLockController
    /// 窗口是否要显示（锁屏或遮挡任一出现）。
    let isVisible: Bool
    /// 当前是否是锁屏；锁屏时窗口要成为 key window，遮挡时不抢。
    let isLocked: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.onSceneChange = { [weak coordinator = context.coordinator] scene in
            coordinator?.attach(to: scene)
        }
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        context.coordinator.update(isVisible: isVisible, isLocked: isLocked)
    }

    static func dismantleUIView(_ uiView: HostView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    /// 占位视图：加入窗口后把所在的场景交出去。
    final class HostView: UIView {
        /// 所在窗口场景变化时的回调；脱离窗口时传 nil。
        var onSceneChange: ((UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onSceneChange?(window?.windowScene)
        }
    }

    /// 管理锁屏窗口的生命周期：懒创建、按状态显示或隐藏，并在隐藏时把 key window 还给主窗口。
    @MainActor
    final class Coordinator {
        /// 应用锁状态机。
        private let controller: AppLockController
        /// 锁屏和遮挡所在的独立窗口，第一次需要显示时才创建。
        private var window: UIWindow?
        /// 主窗口所在的场景；还没拿到时先记住期望状态，拿到后补上。
        private weak var scene: UIWindowScene?
        /// 期望的窗口显示状态。
        private var isVisible = false
        /// 期望的窗口是否是锁屏。
        private var isLocked = false

        /// 创建协调器。
        ///
        /// - Parameter controller: 应用锁状态机。
        init(controller: AppLockController) {
            self.controller = controller
        }

        /// 拿到主窗口所在的场景，并补上之前记住的期望状态。
        ///
        /// - Parameter scene: 主窗口所在的场景；脱离窗口时为 nil，忽略。
        func attach(to scene: UIWindowScene?) {
            guard let scene else { return }
            if self.scene !== scene {
                // 场景变了（例如视图被移到另一个窗口），旧窗口作废，在新场景里重新创建
                window?.isHidden = true
                window = nil
            }
            self.scene = scene
            apply()
        }

        /// 记下期望的显示状态并应用。
        ///
        /// - Parameters:
        ///   - isVisible: 窗口是否要显示。
        ///   - isLocked: 是否是锁屏。
        func update(isVisible: Bool, isLocked: Bool) {
            self.isVisible = isVisible
            self.isLocked = isLocked
            apply()
        }

        /// 隐藏并释放窗口。
        func tearDown() {
            window?.isHidden = true
            window = nil
        }

        /// 把期望状态落到窗口上。
        ///
        /// 锁屏时窗口成为 key window，主窗口里的键盘和焦点随之收起；只有遮挡时只显示、不抢 key。
        /// 窗口隐藏后把 key 还给场景里的主窗口。
        private func apply() {
            guard let scene else { return }
            if isVisible {
                let window = overlayWindow(in: scene)
                window.overrideUserInterfaceStyle = Self.storedInterfaceStyle()
                if isLocked {
                    window.makeKeyAndVisible()
                } else {
                    window.isHidden = false
                }
            } else if let window, !window.isHidden {
                window.isHidden = true
                // 只还给普通层级的主窗口，不碰键盘等系统窗口
                scene.windows.first { $0 !== window && $0.windowLevel == .normal }?.makeKey()
            }
        }

        /// 取已经创建的窗口，没有就创建。
        ///
        /// - Parameter scene: 窗口所属的场景。
        private func overlayWindow(in scene: UIWindowScene) -> UIWindow {
            if let window { return window }
            let window = UIWindow(windowScene: scene)
            // 高于系统弹窗层级，盖住主窗口和其中所有 sheet、fullScreenCover
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            window.backgroundColor = .clear
            // 这个窗口里的 UIHostingController 不继承 WindowGroup 的环境，语言和亮暗色要单独挂上
            let hosting = UIHostingController(
                rootView: AppLockOverlayView(controller: controller)
                    .modifier(AppDisplayPreferencesModifier())
            )
            hosting.view.backgroundColor = .clear
            hosting.view.accessibilityViewIsModal = true
            window.rootViewController = hosting
            self.window = window
            return window
        }

        /// 按 App 内保存的外观偏好换算窗口的外观；跟随系统时不强制。
        ///
        /// 窗口每次显示前都重新读取，设置里改过外观之后下一次锁屏或遮挡就会跟上。
        private static func storedInterfaceStyle() -> UIUserInterfaceStyle {
            let rawValue = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
            switch rawValue.flatMap(AppAppearance.init(rawValue:))?.colorScheme {
            case .light: return .light
            case .dark: return .dark
            default: return .unspecified
            }
        }
    }
}

/// 独立窗口里的根视图：锁着时显示锁屏，否则显示切换器遮挡。
struct AppLockOverlayView: View {
    /// 应用锁状态机。
    let controller: AppLockController

    var body: some View {
        if controller.isLocked {
            AppLockScreen(controller: controller)
        } else {
            AppPrivacyCover()
        }
    }
}
