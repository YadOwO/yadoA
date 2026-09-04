import Foundation

/// 备份文件的编解码边界：固定的跨版本 JSON 表达。
///
/// 金额在 DTO 中以字符串承载；日期统一为 UTC ISO-8601（含小数秒），
/// 与当前语言环境和展示文案无关。编码解码两端必须使用同一策略，
/// 避免默认 `.iso8601` 策略在小数秒上抛错的已知陷阱。
enum BackupFileEncoding {
    /// 固定的 UTC ISO-8601 格式器；标准格式保证解析不随系统区域变化。
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// 创建备份文件的 JSON 编码器。
    ///
    /// 输出为稳定排序的缩进 JSON，便于人工检查与跨版本差异对比。
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        return encoder
    }

    /// 创建备份文件的 JSON 解码器。
    ///
    /// 日期策略与编码器严格对称；不符合固定格式的日期串抛出解码错误，
    /// 不得静默回退。
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let date = dateFormatter.date(from: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "备份日期不符合固定 ISO-8601 格式: \(rawValue)"
                )
            }
            return date
        }
        return decoder
    }

    /// 将备份 JSON 数据解码为信封。
    static func decode(_ data: Data) throws -> BackupFile {
        try makeDecoder().decode(BackupFile.self, from: data)
    }
}
