import Observation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import yadoA

/// 用真实滚动视图验证内容更新后的贴底行为，不访问麦克风或真实 AI 服务。
@Suite("语音会话卡片滚动", .serialized)
@MainActor
struct VoiceSessionCardTests {
    @Test("AI 回复、追问候选和失败提示统一贴底", arguments: ["reply", "ask", "failure"])
    func followsAIResults(kind: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.seedHistory()
        fixture.show()
        let scrollView = try await fixture.scrollView()
        fixture.api.holdsResponse = true
        let sending = Task { await fixture.session.send("再记一笔") }
        defer { sending.cancel() }
        try await fixture.waitUntil { fixture.api.hasPendingResponse && fixture.isAtBottom(scrollView) }
        fixture.displaceOffset(scrollView)

        let response: Result<VoiceSessionTurnResponse, VoiceSessionAPIError>
        switch kind {
        case "ask":
            response = .success(.ask(question: "使用哪个账户？", options: [
                VoiceAskOption(id: "cash", label: "现金"),
                VoiceAskOption(id: "card", label: "银行卡"),
            ]))
        case "failure":
            response = .failure(.serviceUnavailable)
        default:
            response = .success(.reply(text: "已记下这笔开支"))
        }
        fixture.api.complete(with: response)
        await sending.value
        #expect(!fixture.session.isProcessing)
        try await fixture.waitForBottom(scrollView)
    }

    @Test("内容更新结束后，后续布局仅改变偏移也会重新校正到底部")
    func correctsOffsetDriftAfterLayout() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.seedHistory()
        fixture.show()
        let scrollView = try await fixture.scrollView()
        try await fixture.waitForBottom(scrollView)
        let contentSize = scrollView.contentSize

        // 不发送任何新内容，只模拟布局或系统滚动调整把位置移离底部。
        fixture.displaceOffset(scrollView)

        try await fixture.waitForBottom(scrollView)
        #expect(scrollView.contentSize == contentSize)
    }

    @Test("连续新增、修改、撤销与删除后，明细和操作仍完整露出底部")
    func followsTransactionRowsAndUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.seedHistory()
        let context = ModelContext(fixture.sessionContainer)
        let account = Account(
            id: UUID(), typeRawValue: AccountType.cash.rawValue, templateID: nil, name: "现金",
            note: nil, lastFourDigits: nil, balance: 100, currencyCode: "CNY",
            createdAt: .now, updatedAt: .now
        )
        context.insert(account)
        try context.save()
        fixture.show()
        let scrollView = try await fixture.scrollView()
        try await fixture.waitForBottom(scrollView)

        var transactionID: UUID?
        for amount in ["3", "5", "8"] {
            let call: VoiceToolCall
            if let transactionID {
                call = .updateTransaction(id: UUID().uuidString, input: VoiceUpdateTransactionInput(
                    id: transactionID.uuidString, patch: VoiceTransactionPatch(amount: amount)
                ))
            } else {
                call = .createTransaction(id: UUID().uuidString, input: VoiceCreateTransactionInput(
                    type: .expense, amount: amount, accountId: account.id.uuidString, categoryId: "dining",
                    date: "2026-10-21", note: "香蕉", inferredFields: []
                ))
            }
            fixture.api.response = .success(.toolCalls([call], canFinishLocally: true))
            await fixture.session.send("香蕉 \(amount) 元")

            let turn = try #require(fixture.session.undoableTurn)
            transactionID = try #require(turn.changes.first?.entryChange?.transactionID)
            try await fixture.waitForBottom(scrollView)
        }

        fixture.session.undoLatestTurn()
        #expect(fixture.session.latestTurn?.isUndone == true)
        try await fixture.waitForBottom(scrollView)

        fixture.api.response = .success(.toolCalls([
            .deleteTransaction(id: "delete-banana", input: VoiceDeleteTransactionInput(
                id: try #require(transactionID).uuidString
            )),
        ], canFinishLocally: true))
        await fixture.session.send("删除香蕉")
        #expect(fixture.session.latestTurn?.changes.first?.entryChange?.kind == .deleted)
        try await fixture.waitForBottom(scrollView)
    }

    @Test("底部判定包含内容边距，并能识别偏移漂移和布局变化")
    func bottomGeometryIncludesInsets() {
        let bottom = VoiceCardScrollGeometry(
            contentHeight: 1_000, containerHeight: 300, offsetY: 720, topInset: 10, bottomInset: 20
        )
        #expect(bottom.isAtBottom)
        var drifted = bottom
        drifted.offsetY = 680
        #expect(!drifted.isAtBottom)
        #expect(!drifted.hasDifferentLayout(from: bottom))
        var resized = bottom
        resized.containerHeight = 260
        #expect(!resized.isAtBottom)
        #expect(resized.hasDifferentLayout(from: bottom))
        #expect(VoiceCardScrollGeometry(
            contentHeight: 100, containerHeight: 300, offsetY: -10, topInset: 10, bottomInset: 20
        ).isAtBottom)
    }

    /// 持有真实卡片、隔离会话和可控输入，并通过 UIKit 读取最终滚动位置。
    @MainActor
    private final class Fixture {
        /// 固定语言，避免文字测量随测试设备语言变化。
        static let locale = Locale(identifier: "zh-Hans")

        /// 可控的识别输入。
        let recognizer = CardSpeechRecognizer()

        /// 可暂停的会话接口。
        let api = CardSessionAPI()

        /// 实际驱动卡片的交互控制器。
        let input: VoiceInputController

        /// 实际驱动卡片的会话。
        let session: VoiceSession

        /// 会话使用的隔离数据库，供真实流水写入场景准备账户。
        let sessionContainer: ModelContainer

        /// 承载卡片的独立窗口，不改变应用的主窗口。
        private let window: UIWindow

        init() throws {
            input = VoiceInputController(recognizer: recognizer, permission: { .granted }, holdDelay: .zero)
            sessionContainer = try AccountDataContainer.inMemory().modelContainer
            session = VoiceSession(
                container: sessionContainer,
                api: api,
                locale: Self.locale,
                timingStore: VoiceTimingStore(fileURL: nil)
            )
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        }

        /// 准备足够长的历史，确保后续同高度更新也发生在可滚动状态。
        func seedHistory() async {
            api.response = .success(.reply(text: String(repeating: "历史记账结果\n", count: 30)))
            await session.send("查看之前的记录")
        }

        /// 展示真实 SwiftUI 卡片，并保留正式页面的外层动画环境。
        func show() {
            window.rootViewController = UIHostingController(rootView:
                VoiceSessionCard(
                    session: session, input: input,
                    onLocateChange: { _ in }, onOpenTransaction: { _ in }, onOpenAccount: { _ in },
                    onManualEntry: { _ in }, onSignIn: {}, onEnd: {}
                )
                .environment(\.locale, Self.locale)
                .animation(.easeOut(duration: 0.2), value: session.latestTurn)
                .frame(maxHeight: .infinity, alignment: .bottom)
            )
            window.isHidden = false
        }

        /// 找到卡片实际创建的原生滚动区域。
        func scrollView() async throws -> UIScrollView {
            try await waitUntil {
                guard let scrollView = self.findScrollView(in: self.window) else { return false }
                return scrollView.bounds.height > 0 && scrollView.contentSize.height > scrollView.bounds.height
            }
            return try #require(findScrollView(in: window))
        }

        /// 模拟布局造成的偏移漂移；这不是用户拖动，应由跟随逻辑自动校正。
        func displaceOffset(_ scrollView: UIScrollView) {
            scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
        }

        /// 连续检查至少 350 毫秒，确保布局稳定后仍在底部，而非只在某一帧碰巧到达。
        func waitForBottom(_ scrollView: UIScrollView) async throws {
            var consecutiveBottomChecks = 0
            for _ in 0..<200 {
                window.layoutIfNeeded()
                consecutiveBottomChecks = isAtBottom(scrollView) ? consecutiveBottomChecks + 1 : 0
                if consecutiveBottomChecks >= 36 { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(consecutiveBottomChecks >= 36)
        }

        /// 判定实际偏移是否到达含 inset 的底部，允许像素取整误差。
        func isAtBottom(_ scrollView: UIScrollView) -> Bool {
            let bottom = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            return scrollView.bounds.height > 0 && abs(scrollView.contentOffset.y - bottom) < 2
        }

        /// 有界等待主线程布局、观察更新与滚动请求，超时直接报告断言失败。
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                window.layoutIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(condition())
        }

        /// 释放窗口和所有挂起的识别、接口请求。
        func close() {
            input.cancel()
            api.complete(with: .failure(.serviceUnavailable))
            window.isHidden = true
            window.rootViewController = nil
        }

        /// 只查询系统滚动视图类型，不依赖 SwiftUI 私有视图名称。
        private func findScrollView(in view: UIView) -> UIScrollView? {
            if let scrollView = view as? UIScrollView { return scrollView }
            return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
        }
    }
}

