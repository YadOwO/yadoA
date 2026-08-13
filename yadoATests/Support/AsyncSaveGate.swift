import Foundation

/// 测试中用于挂起一次异步保存，直到用例显式恢复。
@MainActor
final class AsyncSaveGate {
    /// 保存是否已进入挂起点。
    private(set) var hasStarted = false

    /// 恢复挂起保存的 continuation。
    private var continuation: CheckedContinuation<Void, Never>?

    /// 标记保存已开始并保持挂起。
    func wait() async {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// 恢复当前挂起的保存。
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
