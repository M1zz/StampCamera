//
//  StampCameraApp.swift
//  StampCamera
//

import SwiftUI
import LeeoKit

@main
struct StampCameraApp: App {
    @StateObject private var router = CameraLaunchRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 실행 기록 + 익명 사용 통계·크래시 진단(FeedbackHub)을 한 번에 켠다.
        LeeoKit.bootstrap(StampCameraSpec.self)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 창 크기로 접힘을 재서 아래로 흘린다. 시트 · 알림창도 접힌 선을 비킨다 (LeeoKit Fold).
                .foldAware()
                .preferredColorScheme(.dark)
                .leeoSatisfactionCheck(StampCameraSpec.self)
                .environmentObject(router)
                // Control Center / Lock Screen control & the kkuk://camera deep
                // link both land here → route straight to the live camera.
                .onOpenURL { router.handle(url: $0) }
                // 영수증을 읽고 요금제를 불러온다 (팁 상품도 같은 스토어가 불러온다)
                .task { await PunchingPlans.shared.refresh() }
                // 모은 스티커를 Siri · Spotlight 가 찾게 — 열 때와 뒤로 보낼 때 다시 싣는다
                .onChange(of: scenePhase) { _, phase in
                    if phase != .inactive { Task { await StampLibrary.reindex() } }
                    if phase == .active { Task { await PunchingPlans.shared.refresh() } }
                }
        }
    }
}
