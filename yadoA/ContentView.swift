//
//  ContentView.swift
//  yadoA
//
//  Created by webull_yado on 2026/8/12.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var screenshotRouter = ScreenshotBookkeepingRouter.shared

    var body: some View {
        AppTabView()
            .background {
                ScreenshotBookkeepingPresenter(
                    request: screenshotRouter.request,
                    container: modelContext.container,
                    onFinish: { screenshotRouter.request = nil }
                )
                .frame(width: 0, height: 0)
            }
    }
}