/// 可观测的假识别器，允许在收音和松手收尾阶段继续修正文字。
@MainActor
@Observable
private final class CardSpeechRecognizer: VoiceSpeechRecognizing {
    /// 当前识别阶段。
    var state = VoiceSpeechRecognizer.State.idle

    /// 测试直接推进的转写文字。
    var transcript = ""

    /// 松手后等待最终结果的任务。
    private var stopContinuation: CheckedContinuation<String, Never>?

    func prepare(locale: Locale, contextualStrings: [String]) {}

    func start(locale: Locale, contextualStrings: [String]) async throws {
        state = .recording
    }

    func stopCapture() {}

    func stop() async -> String {
        state = .finishing
        return await withCheckedContinuation { stopContinuation = $0 }
    }

    func cancel() {
        state = .idle
        stopContinuation?.resume(returning: "")
        stopContinuation = nil
    }
}

/// 默认立即回复，也可由测试手动完成请求以覆盖处理中到结果的转换。
@MainActor
private final class CardSessionAPI: VoiceSessionTurnSending {
    /// 默认响应。
    var response: Result<VoiceSessionTurnResponse, VoiceSessionAPIError> = .success(.reply(text: "已记账"))

    /// 是否暂停请求，等待测试返回结果。
    var holdsResponse = false

    /// 等待中的请求。
    private var continuation: CheckedContinuation<VoiceSessionTurnResponse, any Error>?

    /// 是否已进入等待阶段。
    var hasPendingResponse: Bool { continuation != nil }

    func send(_ request: VoiceSessionTurnRequest, trace: VoiceRequestTrace) async throws -> VoiceSessionTurnResponse {
        guard holdsResponse else { return try response.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    /// 返回结果并清理等待中的请求。
    func complete(with result: Result<VoiceSessionTurnResponse, VoiceSessionAPIError>) {
        continuation?.resume(with: result.mapError { $0 as any Error })
        continuation = nil
    }
}
