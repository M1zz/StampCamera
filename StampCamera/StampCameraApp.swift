//
//  StampCameraApp.swift
//  StampCamera
//

import SwiftUI
import TipKit
import LeeoKit

@main
struct StampCameraApp: App {
    @StateObject private var router = CameraLaunchRouter.shared

    init() {
        // TipKit: tips persist their shown/dismissed state in the default store,
        // so each tip appears once and stays gone after the user reads/dismisses it.
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
        LeeoEngagement.shared.registerLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .leeoSatisfactionCheck(StampCameraSpec.self)
                .environmentObject(router)
                // Control Center / Lock Screen control & the kkuk://camera deep
                // link both land here → route straight to the live camera.
                .onOpenURL { router.handle(url: $0) }
        }
    }
}
