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
                // 팁 상품을 불러오고 끝나지 않은 팁을 마저 센다 (무료 앱이라 LeeoStore 대신 혼자)
                .task { await StampCameraSpec.tipJar.startStandalone() }
        }
    }
}
