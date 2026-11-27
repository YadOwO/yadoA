import Foundation
import Testing
@testable import yadoA

/// 验证「发现新版本」：版本号比较、店面顺序、查询结果解析，以及弹出、只弹一次和查询间隔。
@Suite("发现新版本")
@MainActor
struct AppUpdateNoticeTests {
    // MARK: - 版本号与查询

    @Test("版本号逐段按数字比较，缺的段当 0")
    func comparesVersionsNumerically() {
        #expect(AppStoreLookup.isVersion("1.2.0", newerThan: "1.1.9"))
        #expect(AppStoreLookup.isVersion("1.10", newerThan: "1.9"))
        #expect(AppStoreLookup.isVersion("2", newerThan: "1.99.99"))
        #expect(AppStoreLookup.isVersion("1.2.1", newerThan: "1.2"))
        #expect(!AppStoreLookup.isVersion("1.2", newerThan: "1.2.0"))
        #expect(!AppStoreLookup.isVersion("1.2.0", newerThan: "1.2.0"))
        #expect(!AppStoreLookup.isVersion("1.1", newerThan: "1.2"))
        // 读不到版本号时不当作有新版本
        #expect(!AppStoreLookup.isVersion("", newerThan: "1.0"))
        #expect(!AppStoreLookup.isVersion("1.0", newerThan: ""))
    }

    @Test("先查系统地区的店面，查不到再查中国大陆店面，不重复")
    func ordersCountryCodes() {
        #expect(AppStoreLookup.countryCodes(region: Locale.Region("US")) == ["us", "cn"])
        #expect(AppStoreLookup.countryCodes(region: Locale.Region("CN")) == ["cn"])
        #expect(AppStoreLookup.countryCodes(region: nil) == ["cn"])
    }

    @Test("查询地址带 Bundle ID 和店面代码")
    func buildsLookupURL() throws {
        let url = try #require(AppStoreLookup.url(bundleID: "top.yado1225.yadoA", countryCode: "cn"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "itunes.apple.com")
        #expect(components.path == "/lookup")
        #expect(components.queryItems?.first { $0.name == "bundleId" }?.value == "top.yado1225.yadoA")
        #expect(components.queryItems?.first { $0.name == "country" }?.value == "cn")
    }

    @Test("解析查询结果：取版本号、更新说明和产品页；说明为空时当作没有")
    func parsesLookupResult() throws {
        let release = try #require(try AppStoreLookup.parse(Self.lookupJSON(version: "1.3.0", notes: "  修复问题  ")))
        #expect(release.version == "1.3.0")
        #expect(release.releaseNotes == "修复问题")
        #expect(release.storeURL.absoluteString == "https://apps.apple.com/cn/app/id1234567890")

        let withoutNotes = try #require(try AppStoreLookup.parse(Self.lookupJSON(version: "1.3.0", notes: " ")))
        #expect(withoutNotes.releaseNotes == nil)
    }

