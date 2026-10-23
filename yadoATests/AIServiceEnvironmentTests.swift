import Foundation
import Testing
@testable import yadoA

/// 验证本地开发配置：AI 服务本地地址校验，以及 Scheme 启动环境变量写入 AI 服务、开发入口和同步服务地址的设置。
@Suite("AI 服务环境")
@MainActor
struct AIServiceEnvironmentTests {
    @Test("本地地址只接受带主机名的 http / https 地址")
    func validatesLocalEndpoint() {
        #expect(AIServiceEnvironment.localEndpoint(from: " http://my-mac.local:7790 ")?.absoluteString == "http://my-mac.local:7790")
        #expect(AIServiceEnvironment.localEndpoint(from: "https://10.0.0.2:7790") != nil)
        #expect(AIServiceEnvironment.localEndpoint(from: "my-mac.local:7790") == nil)
        #expect(AIServiceEnvironment.localEndpoint(from: "ftp://my-mac.local") == nil)
        #expect(AIServiceEnvironment.localEndpoint(from: "") == nil)
    }

    @Test("Scheme 环境变量写入设置；没有变量时保持原样，非法取值忽略")
    func appliesLaunchEnvironment() throws {
        let suiteName = "AIServiceEnvironmentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AIServiceEnvironment.applyLaunchEnvironment([
            AIServiceEnvironment.launchEnvironmentKey: "local",
            AIServiceEnvironment.launchLocalEndpointKey: "http://my-mac.local:7790",
        ], defaults: defaults)
        #expect(defaults.string(forKey: AIServiceEnvironment.storageKey) == "local")
        #expect(defaults.string(forKey: AIServiceEnvironment.localEndpointStorageKey) == "http://my-mac.local:7790")

        // 从桌面打开时没有环境变量，保持上次的选择
        AIServiceEnvironment.applyLaunchEnvironment([:], defaults: defaults)
        #expect(defaults.string(forKey: AIServiceEnvironment.storageKey) == "local")

        AIServiceEnvironment.applyLaunchEnvironment([
            AIServiceEnvironment.launchEnvironmentKey: "staging",
            AIServiceEnvironment.launchLocalEndpointKey: "not a url",
        ], defaults: defaults)
        #expect(defaults.string(forKey: AIServiceEnvironment.storageKey) == "local")
        #expect(defaults.string(forKey: AIServiceEnvironment.localEndpointStorageKey) == "http://my-mac.local:7790")

        AIServiceEnvironment.applyLaunchEnvironment([AIServiceEnvironment.launchEnvironmentKey: "production"], defaults: defaults)
        #expect(defaults.string(forKey: AIServiceEnvironment.storageKey) == "production")
    }

    @Test("开发入口开关：yadoA-local 写入 1、yadoA 写入 0，没有变量或非法取值时保持原样")
    func appliesDeveloperToolsLaunchEnvironment() throws {
        let suiteName = "DeveloperToolsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DeveloperTools.applyLaunchEnvironment([DeveloperTools.launchEnvironmentKey: "1"], defaults: defaults)
        #expect(defaults.bool(forKey: DeveloperTools.storageKey))

        DeveloperTools.applyLaunchEnvironment([:], defaults: defaults)
        DeveloperTools.applyLaunchEnvironment([DeveloperTools.launchEnvironmentKey: "yes"], defaults: defaults)
        #expect(defaults.bool(forKey: DeveloperTools.storageKey))

        DeveloperTools.applyLaunchEnvironment([DeveloperTools.launchEnvironmentKey: "0"], defaults: defaults)
        #expect(!defaults.bool(forKey: DeveloperTools.storageKey))
    }

    @Test("同步服务本地地址：合法地址写入设置，没有变量或地址不合法时保持原样")
    func appliesSyncServiceLaunchEnvironment() throws {
        let suiteName = "SyncServiceEnvironmentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SyncServiceEnvironment.launchLocalEndpointKey

        SyncServiceEnvironment.applyLaunchEnvironment([key: "http://my-mac.local:7789"], defaults: defaults)
        #expect(defaults.string(forKey: SyncServiceEnvironment.localEndpointStorageKey) == "http://my-mac.local:7789")

        SyncServiceEnvironment.applyLaunchEnvironment([:], defaults: defaults)
        SyncServiceEnvironment.applyLaunchEnvironment([key: "not a url"], defaults: defaults)
        #expect(defaults.string(forKey: SyncServiceEnvironment.localEndpointStorageKey) == "http://my-mac.local:7789")
    }
}
