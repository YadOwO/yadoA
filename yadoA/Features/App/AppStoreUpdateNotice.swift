import Foundation
import Observation
import SwiftUI
import UIKit

/// App Store 上的一个版本：「发现新版本」弹层要显示的内容。
nonisolated struct AppStoreRelease: Equatable, Identifiable, Sendable {
    /// 营销版本号，例如 `1.2.0`。
    let version: String

    /// 这个版本的更新说明（App Store Connect 里填的「此版本的新增内容」）；没填时为 nil，弹层不显示这一段。
    let releaseNotes: String?

    /// App Store 产品页地址，「前往 App Store 更新」打开它。
    let storeURL: URL

    /// 用版本号区分，同一个版本只弹一次。
    var id: String { version }

    /// 「开发」页预览弹层用的示例版本，不联网。
    static let preview = AppStoreRelease(
        version: "9.9.0",
        releaseNotes: "· 图表可以左右滑动查看每一天\n· 清除数据移到设置的「数据」分组\n· 修复若干问题，提升稳定性",
        storeURL: URL(string: "https://apps.apple.com/")!
    )
}

/// 向 App Store 查询本 App 最新版本：用 Bundle ID 调 iTunes Lookup 接口，不需要 App Store 数字 ID。
///
/// 接口按店面（国家 / 地区）返回结果，App 没在某个店面上架时那个店面查不到；
/// 先查系统地区对应的店面，查不到再查 `fallbackCountryCodes` 里的店面。
nonisolated enum AppStoreLookup {
    /// 系统地区的店面查不到时再试的店面：芽豆记账主要在中国大陆店面上架。
    static let fallbackCountryCodes = ["cn"]

    /// 单次查询的超时时间；查不到就算了，不影响使用。
    static let timeout: TimeInterval = 10

    /// 拼出查询地址。
    ///
    /// - Parameters:
    ///   - bundleID: 本 App 的 Bundle ID。
    ///   - countryCode: 两位店面代码（小写），例如 `cn`。
    /// - Returns: iTunes Lookup 接口地址。
    static func url(bundleID: String, countryCode: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "country", value: countryCode),
        ]
        return components?.url
    }

    /// 依次要查的店面：先系统地区，再兜底店面，去重。
    ///
    /// - Parameter region: 系统地区，通常取 `Locale.current.region`；不是两位国家代码时跳过。
    static func countryCodes(region: Locale.Region?) -> [String] {
        var codes: [String] = []
        if let identifier = region?.identifier, identifier.count == 2, identifier.allSatisfy(\.isLetter) {
            codes.append(identifier.lowercased())
        }
        for code in fallbackCountryCodes where !codes.contains(code) {
            codes.append(code)
        }
        return codes
    }

    /// 解析查询结果。
    ///
    /// - Parameter data: 接口返回的 JSON。
    /// - Returns: 查到的版本；这个店面没有本 App，或缺版本号、产品页地址时为 nil。
    /// - Throws: 返回的不是约定格式的 JSON 时抛出 `DecodingError`。
    static func parse(_ data: Data) throws -> AppStoreRelease? {
        let response = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let result = response.results.first,
              let version = result.version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty,
              let urlString = result.trackViewUrl, let storeURL = URL(string: urlString)
        else { return nil }
        let notes = result.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppStoreRelease(
            version: version,
            releaseNotes: notes?.isEmpty == false ? notes : nil,
            storeURL: storeURL
        )
    }

    /// 比较两个营销版本号：按点分段逐段比数字，位数不同时缺的段当 0（`1.2` 与 `1.2.0` 相同）。
    ///
    /// - Parameters:
    ///   - candidate: App Store 上的版本号。
    ///   - current: 本机安装的版本号。
    /// - Returns: `candidate` 比 `current` 新时为 true；任一方为空时为 false。
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = components(of: candidate)
        let rhs = components(of: current)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// 依次查各店面，返回第一个查到的版本。
    ///
    /// - Parameters:
    ///   - bundleID: 本 App 的 Bundle ID。
    ///   - countryCodes: 依次要查的店面。
    ///   - fetch: 发请求取回数据，测试可以替换。
    /// - Returns: 查到的版本；各店面都没有本 App 时为 nil。
    /// - Throws: 网络出错或返回格式不对时抛出，调用方据此不记录「已检查」，下次启动再试。
    static func latestRelease(
        bundleID: String,
        countryCodes: [String],
        fetch: @Sendable (URL) async throws -> Data
    ) async throws -> AppStoreRelease? {
        for code in countryCodes {
            guard let url = url(bundleID: bundleID, countryCode: code) else { continue }
            let data = try await fetch(url)
            if let release = try parse(data) {
                return release
            }
        }
        return nil
    }

    /// 默认的请求方式：不用缓存，超时 `timeout` 秒，非 200 当作出错。
    ///
    /// - Parameter url: 查询地址。
    /// - Returns: 响应数据。
    /// - Throws: 网络错误，或 HTTP 状态码不是 200 时的 `URLError(.badServerResponse)`。
    @concurrent
    static func fetch(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// 版本号按点拆成数字；某段不是数字时取它开头的数字部分，没有就当 0。
    private static func components(of version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: ".", omittingEmptySubsequences: false).map { part in
            Int(part.prefix { $0.isASCII && $0.isNumber }) ?? 0
        }
    }

    /// iTunes Lookup 接口的返回，只取用到的字段。
    nonisolated private struct LookupResponse: Decodable {
        let results: [LookupResult]
    }

    /// 查询结果里的一个 App。
    nonisolated private struct LookupResult: Decodable {
        let version: String?
        let releaseNotes: String?
        let trackViewUrl: String?
    }
}

