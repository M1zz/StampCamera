//
//  StampCameraPaywallView.swift
//  StampCamera
//
//  펀칭 Plus · Pro 를 파는 한 장. 무엇이 무료인지부터 비교표로 말하고, 그다음 칸마다 값을 고른다.
//
//  **뜯는 순간은 막지 않는다.** 이 화면을 닫은 사람도 스티커를 계속 뜯고, 담고, 보낸다.
//  값을 받는 것은 모으는 재미가 붙은 뒤의 것(수집함 더, 속지와 색감, 순서)과 종이로 뽑는 것뿐이다.
//
//  상품은 불러온 것만 선다. App Store Connect 에 아직 없는 상품이 있어도 단추가 깨지지 않는다.
//

import SwiftUI
import StoreKit
import LeeoKit

struct PaywallView: View {
    /// 어디서 들어왔는가. 비교표에서 그 줄을, 그 기능이 든 칸을 강조한다.
    var highlight: PlanFeature?

    @ObservedObject private var plans = PunchingPlans.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.purchase) private var purchaseAction
    @Environment(\.dynamicTypeSize) private var typeSize

    /// 칸마다 고른 길. 처음엔 연 구독.
    @State private var plusTerm: PlanTerm = .yearly
    @State private var proTerm: PlanTerm = .yearly
    /// 주 · 월을 펼친 칸.
    @State private var shortTermsShown: Set<PlanTier> = []
    /// 처음 구독하는 사람인가 (첫 해 할인을 말할지).
    @State private var introEligible = false
    @State private var loading = true
    @State private var redeemingCode = false

    private let gold = Color(hex: 0xF2B23B)
    private let red = Color(hex: 0xE8504E)
    private let surface = Color.white.opacity(0.07)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    comparison
                    plansStatus
                    tierCard(.plus)
                    tierCard(.pro)
                    if let message = plans.store.lastError, !plans.store.products.isEmpty {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.body)
                            .foregroundStyle(.orange)
                    }
                    legal
                }
                .padding(20)
            }
            .background(Color(hex: 0x141210).ignoresSafeArea())
            .navigationTitle("요금제")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("나중에") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("복원") {
                        Task {
                            await plans.restore()
                            if let highlight, plans.tier >= highlight.tier { dismiss() }
                        }
                    }
                    .disabled(plans.isWorking)
                }
            }
            .offerCodeRedemption(isPresented: $redeemingCode) { _ in
                Task { await plans.refresh() }
            }
            .task {
                LeeoAnalyticsCenter.track(.paywallShown(reason: highlight?.rawValue ?? "settings"))
                await loadPlans()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 머리

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("펀칭 Plus · Pro")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("내 취향대로 꾸미고, 진짜 스티커로 뽑아 붙이세요. 연 구독이나 평생 중에 고르세요.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 비교표

    private enum Mark { case yes, no, text(String) }

    private struct Row: Identifiable {
        let title: String
        let marks: [Mark]   // 무료 · Plus · Pro
        var feature: PlanFeature?
        var id: String { title }
    }

    private var rows: [Row] {
        let albums = String(localized: "\(FreePlan.albumLimit)권")
        let unlimited = String(localized: "무제한")
        return [
            Row(title: String(localized: "스티커 뜯기 · 움직이는 스티커"), marks: [.yes, .yes, .yes]),
            Row(title: String(localized: "메시지 · 키보드에서 쓰기"), marks: [.yes, .yes, .yes]),
            Row(title: String(localized: "복사 · 보내기 (GIF · PNG)"), marks: [.yes, .yes, .yes]),
            Row(title: String(localized: "수집함"), marks: [.text(albums), .text(unlimited), .text(unlimited)],
                feature: .albums),
            Row(title: String(localized: "속지"),
                marks: [.text(kinds(FreePlan.papers.count)), .text(kinds(BackgroundStyle.allCases.count)),
                        .text(kinds(BackgroundStyle.allCases.count))],
                feature: .papers),
            Row(title: String(localized: "색감"),
                marks: [.text(kinds(FreePlan.inks.count)), .text(kinds(StampInk.allCases.count)),
                        .text(kinds(StampInk.allCases.count))],
                feature: .inks),
            Row(title: String(localized: "자유롭게 꾸미기"), marks: [.no, .yes, .yes], feature: .arrange),
            Row(title: String(localized: "인쇄용 스티커 시트 PDF"), marks: [.no, .no, .yes], feature: .printSheet),
            Row(title: String(localized: "수집함 이미지로 공유"), marks: [.no, .no, .yes], feature: .albumImage),
        ]
    }

    private func kinds(_ n: Int) -> String { String(localized: "\(n)종") }

    private var tierNames: [String] { [PlanTier.free.title, "Plus", "Pro"] }

    @ViewBuilder
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 0) {
            if typeSize.isAccessibilitySize {
                // 아주 큰 글자: 줄마다 기능 이름 아래에 세 칸을 적는다. 넷을 나란히 두면 글자가 잘린다.
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).font(.body.weight(.semibold))
                        ForEach(0..<3, id: \.self) { i in
                            HStack(spacing: 8) {
                                Text(tierNames[i]).foregroundStyle(.white.opacity(0.6))
                                markView(row.marks[i])
                            }
                            .font(.body)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(rowBackground(row))
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                    GridRow {
                        Color.clear.frame(width: 0, height: 0)
                        ForEach(0..<3, id: \.self) { i in
                            Text(tierNames[i])
                                .font(.body.weight(.semibold))
                                .foregroundStyle(i == 0 ? .white.opacity(0.7) : gold)
                                .gridColumnAlignment(.center)
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityHidden(true)
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.title)
                                .font(.body)
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(0..<3, id: \.self) { i in
                                markView(row.marks[i]).font(.body)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                        .background(rowBackground(row))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(rowAccessibilityLabel(row))
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(surface))
    }

    @ViewBuilder
    private func rowBackground(_ row: Row) -> some View {
        if let highlight, row.feature == highlight {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(gold.opacity(0.16))
        }
    }

    @ViewBuilder
    private func markView(_ mark: Mark) -> some View {
        switch mark {
        case .yes:
            Image(systemName: "checkmark")
                .fontWeight(.bold)
                .foregroundStyle(gold)
        case .no:
            Text(verbatim: "–").foregroundStyle(.white.opacity(0.35))
        case .text(let s):
            Text(s).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func markText(_ mark: Mark) -> String {
        switch mark {
        case .yes: String(localized: "포함")
        case .no: String(localized: "없음")
        case .text(let s): s
        }
    }

    /// "수집함, 무료 5권, Plus 무제한, Pro 무제한" 처럼 읽는다.
    private func rowAccessibilityLabel(_ row: Row) -> String {
        ([row.title] + (0..<3).map { "\(tierNames[$0]) \(markText(row.marks[$0]))" }).joined(separator: ", ")
    }

    // MARK: 유료 칸

    private func tierCard(_ tier: PlanTier) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let highlighted = highlight?.tier == tier && plans.tier < tier
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(tier.title)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                if plans.tier == tier {
                    Text("지금 쓰는 칸")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(gold)
                }
                Spacer(minLength: 0)
            }
            Text(tier == .plus ? String(localized: "수집함을 원하는 만큼, 속지와 색감은 내 취향대로.")
                               : String(localized: "모은 스티커를 진짜 스티커 용지로 뽑아 다이어리에 붙이세요."))
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            if plans.tier < tier, !terms(of: tier).isEmpty {
                termPicker(tier)
                buyButton(tier)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(surface)
            shape.strokeBorder(highlighted ? gold : .clear, lineWidth: 1.5)
        }
    }

    /// 이 칸의 그 길로 파는 상품. **Plus 평생을 가진 사람에게는 Pro 평생 자리에 올리기 상품을 세운다.**
    private func product(_ tier: PlanTier, _ term: PlanTerm) -> Product? {
        if tier == .pro, term == .lifetime, plans.ownsPlusLifetime {
            return plans.product(PlanProducts.upgrade)
        }
        return plans.product(PlanProducts.id(tier, term))
    }

    /// 불러온 상품이 있는 길만.
    private func terms(of tier: PlanTier) -> [PlanTerm] {
        PlanTerm.allCases.filter { product(tier, $0) != nil }
    }

    private func termBinding(_ tier: PlanTier) -> Binding<PlanTerm> {
        tier == .plus ? $plusTerm : $proTerm
    }

    /// 고른 길. 고른 상품이 아직 없으면 있는 것 가운데 하나.
    private func chosen(_ tier: PlanTier) -> PlanTerm? {
        let available = terms(of: tier)
        let picked = termBinding(tier).wrappedValue
        return available.contains(picked) ? picked : (available.first { $0 == .yearly } ?? available.first)
    }

    private func termPicker(_ tier: PlanTier) -> some View {
        let available = terms(of: tier)
        let long = available.filter { $0 == .yearly || $0 == .lifetime }
        let short = available.filter { $0 == .weekly || $0 == .monthly }
        let current = chosen(tier)
        let showsShort = shortTermsShown.contains(tier) || current == .weekly || current == .monthly
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8))
                                                  : AnyLayout(HStackLayout(spacing: 8))
        return VStack(alignment: .leading, spacing: 8) {
            if !long.isEmpty {
                layout { ForEach(long, id: \.self) { option(tier, $0, selected: current == $0) } }
            }
            if !short.isEmpty {
                if showsShort {
                    layout { ForEach(short, id: \.self) { option(tier, $0, selected: current == $0) } }
                } else {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { _ = shortTermsShown.insert(tier) }
                    } label: {
                        Label("주 · 월 구독 보기", systemImage: "chevron.down")
                            .font(.body)
                            .foregroundStyle(gold)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let current, let note = note(tier, current) {
                Text(note)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func option(_ tier: PlanTier, _ term: PlanTerm, selected: Bool) -> some View {
        let price = product(tier, term)?.displayPrice ?? ""
        let (title, priceLine): (String, String) = switch term {
        case .weekly:   (String(localized: "주 구독"), String(localized: "\(price) / 주"))
        case .monthly:  (String(localized: "월 구독"), String(localized: "\(price) / 월"))
        case .yearly:   (LeeoLadderText.yearly, String(format: LeeoLadderText.perYearFormat, price))
        case .lifetime: (LeeoLadderText.lifetime, price)
        }
        return Button {
            termBinding(tier).wrappedValue = term
        } label: {
            VStack(spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(priceLine).font(.body).monospacedDigit()
            }
            .foregroundStyle(selected ? gold : .white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? gold.opacity(0.14) : Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? gold : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 연: 처음이면 첫 해 할인. 평생: 연 구독 몇 년치인가.
    private func note(_ tier: PlanTier, _ term: PlanTerm) -> String? {
        switch term {
        case .yearly:
            guard introEligible, let offer = product(tier, .yearly)?.subscription?.introductoryOffer,
                  offer.paymentMode == .payUpFront || offer.paymentMode == .payAsYouGo else { return nil }
            return String(format: LeeoLadderText.introFormat, offer.displayPrice)
        case .lifetime:
            guard let yearly = product(tier, .yearly)?.price, yearly > 0,
                  let lifetime = product(tier, .lifetime)?.price, lifetime != yearly else { return nil }
            // ⚠️ 긴 몫에서 `NSDecimalNumber.intValue` 가 엉뚱한 값을 내므로 double 로 내린다.
            let years = Int(NSDecimalNumber(decimal: lifetime / yearly).doubleValue.rounded(.down))
            return years >= 2 ? String(format: LeeoLadderText.lifetimeWorthFormat, years) : nil
        case .weekly, .monthly:
            return nil
        }
    }

    private func buyButton(_ tier: PlanTier) -> some View {
        let term = chosen(tier)
        let product = term.flatMap { self.product(tier, $0) }
        let title: String = switch term {
        case .weekly:   String(localized: "주 구독 시작")
        case .monthly:  String(localized: "월 구독 시작")
        case .yearly:   String(localized: "연 구독 시작")
        case .lifetime where tier == .pro && plans.ownsPlusLifetime: String(localized: "Pro 평생으로 올리기")
        case .lifetime, nil: String(localized: "평생으로 사기")
        }
        return Button {
            guard let product else { return }
            Task {
                await plans.purchase(product, using: purchaseAction)
                if plans.tier >= tier { dismiss() }
            }
        } label: {
            Group {
                if plans.isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text(title).font(.body.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .tint(red)
        .controlSize(.large)
        .disabled(plans.isWorking || product == nil)
    }

    // MARK: 요금제를 못 불러왔을 때

    @ViewBuilder
    private var plansStatus: some View {
        if plans.store.products.isEmpty {
            if loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("값을 불러오는 중…").font(.body).foregroundStyle(.white.opacity(0.65))
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("요금제를 불러오지 못했어요. 인터넷 연결을 확인하고 다시 불러와 주세요.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await loadPlans() }
                    } label: {
                        Label("다시 불러오기", systemImage: "arrow.clockwise").font(.body.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(gold)
                }
            }
        }
    }

    /// 첫 조회가 비어 오면 한 번 더 청한다. 샌드박스(심사 환경)는 첫 조회가 빈손으로 오는 일이 잦다.
    private func loadPlans() async {
        loading = true
        await plans.loadProducts()
        if plans.store.products.isEmpty {
            try? await Task.sleep(for: .seconds(1.5))
            await plans.loadProducts()
        }
        let yearly = plans.product(PlanProducts.id(.plus, .yearly)) ?? plans.product(PlanProducts.id(.pro, .yearly))
        introEligible = await yearly?.subscription?.isEligibleForIntroOffer ?? false
        loading = false
    }

    // MARK: 약관 (구독을 파는 앱의 심사 필수 항목)

    private var legal: some View {
        VStack(alignment: .leading, spacing: 10) {
            if plans.store.products.contains(where: { $0.subscription != nil }) {
                Text("구독은 기간이 끝나기 24시간 전까지 해지하지 않으면 같은 요금으로 자동 갱신되며, Apple 계정으로 결제됩니다. 첫 구독 할인을 받으면 할인 기간이 끝난 뒤 정가로 갱신됩니다. 해지와 관리는 App Store 계정 설정에서 합니다. 평생은 구독이 아니라 한 번 결제입니다.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                if let terms = StampCameraSpec.monetization.subscriptionTermsURL {
                    Button("이용약관") { openURL(terms) }
                }
                Button("개인정보 처리방침") { openURL(StampCameraSpec.legal.privacyURL) }
            }
            .font(.body)
            .tint(gold)
            Button {
                redeemingCode = true
            } label: {
                Label("코드 사용", systemImage: "ticket")
            }
            .font(.body)
            .tint(gold)
            .disabled(plans.isWorking)
        }
    }
}

// MARK: - 잠긴 자리에서 부르는 길

extension View {
    /// `feature` 가 서면 그 기능의 페이월을 낸다.
    func paywall(_ feature: Binding<PlanFeature?>) -> some View {
        sheet(item: feature) { PaywallView(highlight: $0) }
    }
}

/// 잠긴 것 옆의 작은 자물쇠. 눌러 보기 전에 잠긴 줄 알 수 있어야 한다.
struct PlanLockBadge: View {
    let feature: PlanFeature

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(Circle().fill(.black.opacity(0.6)))
            .accessibilityLabel(String(localized: "잠김, \(feature.tier.title)에서 열려요"))
    }
}
