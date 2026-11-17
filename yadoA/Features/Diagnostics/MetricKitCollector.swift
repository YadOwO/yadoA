import Foundation
import MetricKit
import os

/// 订阅 MetricKit 诊断，精简后存到本机；不上传，只有用户在意见反馈里勾选才会随反馈发送。
nonisolated final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    /// 全局唯一实例。
    static let shared = MetricKitCollector()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yadoA", category: "MetricKit")
    private let lock = NSLock()
    private var started = false

    /// 开始订阅；重复调用无害。
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    /// 收到诊断包：精简后保存到本机，失败只记日志。
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.flatMap { DiagnosticReport.reports(from: $0) }
        do {
            try DiagnosticStore.shared.save(reports)
        } catch {
            logger.error("保存诊断失败：\(error.localizedDescription)")
        }
    }
}
