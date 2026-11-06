//
//  StampCameraPlans.swift
//  StampCamera
//
//  펀칭의 세 칸 — 무료 · Plus · Pro. **무엇이 어느 칸인지와, 지금 어느 칸인지를 아는 한 곳.**
//
//   · 무료: 뜯기 · 담기 · 메시지와 키보드로 보내기 · 복사와 공유는 끝없이. 수집함 5권, 속지 3종, 색감 3종.
//   · Plus: 수집함 무제한, 속지 10종, 색감 6종, 스티커 순서 바꾸기(자유롭게 꾸미기).
//   · Pro:  Plus 전부 + 인쇄용 스티커 시트(PDF), 수집함을 이미지 한 장으로 공유.
//
//  ⚠️ 잠그는 것은 **새로 고르고 만드는 순간**뿐이다. 이미 만든 수집함(다섯 권이 넘어도) · 이미 입힌 속지와
//     색감 · 이미 정한 순서는 그대로 보이고, 지울 수 있다. 메시지 · 키보드의 스티커 묶음도 전부 그대로다.
//     그래서 페이월 전에 쓰던 사람에게서 뺏는 것이 없다 — 따로 설치일을 볼 일이 없다.
//  ⚠️ 상품 로드 · 구매 · 복원 · 거래 리스너(다른 기기 · 가족 공유 · 환불 · 만료)는 전부 `LeeoStore` 안에 있다.
//  ⚠️ 팁은 권한이 아니다. 같은 스토어가 들고 있지만(리스너 하나로 팁 결제를 세게) 아무것도 열지 않는다.
//

import Foundation
import Combine
import StoreKit
import SwiftUI
import LeeoKit

/// 칸. 값이 클수록 더 많이 연다. Pro 는 Plus 를 전부 포함한다.
enum PlanTier: Int, Comparable, CaseIterable {
    case free, plus, pro

    static func < (a: PlanTier, b: PlanTier) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .free: String(localized: "무료")
        case .plus: String(localized: "펀칭 Plus")
        case .pro:  String(localized: "펀칭 Pro")
        }
    }
}

/// 값을 받고 여는 것들.
enum PlanFeature: String, Identifiable {
    /// 여섯 번째 수집함부터.
    case albums
    /// 무료 셋 밖의 속지.
    case papers
    /// 무료 셋 밖의 색감.
    case inks
    /// 스티커 순서 바꾸기 (자유롭게 꾸미기).
    case arrange
    /// 인쇄용 스티커 시트 (PDF, 칼선 포함).
    case printSheet
    /// 수집함 한 권을 이미지 한 장으로 공유.
    case albumImage

    var id: String { rawValue }

    /// 이 기능을 여는 가장 낮은 칸.
    var tier: PlanTier {
        switch self {
        case .albums, .papers, .inks, .arrange: .plus
        case .printSheet, .albumImage:          .pro
        }
    }
}

/// 무료 칸의 한도. 계약(`StampCameraSpec.monetization`)과 잠금 판정이 함께 읽는다.
enum FreePlan {
    static let albumLimit = 5
    static let papers: Set<BackgroundStyle> = [.cream, .grid, .ruled]
    static let inks: Set<StampInk> = [.original, .sepia, .mono]
}

/// 유료 칸을 사는 네 가지 길. 페이월은 연을 먼저 고르고, 주 · 월은 펼쳐야 보인다.
enum PlanTerm: CaseIterable {
    case weekly, monthly, yearly, lifetime
}

// MARK: - 상품

/// ⚠️ App Store Connect · `Products.storekit` 과 **글자 하나까지 같아야 한다.**
///    주 · 월 · 연 구독 여섯은 한 구독 그룹("펀칭")에 넣고 Pro 를 위 단계로 둔다(갈아탈 때 App Store 가 정산한다).
enum PlanProducts {
    private static let prefix = "com.devkoan.StampCamera"

    static func id(_ tier: PlanTier, _ term: PlanTerm) -> String {
        let name = tier == .pro ? "pro" : "plus"
        switch term {
        case .weekly:   return "\(prefix).\(name).weekly"
        case .monthly:  return "\(prefix).\(name).monthly"
        case .yearly:   return "\(prefix).\(name).yearly"
        case .lifetime: return "\(prefix).\(name).lifetime"
        }
    }

    /// Plus 평생을 산 사람이 Pro 평생으로 올리는 값.
    static let upgrade = "\(prefix).pro.upgrade"
    /// 구독 중인 사람의 졸업가 Pro 평생 (→ LeeoGraduation).
    static let graduate = "\(prefix).pro.graduate"

    /// 개발자 응원 팁 (소모성 셋, 작은 것부터). 아무것도 열지 않는다.
    /// ⚠️ `all` · `tierByProduct` 에 넣지 않는다 — 넣으면 팁을 낸 사람이 Plus 가 된다.
    static let tips = ["\(prefix).tip.small", "\(prefix).tip.medium", "\(prefix).tip.large"]

    private static let paid: [PlanTier] = [.plus, .pro]

    /// 상품마다 여는 칸.
    static let tierByProduct: [String: PlanTier] = {
        var map: [String: PlanTier] = [upgrade: .pro, graduate: .pro]
        for tier in paid { for term in PlanTerm.allCases { map[id(tier, term)] = tier } }
        return map
    }()

