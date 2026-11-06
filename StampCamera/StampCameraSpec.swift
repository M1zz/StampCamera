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

    /// 무료 다운로드 + 무료 · Plus · Pro (칸마다 주 · 월 · 연 구독과 평생). 칸과 상품은 StampCameraPlans.swift.
    static let monetization = LeeoMonetization.freemiumSubscription(
        LeeoSubscriptionConfig(
            productIDs: PlanProducts.all,
            // 자체 약관이 없으므로 애플 표준 사용권 계약(EULA)을 건다. 구독을 파는 앱의 심사 필수 항목이다.
            termsURL: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!,
            entitlementIDs: Set(PlanProducts.tierByProduct.keys),
            gate: LeeoGatePolicy(
                freeLimits: [PlanFeature.albums.rawValue: FreePlan.albumLimit,
                             PlanFeature.papers.rawValue: FreePlan.papers.count,
                             PlanFeature.inks.rawValue: FreePlan.inks.count],
                proOnly: [PlanFeature.arrange.rawValue, PlanFeature.printSheet.rawValue,
                          PlanFeature.albumImage.rawValue]),
            // 팁은 같은 스토어가 들고 있어야 결제 리스너 하나로 센다. ⚠️ 기능을 여는 상품이 아니다.
            tipJar: LeeoTipJarConfig(productIDs: PlanProducts.tips)
        )
    )

    /// 백업 금고가 함께 떠 두는 공유 저장소 (위젯과 나누는 것).
    static let appGroups = ["group.com.devkoan.StampCamera"]

    /// 익명 사용 통계 → FeedbackHub. 없으면 bootstrap 이 스냅샷·app_open 을 건너뛴다.
    static let analytics: any LeeoAnalytics = LeeoUsageAnalytics(spec: StampCameraSpec.self)
}

extension StampCameraSpec {
    /// 개발자 응원 팁 — 페이월과 같은 `LeeoStore` 가 들고 있다(→ StampCameraPlans.swift).
    @MainActor static var tipJar: LeeoTipJar {
        guard let jar = PunchingPlans.shared.store.tipJar else { preconditionFailure("계약에 팁이 없다") }
        return jar
    }
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
