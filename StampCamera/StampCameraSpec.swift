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
}
