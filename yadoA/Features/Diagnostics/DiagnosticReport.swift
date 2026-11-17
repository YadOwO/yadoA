import Foundation
import MetricKit

/// 一份精简后的 MetricKit 诊断，只保留排查问题需要的字段。
nonisolated struct DiagnosticReport: Codable, Equatable, Identifiable, Sendable {
    /// 诊断类型；rawValue 与服务端一致。
    nonisolated enum Kind: String, Codable, Sendable {
        /// 崩溃。
        case crash
        /// 卡顿。
        case hang
        /// 磁盘写入异常。
        case diskWrite
    }

    /// 版本字段的长度上限，与服务端一致。
    static let maxVersionLength = 64

    /// 只用于本地文件名和列表，不上传。
    let id: UUID

    /// 诊断类型。
    let kind: Kind

    /// 诊断时间，取 payload 的结束时间。
    let timestamp: Date

    /// 系统版本。
    let osVersion: String

    /// App 版本（CFBundleShortVersionString）。
    let appVersion: String

    /// 构建号。
    let buildVersion: String

    /// 调用栈树的 JSON 文本，本地原样保存。
    let callStackTree: String

    /// 把一份诊断包精简为本地保存的诊断。
    ///
    /// - Parameter payload: MetricKit 回调的诊断包。
    /// - Returns: 崩溃、卡顿、磁盘写入异常三类诊断，其他类型忽略。
    static func reports(from payload: MXDiagnosticPayload) -> [DiagnosticReport] {
        let timestamp = payload.timeStampEnd
        var result: [DiagnosticReport] = []
        for diag in payload.crashDiagnostics ?? [] {
            result.append(make(.crash, diag, timestamp))
        }
        for diag in payload.hangDiagnostics ?? [] {
            result.append(make(.hang, diag, timestamp))
        }
        for diag in payload.diskWriteExceptionDiagnostics ?? [] {
            result.append(make(.diskWrite, diag, timestamp))
        }
        return result
    }

    /// 从单条 MetricKit 诊断构造精简诊断。
    private static func make(_ kind: Kind, _ diag: MXDiagnostic, _ timestamp: Date) -> DiagnosticReport {
        let tree: Data
        switch diag {
        case let crash as MXCrashDiagnostic: tree = crash.callStackTree.jsonRepresentation()
        case let hang as MXHangDiagnostic: tree = hang.callStackTree.jsonRepresentation()
        case let disk as MXDiskWriteExceptionDiagnostic: tree = disk.callStackTree.jsonRepresentation()
        default: tree = Data()
        }
        return DiagnosticReport(
            id: UUID(),
            kind: kind,
            timestamp: timestamp,
            osVersion: normalized(diag.metaData.osVersion),
            appVersion: normalized(diag.applicationVersion),
            buildVersion: normalized(diag.metaData.applicationBuildVersion),
            callStackTree: String(decoding: tree, as: UTF8.self)
        )
    }

    /// 版本字段为空时填 `unknown`，并截到上限。
    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : String(trimmed.prefix(maxVersionLength))
    }
}
