import Foundation

/// App Store 产品页地址的统一拼法。
nonisolated enum AppStoreLink {
    /// 由 App Store 数字 ID 拼出产品页地址；ID 为空、为 nil 或含非 ASCII 数字字符时为 nil，防止拼出非法链接。
    ///
    /// - Parameter id: App Store 数字 ID。
    /// - Returns: 产品页地址；ID 不合法时为 nil。
    static func productURL(id: String?) -> URL? {
        guard let id,
              !id.isEmpty,
              id.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(id)")
    }
}
