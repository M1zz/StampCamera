//
//  StampCameraApp.swift
//  StampCamera
//

import SwiftUI
import TipKit

@main
struct StampCameraApp: App {
    init() {
        // TipKit: tips persist their shown/dismissed state in the default store,
        // so each tip appears once and stays gone after the user reads/dismisses it.
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
