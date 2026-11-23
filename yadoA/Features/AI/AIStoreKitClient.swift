import Foundation
import StoreKit

/// StoreKit 里的一个商品，只留界面和购买用得到的信息；测试用假数据创建，不依赖 StoreKit 的 `Product`。
nonisolated struct AIStoreProduct: Equatable, Identifiable, Sendable {
    /// 自动续期订阅的周期单位。
    nonisolated enum PeriodUnit: Equatable, Sendable {
        case day, week, month, year
    }

    /// 商品 ID。
    let id: String

    /// App Store Connect 里填的商品名称，已按用户的语言本地化。
    let displayName: String

    /// 当地价格文本，例如“¥6.00”“$0.99”。
    let displayPrice: String

    /// 自动续期订阅的周期，例如 1 个月；不是订阅时为 nil。以后服务端开卖订阅时，旧版 App 也能据此显示周期和续订说明。
    let subscriptionPeriod: (unit: PeriodUnit, value: Int)?

    /// 是否是自动续期订阅。
    var isSubscription: Bool {
        subscriptionPeriod != nil
    }

    /// 逐字段创建。
    init(id: String, displayName: String, displayPrice: String, subscriptionPeriod: (unit: PeriodUnit, value: Int)? = nil) {
        self.id = id
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.subscriptionPeriod = subscriptionPeriod
    }

    static func == (lhs: AIStoreProduct, rhs: AIStoreProduct) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName && lhs.displayPrice == rhs.displayPrice
            && lhs.subscriptionPeriod?.unit == rhs.subscriptionPeriod?.unit
            && lhs.subscriptionPeriod?.value == rhs.subscriptionPeriod?.value
    }
}

/// 一笔已经通过 StoreKit 本机校验、等待入账的交易。
struct AIStoreTransaction: Sendable {
    /// App Store 的交易 ID。
    let id: UInt64

    /// 商品 ID。
    let productID: String

    /// Apple 签名的交易（JWS），上传给服务端校验入账。
    let signedTransaction: String

    /// 结束这笔交易；只能在服务端入账成功（或确定永远入不了账）之后调用，否则 StoreKit 不会再交付它。
    let finish: @Sendable () async -> Void
}

/// 一次购买在 StoreKit 这一侧的结果。
enum AIStoreKitPurchaseOutcome: Sendable {
    /// 付款成功，交易等待入账。
    case success(AIStoreTransaction)

    /// 等待中：家长批准（询问购买）或银行验证，完成后从交易更新里交付。
    case pending

    /// 用户取消。
    case cancelled
}

/// StoreKit 购买出错的原因。
enum AIStoreKitError: Error, Equatable {
    /// 商品还没从 StoreKit 加载，或已下架。
    case productUnavailable

    /// StoreKit 本机校验交易失败（签名不对），不交付、不上传。
    case unverified
}

/// StoreKit 的能力：查商品、购买、读取没结束的交易、监听交易更新；测试注入假实现。
protocol AIStoreKitProviding: AnyObject {
    /// 按商品 ID 查商品；查不到的商品（没在 App Store Connect 建好、已下架）不在结果里。
    ///
    /// - Parameter ids: 商品 ID。
    /// - Returns: 查到的商品。
    /// - Throws: StoreKit 的网络或系统错误。
    func products(for ids: [String]) async throws -> [AIStoreProduct]

    /// 购买一个已查到的商品。
    ///
    /// - Parameters:
    ///   - productID: 商品 ID，必须先用 `products(for:)` 查过。
    ///   - appAccountToken: 服务端给的账号标识，Apple 原样写进交易，服务端据此确认交易属于哪个账号。
    /// - Returns: 购买结果。
    /// - Throws: `AIStoreKitError` 或 StoreKit 的错误。
    func purchase(productID: String, appAccountToken: UUID) async throws -> AIStoreKitPurchaseOutcome

    /// 当前 Apple 账号下还没结束的交易（付了款但还没确认入账的）。
    ///
    /// - Returns: 通过本机校验的交易。
    func unfinishedTransactions() async -> [AIStoreTransaction]

    /// 开始监听交易更新（询问购买获批、在其他设备购买、订阅续订等），整个 App 生命周期只调用一次。
    ///
    /// - Parameter handler: 收到一笔通过本机校验的交易时调用。
    /// - Returns: 监听任务。
    func observeTransactionUpdates(_ handler: @escaping @MainActor (AIStoreTransaction) async -> Void) -> Task<Void, Never>
}

/// 基于 StoreKit 2 的实现。
final class AIStoreKitClient: AIStoreKitProviding {
    /// 查到的商品，购买时要用 StoreKit 的 `Product` 对象。
    private var loadedProducts: [String: Product] = [:]

    func products(for ids: [String]) async throws -> [AIStoreProduct] {
        guard !ids.isEmpty else { return [] }
        let products = try await Product.products(for: ids)
        for product in products {
            loadedProducts[product.id] = product
        }
        return products.map(Self.storeProduct)
    }

    func purchase(productID: String, appAccountToken: UUID) async throws -> AIStoreKitPurchaseOutcome {
        guard let product = loadedProducts[productID] else {
            throw AIStoreKitError.productUnavailable
        }
        let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
        switch result {
        case let .success(verification):
            guard let transaction = Self.storeTransaction(from: verification) else {
                throw AIStoreKitError.unverified
            }
            return .success(transaction)
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func unfinishedTransactions() async -> [AIStoreTransaction] {
        var transactions: [AIStoreTransaction] = []
        for await verification in Transaction.unfinished {
            if let transaction = Self.storeTransaction(from: verification) {
                transactions.append(transaction)
            }
        }
        return transactions
    }

    func observeTransactionUpdates(_ handler: @escaping @MainActor (AIStoreTransaction) async -> Void) -> Task<Void, Never> {
        Task {
            for await verification in Transaction.updates {
                if let transaction = Self.storeTransaction(from: verification) {
                    await handler(transaction)
                }
            }
        }
    }

    /// 把 StoreKit 的商品转成界面用的商品。
    ///
    /// - Parameter product: StoreKit 商品。
    /// - Returns: 界面用的商品。
    private static func storeProduct(_ product: Product) -> AIStoreProduct {
        let period = product.type == .autoRenewable ? product.subscription?.subscriptionPeriod : nil
        return AIStoreProduct(
            id: product.id,
            displayName: product.displayName,
            displayPrice: product.displayPrice,
            subscriptionPeriod: period.map { (unit: periodUnit($0.unit), value: $0.value) }
        )
    }

    /// 订阅周期单位的转换。
    ///
    /// - Parameter unit: StoreKit 的周期单位。
    /// - Returns: 界面用的周期单位。
    private static func periodUnit(_ unit: Product.SubscriptionPeriod.Unit) -> AIStoreProduct.PeriodUnit {
        switch unit {
        case .day: .day
        case .week: .week
        case .month: .month
        case .year: .year
        @unknown default: .month
        }
    }

    /// 只交付通过 StoreKit 本机校验的交易；没通过的不上传，也不结束（服务端同样会拒绝它）。
    ///
    /// - Parameter verification: StoreKit 的校验结果。
    /// - Returns: 待入账的交易；没通过校验时为 nil。
    private static func storeTransaction(from verification: VerificationResult<Transaction>) -> AIStoreTransaction? {
        guard case let .verified(transaction) = verification else { return nil }
        return AIStoreTransaction(
            id: transaction.id,
            productID: transaction.productID,
            signedTransaction: verification.jwsRepresentation,
            finish: { await transaction.finish() }
        )
    }
}
