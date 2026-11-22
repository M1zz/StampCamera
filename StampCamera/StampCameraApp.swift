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
                // 개발자가 보낸 의견에 답장하면, 앱이 앞으로 올 때 답장을 시트로 보여 준다 (LeeoKit).
                .leeoFeedbackReplyNotice(StampCameraSpec.self)
                // 유료가 되면 콘페티, 모든 사용자가 한 번은 감사 인사를 받는다 (LeeoKit).
                .celebrationsUnlessScreenshot()
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

private extension View {
    /// 축하 · 감사 (LeeoKit). 스토어 스크린샷을 찍을 때는 띄우지 않는다.
    @ViewBuilder func celebrationsUnlessScreenshot() -> some View {
        #if DEBUG
        if ScreenshotScene.isActive { self } else { leeoCelebrations(appName: StampCameraSpec.displayName) }
        #else
        leeoCelebrations(appName: StampCameraSpec.displayName)
        #endif
    }
}
