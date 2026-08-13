//
//  yadoAApp.swift
//  yadoA
//
//  Created by webull_yado on 2026/8/12.
//

import SwiftData
import SwiftUI

@main
struct yadoAApp: App {
    /// 仅由 UI 自动化参数显式启用的隔离内存容器；生产启动不会创建它。
    private let uiTestingDataContainer: AccountDataContainer?

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-in-memory") {
            do {
                let container = try AccountDataContainer.inMemory()
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-home-fixture") {
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing-reset-home-summary-visibility") {
                        UserDefaults.standard.set(false, forKey: "home.summary.amountsVisible")
                    }
                    try HomeUITestFixture.seed(in: container.modelContainer)
                }
                uiTestingDataContainer = container
            } catch {
                // UI 自动化绝不能因隔离容器失败而转入生产文件存储。
                fatalError("Unable to create isolated UI testing store: \(error)")
            }
        } else {
            uiTestingDataContainer = nil
        }
        #else
        // Release 构建始终使用生产文件存储，忽略任何自动化启动参数。
        uiTestingDataContainer = nil
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if let uiTestingDataContainer {
                ContentView()
                    .modelContainer(uiTestingDataContainer.modelContainer)
            } else {
                LocalDataBootstrapView {
                    ContentView()
                }
            }
        }
    }
}