    @Test("店面里没有本 App 时解析为 nil，格式不对时抛错")
    func parsesEmptyAndMalformedResults() throws {
        #expect(try AppStoreLookup.parse(Data(#"{"resultCount":0,"results":[]}"#.utf8)) == nil)
        #expect(throws: DecodingError.self) {
            try AppStoreLookup.parse(Data("not json".utf8))
        }
    }

    // MARK: - 弹出时机

    @Test("App Store 上有更新的版本时弹出；弹过之后同一版本不再弹")
    func presentsNewerVersionOnlyOnce() async throws {
        let defaults = try Self.isolatedDefaults()
        let log = RequestLog()
        let first = Self.makeNotice(defaults: defaults, log: log, remoteVersion: "1.3.0")

        await first.checkIfNeeded(now: Self.day(0))
        let release = try #require(first.pendingRelease)
        #expect(release.version == "1.3.0")
        #expect(first.storeURL == release.storeURL)
        // 查到后先待弹，界面空出来时才真正弹出
        #expect(first.presentedRelease == nil)
        first.presentPending()
        #expect(first.presentedRelease == release)
        #expect(first.pendingRelease == nil)
        first.markNotified(release)

        // 下次启动、过了一天以上再查，同一版本不再弹
        let second = Self.makeNotice(defaults: defaults, log: log, remoteVersion: "1.3.0")
        await second.checkIfNeeded(now: Self.day(2))
        #expect(second.pendingRelease == nil)
        #expect(log.count == 2)

        // 又出了新版本，照常弹
        let third = Self.makeNotice(defaults: defaults, log: log, remoteVersion: "1.4.0")
        await third.checkIfNeeded(now: Self.day(4))
        #expect(third.pendingRelease?.version == "1.4.0")
    }

    @Test("App Store 上的版本不比本机新时不弹")
    func ignoresSameOrOlderVersion() async throws {
        let defaults = try Self.isolatedDefaults()
        let notice = Self.makeNotice(defaults: defaults, log: RequestLog(), remoteVersion: "1.2.0")
        await notice.checkIfNeeded(now: Self.day(0))
        #expect(notice.pendingRelease == nil)
    }

    @Test("一天内只查一次；同一次启动也只查一次")
    func throttlesChecks() async throws {
        let defaults = try Self.isolatedDefaults()
        let log = RequestLog()
        let notice = Self.makeNotice(defaults: defaults, log: log, remoteVersion: "1.2.0")
        await notice.checkIfNeeded(now: Self.day(0))
        await notice.checkIfNeeded(now: Self.day(3))
        #expect(log.count == 1)

        let nextLaunch = Self.makeNotice(defaults: defaults, log: log, remoteVersion: "1.3.0")
        await nextLaunch.checkIfNeeded(now: Self.day(0).addingTimeInterval(60 * 60))
        #expect(log.count == 1)
        #expect(nextLaunch.pendingRelease == nil)
    }

    @Test("查询失败不记查询时间，下次启动再试")
    func retriesAfterFailure() async throws {
        let defaults = try Self.isolatedDefaults()
        let log = RequestLog()
        let failing = AppUpdateNotice(
            defaults: defaults,
            currentVersion: "1.2.0",
            bundleID: "top.yado1225.yadoA",
            countryCodes: ["cn"],
            fetch: { url in
                log.record(url)
                throw URLError(.notConnectedToInternet)
            },
            upgradePrompt: AppUpdatePrompt()
        )
        await failing.checkIfNeeded(now: Self.day(0))
        #expect(defaults.object(forKey: AppUpdateNotice.lastCheckedKey) == nil)

        let retry = Self.makeNotice(defaults: defaults, log: log, remoteVersion: "1.3.0")
        await retry.checkIfNeeded(now: Self.day(0).addingTimeInterval(60))
        #expect(log.count == 2)
        #expect(retry.pendingRelease?.version == "1.3.0")
    }

    @Test("本次启动已经弹过 426 提示时不再叠一个新版本弹层")
    func skipsWhenUpgradeRequiredAlreadyPrompted() async throws {
        let defaults = try Self.isolatedDefaults()
        let upgradePrompt = AppUpdatePrompt()
        upgradePrompt.present()
        let notice = Self.makeNotice(
            defaults: defaults,
            log: RequestLog(),
            remoteVersion: "1.3.0",
            upgradePrompt: upgradePrompt
        )
        await notice.checkIfNeeded(now: Self.day(0))
        #expect(notice.pendingRelease == nil)
    }

    @Test("第一个店面查不到时查下一个")
    func fallsBackToNextStorefront() async throws {
        let defaults = try Self.isolatedDefaults()
        let log = RequestLog()
        let notice = AppUpdateNotice(
            defaults: defaults,
            currentVersion: "1.2.0",
            bundleID: "top.yado1225.yadoA",
            countryCodes: ["us", "cn"],
            fetch: { url in
                log.record(url)
                return url.absoluteString.contains("country=cn")
                    ? Self.lookupJSON(version: "1.3.0", notes: nil)
                    : Data(#"{"resultCount":0,"results":[]}"#.utf8)
            },
            upgradePrompt: AppUpdatePrompt()
        )
        await notice.checkIfNeeded(now: Self.day(0))
        #expect(log.count == 2)
        #expect(notice.pendingRelease?.version == "1.3.0")
    }

    // MARK: - 「我的」页的「新版本可用」

    @Test("有更新的版本时「我的」页一直显示，弹层弹过、下次启动不查也照样显示")
    func keepsAvailableReleaseUntilUpdated() async throws {
        let defaults = try Self.isolatedDefaults()
        let log = RequestLog()
        let first = Self.makeNotice(defaults: defaults, log: log, remoteVersion: "1.3.0")
        #expect(first.availableRelease == nil)
        await first.checkIfNeeded(now: Self.day(0))
        #expect(first.availableRelease?.version == "1.3.0")
        let release = try #require(first.pendingRelease)
        first.presentPending()
        first.markNotified(release)

        // 下次启动不到一天，不查也能从上次的结果显示
        let nextLaunch = Self.makeNotice(defaults: defaults, log: log, remoteVersion: "1.3.0")
        await nextLaunch.checkIfNeeded(now: Self.day(0).addingTimeInterval(60 * 60))
        #expect(log.count == 1)
        #expect(nextLaunch.pendingRelease == nil)
        #expect(nextLaunch.availableRelease?.version == "1.3.0")
        #expect(nextLaunch.availableRelease?.storeURL == release.storeURL)

        // 过了一天再查，弹过的版本不再弹，但这一行还在
        let later = Self.makeNotice(defaults: defaults, log: log, remoteVersion: "1.3.0")
        await later.checkIfNeeded(now: Self.day(2))
        #expect(later.pendingRelease == nil)
        #expect(later.availableRelease?.version == "1.3.0")
    }

    @Test("本机更新到 App Store 上的版本后不再显示「新版本可用」")
    func hidesAvailableReleaseAfterUpdating() async throws {
        let defaults = try Self.isolatedDefaults()
        let notice = Self.makeNotice(defaults: defaults, log: RequestLog(), remoteVersion: "1.3.0")
        await notice.checkIfNeeded(now: Self.day(0))
        #expect(notice.availableRelease != nil)

        let updated = AppUpdateNotice(
            defaults: defaults,
            currentVersion: "1.3.0",
            bundleID: "top.yado1225.yadoA",
            countryCodes: ["cn"],
            fetch: { _ in Self.lookupJSON(version: "1.3.0", notes: nil) },
            upgradePrompt: AppUpdatePrompt()
        )
        #expect(updated.availableRelease == nil)
    }

    @Test("426 提示弹过时不叠弹层，但「我的」页照样显示「新版本可用」")
    func showsAvailableReleaseEvenWhenUpgradePrompted() async throws {
        let defaults = try Self.isolatedDefaults()
        let upgradePrompt = AppUpdatePrompt()
        upgradePrompt.present()
        let notice = Self.makeNotice(
            defaults: defaults,
            log: RequestLog(),
            remoteVersion: "1.3.0",
            upgradePrompt: upgradePrompt
        )
        await notice.checkIfNeeded(now: Self.day(0))
        #expect(notice.pendingRelease == nil)
        #expect(notice.availableRelease?.version == "1.3.0")
    }

    @Test("App Store 上查不到本 App 时清掉之前的「新版本可用」")
    func clearsAvailableReleaseWhenNotFound() async throws {
        let defaults = try Self.isolatedDefaults()
        let first = Self.makeNotice(defaults: defaults, log: RequestLog(), remoteVersion: "1.3.0")
        await first.checkIfNeeded(now: Self.day(0))
        #expect(first.availableRelease != nil)

        let missing = AppUpdateNotice(
            defaults: defaults,
            currentVersion: "1.2.0",
            bundleID: "top.yado1225.yadoA",
            countryCodes: ["cn"],
            fetch: { _ in Data(#"{"resultCount":0,"results":[]}"#.utf8) },
            upgradePrompt: AppUpdatePrompt()
        )
        #expect(missing.availableRelease != nil)
        await missing.checkIfNeeded(now: Self.day(2))
        #expect(missing.availableRelease == nil)
        #expect(defaults.string(forKey: AppUpdateNotice.latestVersionKey) == nil)
    }

    // MARK: - 辅助

    /// 本机版本固定为 1.2.0、只查中国大陆店面的提示状态，查询返回指定版本。
    private static func makeNotice(
        defaults: UserDefaults,
        log: RequestLog,
        remoteVersion: String,
        upgradePrompt: AppUpdatePrompt? = nil
    ) -> AppUpdateNotice {
        AppUpdateNotice(
            defaults: defaults,
            currentVersion: "1.2.0",
            bundleID: "top.yado1225.yadoA",
            countryCodes: ["cn"],
            fetch: { url in
                log.record(url)
                return lookupJSON(version: remoteVersion, notes: "修复问题")
            },
            // 不碰 shared：别的测试会让 shared 弹过 426
            upgradePrompt: upgradePrompt ?? AppUpdatePrompt()
        )
    }

    /// 一份查询结果 JSON。
    nonisolated private static func lookupJSON(version: String, notes: String?) -> Data {
        var result: [String: Any] = [
            "version": version,
            "trackViewUrl": "https://apps.apple.com/cn/app/id1234567890",
            "trackId": 1_234_567_890,
        ]
        if let notes {
            result["releaseNotes"] = notes
        }
        let payload: [String: Any] = ["resultCount": 1, "results": [result]]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// 基准时间往后第几天。
    private static func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(TimeInterval(offset) * 24 * 60 * 60)
    }

    /// 每个用例独立的 UserDefaults。
    private static func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "AppUpdateNoticeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

/// 记下假请求发了几次；查询闭包要求 Sendable，用锁保护。
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    /// 已经发出的请求数。
    var count: Int {
        lock.withLock { urls.count }
    }

    /// 记一次请求。
    func record(_ url: URL) {
        lock.withLock { urls.append(url) }
    }
}
