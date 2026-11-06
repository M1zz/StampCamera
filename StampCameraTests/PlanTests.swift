//
//  PlanTests.swift
//  StampCameraTests
//
//  세 칸(무료 · Plus · Pro)의 상품과 무료 한도.
//

import Testing
@testable import StampCamera

struct PlanTests {

    @Test func 상품마다_여는_칸() {
        #expect(PlanProducts.tier(owning: []) == .free)
        for term in PlanTerm.allCases {
            #expect(PlanProducts.tier(owning: [PlanProducts.id(.plus, term)]) == .plus)
            #expect(PlanProducts.tier(owning: [PlanProducts.id(.pro, term)]) == .pro)
        }
        #expect(PlanProducts.tier(owning: [PlanProducts.upgrade]) == .pro)
        #expect(PlanProducts.tier(owning: [PlanProducts.graduate]) == .pro)
        // 두 칸을 다 가졌으면 높은 쪽
        #expect(PlanProducts.tier(owning: [PlanProducts.id(.plus, .lifetime), PlanProducts.id(.pro, .monthly)]) == .pro)
    }

    @Test func 팁은_아무것도_열지_않는다() {
        #expect(PlanProducts.tier(owning: Set(PlanProducts.tips)) == .free)
        #expect(Set(PlanProducts.all).isDisjoint(with: PlanProducts.tips))
        #expect(StampCameraSpec.paywall?.entitlementIDs.isDisjoint(with: PlanProducts.tips) == true)
    }

    @Test func 상품_ID는_번들_ID_아래_겹치지_않게() {
        #expect(PlanProducts.all.count == 10)
        #expect(Set(PlanProducts.all).count == PlanProducts.all.count)
        #expect(PlanProducts.all.allSatisfy { $0.hasPrefix("com.devkoan.StampCamera.") })
        #expect(PlanProducts.id(.plus, .weekly) == "com.devkoan.StampCamera.plus.weekly")
        #expect(PlanProducts.id(.pro, .lifetime) == "com.devkoan.StampCamera.pro.lifetime")
    }

    @Test func 구독은_주_월_연_여섯() {
        #expect(PlanProducts.subscriptionIDs.count == 6)
        #expect(!PlanProducts.subscriptionIDs.contains(PlanProducts.id(.plus, .lifetime)))
        #expect(!PlanProducts.subscriptionIDs.contains(PlanProducts.graduate))
    }

    @Test func 무료_한도() {
        #expect(FreePlan.albumLimit == 5)
        #expect(FreePlan.papers.count == 3)
        #expect(FreePlan.papers.contains(.cream))   // 새 수집함의 기본 속지는 늘 무료
        #expect(FreePlan.inks == [.original, .sepia, .mono])
        #expect(PlanFeature.printSheet.tier == .pro)
        #expect(PlanFeature.albumImage.tier == .pro)
        #expect(PlanFeature.arrange.tier == .plus)
    }
}