/// 「发现新版本」提示的全局状态：启动后查一次 App Store，有比本机新的版本时弹一次说明。
///
/// - 和 `AppUpdatePrompt`（接口返回 426、必须更新）不同，这里只是告知，点「稍后再说」照常使用。
/// - 同一个版本只弹一次；一天最多查一次，查询失败不计数，下次启动再试。
/// - 只在允许联网（同意了隐私政策或不需要同意的地区）、首次引导和同意卡都结束后才查，见 `AppUpdateNoticeModifier`。
/// - 查到后先记为待弹（`pendingRelease`），等界面上没有别的弹层（记账页、聊天页、登录页、426 提示等）时才真正弹出：
///   弹层挂在根视图上，别的弹层还开着时 SwiftUI 弹不出来，这个版本会就此错过。
/// - 查到的产品页地址存下来，426 提示里没有配置 App Store 数字 ID 时也能跳转。
/// - 查到的版本号也存下来：只要本机还没更新，「我的」页底部就一直显示「新版本可用」（`availableRelease`），不受「只弹一次」限制。
@MainActor
@Observable
final class AppUpdateNotice {
    /// 应用内唯一的提示通道。
    static let shared = AppUpdateNotice()

    /// 上次查询成功的时间的存储键。
    nonisolated static let lastCheckedKey = "appUpdate.notice.lastCheckedAt"

    /// 已经弹过的版本号的存储键。
    nonisolated static let notifiedVersionKey = "appUpdate.notice.notifiedVersion"

    /// 上次查到的 App Store 产品页地址的存储键。
    nonisolated static let storeURLKey = "appUpdate.notice.storeURL"

    /// 上次查到的 App Store 版本号的存储键；一天只查一次，没查的那几次启动靠它显示「有新版本」。
    nonisolated static let latestVersionKey = "appUpdate.notice.latestVersion"

    /// 两次查询的最短间隔：一天。
    nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60

    /// 正在弹出的新版本；为 nil 时不显示弹层。
    var presentedRelease: AppStoreRelease?

    /// App Store 上比本机新的版本，「我的」页底部据此显示「新版本可用 · 前往更新」；没有更新的版本时为 nil。
    ///
    /// 和弹层不同，这里不管弹没弹过、426 提示有没有出过，只要还没更新就一直显示。
    /// 启动时从上次查到的版本号和产品页地址算出来，本机更新到这个版本后自然消失；不带更新说明。
    private(set) var availableRelease: AppStoreRelease?

    /// 已经查到、还没弹出的新版本：等界面上没有别的弹层时由 `presentPending()` 弹出；没有待弹的版本时为 nil。
    private(set) var pendingRelease: AppStoreRelease?

    /// 本次启动是否已经查过（含正在查）；同一次启动不重复查。
    private var hasChecked = false

    /// 保存查询时间、弹过的版本和产品页地址。
    private let defaults: UserDefaults

    /// 本机安装的营销版本号。
    private let currentVersion: String

    /// 本 App 的 Bundle ID；dev 包的 Bundle ID 没有上架，查不到结果，不会弹。
    private let bundleID: String?

    /// 依次要查的店面。
    private let countryCodes: [String]

