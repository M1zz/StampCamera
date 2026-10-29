//
//  StampCameraSpec.swift
//  StampCamera
//
//  LeeoKit 계약(LeeoAppSpec) 준수 — 이 앱의 공통 기능 설정값 단일 소스.
//

import Foundation
import LeeoKit

enum StampCameraSpec: LeeoAppSpec {
    static let appName = "펀칭"
    static let developerEmail = "leeo@kakao.com"
    /// 친구에게 소개하기·리뷰 남기기 링크에 쓴다.
    static let appStoreID: String? = "6779659029"

    /// 공용 피드백 허브(FeedbackHub)로 수집 — appIdentifier로 앱을 구분한다.
    /// StampCamera.entitlements에 iCloud.com.Ysoup.FeedbackHub 컨테이너가 있어야 한다.
    static let feedback = LeeoFeedbackConfig(
        containerIdentifier: "iCloud.com.Ysoup.FeedbackHub",
        appIdentifier: "com.devkoan.StampCamera"
    )

    /// 개인정보 처리방침·지원 페이지 (README에 공개된 링크와 동일).
    static let legal = LeeoLegalConfig(
        privacyURL: URL(string: "https://m1zz.github.io/StampCamera/privacy.html")!,
        supportURL: URL(string: "https://m1zz.github.io/StampCamera/support.html")!
    )

    /// 결제 없음 — 앱 안에 StoreKit·페이월 코드가 존재하지 않는다.
    static let monetization = LeeoMonetization.free

    /// 익명 사용 통계 → FeedbackHub. 없으면 bootstrap 이 스냅샷·app_open 을 건너뛴다.
    static let analytics: any LeeoAnalytics = LeeoUsageAnalytics(spec: StampCameraSpec.self)
}

extension StampCameraSpec {
    /// 무료 앱이라 LeeoStore 가 없다 — 팁만 혼자 받는다(앱을 열 때 `startStandalone()`, → StampCameraApp).
    /// 소모성 상품 셋, 작은 것부터. ⚠️ 기능을 여는 상품이 아니다.
    @MainActor static let tipJar = LeeoTipJar(config: LeeoTipJarConfig(productIDs: [
        "com.devkoan.StampCamera.tip.small",
        "com.devkoan.StampCamera.tip.medium",
        "com.devkoan.StampCamera.tip.large",
    ]))
}

/// 팁을 부탁할 만한 순간 — 지금까지 뜯어 모은 스티커 수. 한 번 뜯을 때마다 하나씩 는다.
enum StampCameraTipMoments {
    /// 모은 스티커 수. 큰 것부터.
    static let punched = [100, 30, 10]

    /// 넘어선 순간, 인상적인 것부터.
    static func reached(punchedCount count: Int) -> [LeeoTipMoment] {
        punched.filter { count >= $0 }.map { threshold in
            LeeoTipMoment(id: "stamps.\(threshold)",
                          message: String(localized: "지금까지 스티커 \(count)장을 뜯어 모았어요",
                                          comment: "Tip ask card: how many stickers the person has punched and collected"))
        }
    }
}
