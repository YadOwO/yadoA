import Foundation

/// 注销确认页里显示的一行。
nonisolated enum AccountDataSummaryRow: Equatable, Sendable, Identifiable {
    /// 某个产品的某类数据有多少：`titleKey` 对应的文案带一个 `%lld`，把 `count` 填进去。
    case count(titleKey: String, count: Int)

    /// 某个产品暂时查不到：`productNameKey` 对应产品名，文案是「<产品名>：暂时查不到」。
    case unavailable(productNameKey: String)

    /// 是不是「暂时查不到」的那一行，界面用次要色显示。
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// 列表里区分每一行：同一个文案键不会出现两次。
    var id: String {
        switch self {
        case let .count(titleKey, _): titleKey
        case let .unavailable(productNameKey): productNameKey
        }
    }
}

/// yado_hub `GET /v1/account/summary` 返回的各产品数据量，注销确认页据此列出「会删掉什么」。
///
/// hub 已经把数量为 0 的项、查到了但没有任何项的服务去掉；某个下游查不到（超时、出错）时，那个服务的 `status` 是 `unavailable`、
/// `items` 为空，不影响注销。App 靠「服务名 + key」对应文案，认不出的服务或 key 直接跳过，
/// 所以以后 hub 加了新产品或新类别，旧版 App 也不会出错。
nonisolated struct AccountDataSummary: Decodable, Equatable, Sendable {
    /// 一个下游服务的汇总结果。
    nonisolated struct Service: Decodable, Equatable, Sendable {
        /// 服务名，hub 固定为 `yado-ai`、`yadoa-be`、`yadoi-be`。
        let service: String

        /// 这个服务有没有查到。
        let status: Status

        /// 各类数据的数量；没查到时为空。
        let items: [Item]

        /// - Parameters:
        ///   - service: 服务名。
        ///   - status: 有没有查到。
        ///   - items: 各类数据的数量。
        init(service: String, status: Status, items: [Item] = []) {
            self.service = service
            self.status = status
            self.items = items
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            service = try container.decode(String.self, forKey: .service)
            status = try container.decode(Status.self, forKey: .status)
            items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case service
            case status
            case items
        }
    }

    /// 服务有没有查到。
    nonisolated enum Status: Equatable, Sendable, Decodable {
        /// 查到了。
        case ok

        /// 暂时查不到；hub 以后加的其他取值也按它处理，只会多显示一行「暂时查不到」。
        case unavailable

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = value == "ok" ? .ok : .unavailable
        }
    }

    /// 一类数据的数量。
    nonisolated struct Item: Decodable, Equatable, Sendable {
        /// 数据类别，如 `synced_records`；和服务名一起决定显示哪句文案。
        let key: String

        /// 数量，非负整数。
        let count: Int
    }

    /// 各服务的汇总，顺序和 hub 的注销顺序一致。
    let services: [Service]

    /// 界面要显示的行，顺序和服务的顺序一致。
    ///
    /// 查到了的服务，每个认识的数据类别一行（数量为 0 的跳过，hub 已经去掉，这里再兜一次底）；
    /// 查不到的服务，认识的显示一行「<产品名>：暂时查不到」；认不出的服务或类别跳过。
    var rows: [AccountDataSummaryRow] {
        services.flatMap { service -> [AccountDataSummaryRow] in
            switch service.status {
            case .ok:
                return service.items.compactMap { item in
                    guard item.count > 0, let titleKey = Self.titleKey(service: service.service, key: item.key) else {
                        return nil
                    }
                    return .count(titleKey: titleKey, count: item.count)
                }
            case .unavailable:
                guard let productNameKey = Self.productNameKey(service: service.service) else { return [] }
                return [.unavailable(productNameKey: productNameKey)]
            }
        }
    }

    /// 某个服务的某类数据对应的整句文案键，文案里带一个 `%lld`；认不出时为 nil。
    ///
    /// - Parameters:
    ///   - service: hub 的服务名。
    ///   - key: 数据类别。
    private static func titleKey(service: String, key: String) -> String? {
        switch (service, key) {
        case ("yadoa-be", "synced_records"): "account.delete.summary.yadoa.synced_records"
        case ("yadoi-be", "items"): "account.delete.summary.yadoi.items"
        case ("yado-ai", "points_balance"): "account.delete.summary.ai.points_balance"
        default: nil
        }
    }

    /// 某个服务对应的产品名文案键；认不出时为 nil。
    ///
    /// - Parameter service: hub 的服务名。
    private static func productNameKey(service: String) -> String? {
        switch service {
        case "yadoa-be": "account.delete.summary.product.yadoa"
        case "yadoi-be": "account.delete.summary.product.yadoi"
        case "yado-ai": "account.delete.summary.product.ai"
        default: nil
        }
    }
}