    /// 发请求取回数据。
    private let fetch: @Sendable (URL) async throws -> Data

    /// 426「需要更新」提示；它本次启动弹过时不再叠一个。nil 时用 `AppUpdatePrompt.shared`。
    private let upgradePrompt: AppUpdatePrompt?

    /// 创建提示状态。
    ///
    /// - Parameters:
    ///   - defaults: 保存状态的存储，测试传入隔离实例。
    ///   - currentVersion: 本机营销版本号。
    ///   - bundleID: 本 App 的 Bundle ID。
    ///   - countryCodes: 依次要查的店面；nil 时按系统地区和兜底店面生成。
    ///   - fetch: 发请求取回数据，测试可以替换。
    ///   - upgradePrompt: 426「需要更新」提示，测试传入独立实例；nil 时用 `AppUpdatePrompt.shared`。
    init(
        defaults: UserDefaults = .standard,
        currentVersion: String = AppVersion.marketingVersion,
        bundleID: String? = Bundle.main.bundleIdentifier,
        countryCodes: [String]? = nil,
        fetch: @escaping @Sendable (URL) async throws -> Data = { try await AppStoreLookup.fetch($0) },
        upgradePrompt: AppUpdatePrompt? = nil
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.bundleID = bundleID
        self.countryCodes = countryCodes ?? AppStoreLookup.countryCodes(region: Locale.current.region)
        self.fetch = fetch
        self.upgradePrompt = upgradePrompt
        if let version = defaults.string(forKey: Self.latestVersionKey),
           let storeURL = defaults.url(forKey: Self.storeURLKey) {
            availableRelease = Self.newerRelease(
                AppStoreRelease(version: version, releaseNotes: nil, storeURL: storeURL),
                currentVersion: currentVersion
            )
        }
    }

    /// 查到的版本比本机新时原样返回，否则为 nil。
    ///
    /// - Parameters:
    ///   - release: App Store 上的版本。
    ///   - currentVersion: 本机营销版本号。
    private static func newerRelease(_ release: AppStoreRelease, currentVersion: String) -> AppStoreRelease? {
        AppStoreLookup.isVersion(release.version, newerThan: currentVersion) ? release : nil
    }

    /// 上次查到的 App Store 产品页地址；还没查到过时为 nil。
    var storeURL: URL? {
        defaults.url(forKey: Self.storeURLKey)
    }

    /// 需要时查一次 App Store，有没弹过的新版本就记为待弹（`pendingRelease`），由调用方挑没有别的弹层的时候弹出。
    ///
    /// 同一次启动只查一次；距上次查询成功不到 `checkInterval` 时不查。本次启动已经弹过 426 提示时不再叠一个。
    ///
    /// - Parameter now: 当前时间，测试可以指定。
    func checkIfNeeded(now: Date = .now) async {
        guard !hasChecked else { return }
        hasChecked = true
        if let lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date,
           now.timeIntervalSince(lastChecked) < Self.checkInterval {
            return
        }
        guard let bundleID, !currentVersion.isEmpty else { return }

        let release: AppStoreRelease?
        do {
            release = try await AppStoreLookup.latestRelease(bundleID: bundleID, countryCodes: countryCodes, fetch: fetch)
        } catch {
            // 网络不通或格式不对：不记查询时间，下次启动再试
            return
        }
        defaults.set(now, forKey: Self.lastCheckedKey)
        guard let release else {
            // 各店面都查不到（下架等）：不再提示有新版本；产品页地址留着给 426 提示用
            defaults.removeObject(forKey: Self.latestVersionKey)
            availableRelease = nil
            return
        }
        defaults.set(release.storeURL, forKey: Self.storeURLKey)
        defaults.set(release.version, forKey: Self.latestVersionKey)
        availableRelease = Self.newerRelease(release, currentVersion: currentVersion)

        guard availableRelease != nil,
              defaults.string(forKey: Self.notifiedVersionKey) != release.version,
              !(upgradePrompt ?? .shared).hasPrompted
        else { return }
        pendingRelease = release
    }

    /// 弹出待弹的新版本；没有待弹的版本时什么也不做。
    func presentPending() {
        guard let pendingRelease else { return }
        self.pendingRelease = nil
        presentedRelease = pendingRelease
    }