    /// 페이월이 불러올 상품 (화면 차례).
    static let all: [String] = paid.flatMap { tier in PlanTerm.allCases.map { id(tier, $0) } } + [upgrade, graduate]

    /// 자동 갱신 구독 (구독 졸업을 제안할 대상).
    static let subscriptionIDs: Set<String> = Set(paid.flatMap { tier in
        [PlanTerm.weekly, .monthly, .yearly].map { id(tier, $0) }
    })

    /// 가진 상품들이 여는 칸. 가장 높은 것.
    static func tier(owning ids: Set<String>) -> PlanTier {
        ids.compactMap { tierByProduct[$0] }.max() ?? .free
    }
}

// MARK: - 지금 어느 칸인가

@MainActor
final class PunchingPlans: ObservableObject {
    static let shared = PunchingPlans()

    let store: LeeoStore

    /// 지금 살아 있는 구독. 있으면 설정에 '평생으로 바꾸기' 가 선다.
    @Published private(set) var subscription: LeeoGraduation.Subscription?

    private var forward: AnyCancellable?

    /// 이 기기가 유료 칸 상품을 한 번이라도 불러왔는가.
    private static let onSaleKey = "plans.onSale"

    private init() {
        guard let config = StampCameraSpec.paywall else {
            preconditionFailure("계약에 페이월이 없다. StampCameraSpec.monetization 을 확인할 것")
        }
        store = LeeoStore(config: config)
        forward = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// 지금 쓰는 칸. 근거는 App Store 영수증뿐이다 (LeeoStore 가 마지막 답을 기억해 켤 때 깜빡이지 않는다).
    var tier: PlanTier {
        #if DEBUG
        if ScreenshotScene.isActive { return .pro }   // 스토어 스크린샷에 자물쇠가 찍히지 않게
        #endif
        return PlanProducts.tier(owning: store.purchasedProductIDs)
    }

    /// **팔기 시작했는가.** 유료 칸 상품을 하나도 못 불러온 기기는 한도로 막지 않는다.
    ///
    /// ⚠️ App Store Connect 에 상품이 서기 전에 빌드가 나가면, 살 수 없는데 막히는 사람이 생긴다.
    ///    한 번이라도 불러온 기기는 기억해 둔다 — 그 뒤로 잠깐 오프라인이어도 다시 한도가 선다.
    var isSelling: Bool { UserDefaults.standard.bool(forKey: Self.onSaleKey) }

    func allows(_ feature: PlanFeature) -> Bool { !isSelling || tier >= feature.tier }

    /// 수집함을 하나 더 만들어도 되는가. 이미 가진 권 수는 줄이지 않는다.
    func canCreateAlbum(having count: Int) -> Bool { count < FreePlan.albumLimit || allows(.albums) }

    func allows(_ paper: BackgroundStyle) -> Bool { FreePlan.papers.contains(paper) || allows(.papers) }

    func allows(_ ink: StampInk) -> Bool { FreePlan.inks.contains(ink) || allows(.inks) }

    func product(_ id: String) -> Product? { store.products.first { $0.id == id } }

    /// Plus 평생을 가졌는가. 그러면 Pro 평생 자리에 올리기 상품을 세운다.
    var ownsPlusLifetime: Bool { store.purchasedProductIDs.contains(PlanProducts.id(.plus, .lifetime)) }

    var isWorking: Bool { store.purchasingProductID != nil || store.isRestoring }

    // MARK: 상태 맞추기

    /// 영수증을 다시 읽고 상품을 불러온다. 앱이 켜질 때와 앞으로 나올 때마다.
    func refresh() async {
        await store.refreshEntitlements()
        await loadProducts()
        subscription = await LeeoGraduation.currentSubscription(among: PlanProducts.subscriptionIDs)
    }

    func loadProducts() async {
        await store.loadProducts()
        if !isSelling, store.products.contains(where: { PlanProducts.tierByProduct[$0.id] != nil }) {
            UserDefaults.standard.set(true, forKey: Self.onSaleKey)
            objectWillChange.send()
        }
    }

    /// ⚠️ `action` 은 페이월의 `@Environment(\.purchase)` 다. 아이패드에서 결제 시트가 엉뚱한 창에 뜨지 않게.
    func purchase(_ product: Product, using action: PurchaseAction) async {
        _ = await store.purchase(product) { try await action($0) }
        subscription = await LeeoGraduation.currentSubscription(among: PlanProducts.subscriptionIDs)
    }

    func restore() async {
        await store.restore()
        subscription = await LeeoGraduation.currentSubscription(among: PlanProducts.subscriptionIDs)
    }

    // MARK: 구독 졸업

    /// 구독 6개월째와 갱신 7일 전에 한 번씩. 띄운 쪽이 `markGraduationOffered()` 를 부른다.
    var graduationIsDue: Bool {
        guard let subscription, product(PlanProducts.graduate) != nil else { return false }
        return LeeoGraduation.isDue(subscription, lastOffered: LeeoGraduation.lastOffered())
    }

    func markGraduationOffered() { LeeoGraduation.markOffered() }
}
