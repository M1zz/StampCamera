//
//  SubscriptionLegalLinks.swift
//  StampCamera
//
//  이용약관(EULA) · 개인정보 처리방침 링크. **구독을 사는 화면마다 반드시 선다.**
//
//  심사 지침 3.1.2(c): 자동 갱신 구독을 파는 앱은 앱 안에 두 링크가 눌리는 채로 있어야 한다.
//  1.0.5 (13) 는 링크가 페이월 맨 아래(비교표 · 두 칸 · 고지문을 지나 스크롤해야 보이는 자리)에만 있고
//  설정에는 없어서 반려됐다. 그래서
//    · 페이월과 평생 전환 판에는 스크롤과 상관없이 바닥에 붙여 두고 (`.subscriptionLegalBar()`)
//    · 설정의 요금제 구역에도 줄로 둔다 (`SubscriptionLegalLinks(style: .rows)`).
//
//  ⚠️ 살 수 있는 화면을 새로 만들면 이 뷰를 함께 넣는다. `scripts/predeploy.sh` 가 빠진 화면을 잡는다.
//

import SwiftUI
import LeeoKit

/// 구독 약관 주소의 단일 소스. 화면 · 테스트 · 배포 전 검사가 모두 여기를 본다.
enum SubscriptionLegal {
    /// 애플 표준 사용권 계약(EULA). 자체 약관이 없는 앱이 거는 주소.
    static let standardEULA = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// 계약(`StampCameraSpec.monetization`)에 적힌 약관. 계약이 바뀌어도 링크가 사라지지 않게 표준 EULA 로 받친다.
    static var termsURL: URL { StampCameraSpec.monetization.subscriptionTermsURL ?? standardEULA }

    static var privacyURL: URL { StampCameraSpec.legal.privacyURL }
}

struct SubscriptionLegalLinks: View {
    enum Style {
        /// 화면 바닥에 붙는 한 줄 (페이월 · 평생 전환 판)
        case bar
        /// 목록 안의 줄 (설정)
        case rows
    }

    var style: Style = .bar
    var tint: Color?

    var body: some View {
        switch style {
        case .bar:
            // 좁은 화면 · 큰 글자에서는 두 줄로 내려 쌓는다. 글자가 잘려 링크가 안 보이는 일이 없게.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { terms; privacy }
                VStack(spacing: 8) { terms; privacy }
            }
            .font(.body)
            .tint(tint)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        case .rows:
            Link(destination: SubscriptionLegal.termsURL) {
                Label("이용약관(EULA)", systemImage: "doc.text")
            }
            Link(destination: SubscriptionLegal.privacyURL) {
                Label("개인정보 처리방침", systemImage: "hand.raised")
            }
        }
    }

    private var terms: some View {
        Link(destination: SubscriptionLegal.termsURL) {
            Text("이용약관(EULA)").underline().frame(minHeight: 44)
        }
    }

    private var privacy: some View {
        Link(destination: SubscriptionLegal.privacyURL) {
            Text("개인정보 처리방침").underline().frame(minHeight: 44)
        }
    }
}

extension View {
    /// 살 수 있는 화면의 바닥에 약관 · 개인정보 링크를 붙인다. 스크롤하지 않아도 늘 보인다.
    func subscriptionLegalBar(tint: Color? = nil) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            SubscriptionLegalLinks(style: .bar, tint: tint)
        }
    }
}