    /// 弹层真正显示出来时调用：记下这个版本，之后不再为它弹。
    ///
    /// - Parameter release: 正在显示的版本。
    func markNotified(_ release: AppStoreRelease) {
        guard release != .preview else { return }
        defaults.set(release.version, forKey: Self.notifiedVersionKey)
    }

    /// 「开发」页预览：用示例版本弹出弹层，同时让「我的」页底部出现「新版本可用」那一行（重启 App 后消失）；不联网、不记录。
    func presentPreview() {
        presentedRelease = .preview
        availableRelease = .preview
    }
}

/// 在应用根视图上挂「发现新版本」弹层，并在合适的时机查一次 App Store。
///
/// 允许联网、首次引导和隐私政策同意卡都结束后才查；UI 自动化（`--ui-testing-in-memory`）下不查，免得弹层挡住用例。
/// 查到新版本时如果界面上正开着别的弹层，每隔几秒看一次，等它们都关掉再弹。
struct AppUpdateNoticeModifier: ViewModifier {
    /// 等别的弹层关掉时，两次查看的间隔。
    private static let presentationRetryInterval: Duration = .seconds(3)

    /// 全局提示状态。
    @State private var notice = AppUpdateNotice.shared

    /// 现在能不能查：允许联网，而且首次引导、同意卡和登录页都不在屏幕上。
    let canCheck: Bool

    func body(content: Content) -> some View {
        content
            .task(id: canCheck) {
                guard canCheck, !Self.isUITesting else { return }
                // 等启动动画和引导收尾的过渡走完再查，弹层不和它们抢
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await notice.checkIfNeeded()
                // 查到时用户可能已经打开了记账页、聊天页等弹层，从根视图弹不出来：等它们都关掉再弹。
                // 中途 canCheck 变化会取消这里，变回 true 时重新进来，待弹的版本还在，接着等
                while notice.pendingRelease != nil, !Task.isCancelled {
                    if Self.isScreenFree {
                        notice.presentPending()
                        break
                    }
                    try? await Task.sleep(for: Self.presentationRetryInterval)
                }
            }
            .sheet(item: $notice.presentedRelease) { release in
                AppUpdateAvailableSheet(release: release) {
                    notice.presentedRelease = nil
                }
                .onAppear { notice.markNotified(release) }
            }
    }

    /// 是否在跑 UI 自动化。
    private static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-in-memory")
    }

    /// 界面上是不是没有别的弹层：App 在前台，而且前台场景的每个窗口都没有正在显示的弹层（sheet、全屏页、系统 alert）。
    ///
    /// SwiftUI 不提供「当前有没有弹层」的全局状态，这里直接看 UIKit 的 `presentedViewController`。
    /// 应用锁在单独的高层级窗口里（`AppLockGate`），锁着时弹层出在锁屏底下，解锁后就能看到。
    private static var isScreenFree: Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) else { return false }
        return scene.windows.allSatisfy { $0.rootViewController?.presentedViewController == nil }
    }
}

/// 「发现新版本」弹层：版本号、更新说明，以及「前往 App Store 更新」和「稍后再说」。
///
/// 半屏弹出，更新说明长时可以上拉到全屏或在弹层里滚动；颜色都用系统语义色，浅色、深色外观自动适配。
struct AppUpdateAvailableSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL

    /// 要介绍的版本。
    let release: AppStoreRelease

    /// 关闭弹层。
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if let notes = release.releaseNotes {
                    releaseNotes(notes)
                }

                actions
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .paperPage()
        .presentationDetents(release.releaseNotes == nil ? [.medium] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-update-notice")
    }

    /// 品牌图标、标题和版本号。
    private var header: some View {
        VStack(spacing: 12) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            Text(text("appUpdate.notice.title"))
                .font(.system(.title3, design: .serif, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(String(format: text("appUpdate.notice.version"), locale: locale, release.version))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 「更新内容」和 App Store 上填的说明。
    ///
    /// - Parameter notes: 更新说明。
    private func releaseNotes(_ notes: String) -> some View {
        LedgerCard(seed: 211) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text("appUpdate.notice.notes"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .ledgerCardRow()
        }
    }

    /// 去更新和稍后再说。
    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                openURL(release.storeURL)
                onClose()
            } label: {
                ProfilePrimaryButtonLabel(title: text("appUpdate.notice.update"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("app-update-notice-update")

            Button(text("appUpdate.notice.later")) {
                onClose()
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .accessibilityIdentifier("app-update-notice-later")
        }
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AppUpdateAvailableSheet(release: .preview) {}
        }
}
