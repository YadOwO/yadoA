import Foundation
import Testing

/// 文案目录的完整性：面向用户的每条文案都要有英文、简体、繁体三种。
///
/// App 按语言取文案时不会退回英文，漏了哪种语言，界面上就会直接露出文案键名。
/// 直接读源码里的 `.xcstrings`，和 `SyncChangeTrackerTests` 读源码的做法一样。
@Suite("文案三种语言齐全")
struct LocalizationCompletenessTests {
    /// 每条文案都要有的语言。
    private static let requiredLanguages = ["en", "zh-Hans", "zh-Hant"]

    /// 不需要翻译的条目：只给系统用，不出现在界面上。
    private static let exemptKeys: Set<String> = ["CFBundleName"]

    @Test(
        "每条面向用户的文案都有英文、简体、繁体",
        arguments: ["Localizable.xcstrings", "InfoPlist.xcstrings", "AppShortcuts.xcstrings"]
    )
    func everyEntryHasAllLanguages(catalog: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "yadoA")
            .appending(path: catalog)
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try #require(object as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])

        var missing: [String] = []
        for (key, value) in strings {
            guard let entry = value as? [String: Any], Self.needsTranslation(key: key, entry: entry) else { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            let absent = Self.requiredLanguages.filter { localizations[$0] == nil }
            if !absent.isEmpty {
                missing.append("\(key)（缺 \(absent.joined(separator: "、"))）")
            }
        }

        #expect(missing.isEmpty, "\(catalog) 里缺语言的文案：\(missing.sorted())")
    }

    /// 条目是否需要三种语言：标了不翻译、在豁免名单里，或去掉占位符后没有文字（例如 `%@, %@`）的不需要。
    private static func needsTranslation(key: String, entry: [String: Any]) -> Bool {
        if entry["shouldTranslate"] as? Bool == false || exemptKeys.contains(key) {
            return false
        }
        let withoutPlaceholders = key.replacingOccurrences(
            of: "%(\\d+\\$)?(ll|l)?[@dfsu]",
            with: "",
            options: .regularExpression
        )
        return withoutPlaceholders.contains { $0.isLetter }
    }
}
