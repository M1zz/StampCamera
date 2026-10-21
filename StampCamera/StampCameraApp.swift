//
//  StampCameraApp.swift
//  StampCamera
//

import SwiftUI
import LeeoKit

@main
struct StampCameraApp: App {
    @StateObject private var router = CameraLaunchRouter.shared

    init() {
        // 실행 기록 + 익명 사용 통계·크래시 진단(FeedbackHub)을 한 번에 켠다.
        LeeoKit.bootstrap(StampCameraSpec.self)
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
