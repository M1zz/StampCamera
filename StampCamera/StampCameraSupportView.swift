//
//  StampCameraSupportView.swift
//  StampCamera
//
//  앱의 하나뿐인 설정 화면 — 카메라 오른쪽 위 톱니에서 연다.
//  구역은 앱의 세 칸(뜯기 · 보기 · 쓰기)과 지원 순서다 (IDENTITY.md §3).
//

import SwiftUI
import StoreKit
import LeeoKit
import UniformTypeIdentifiers

struct StampCameraSupportView: View {
    @ObservedObject var collection: CollectionStore
    @ObservedObject private var backup = StickerBackup.shared
    @Environment(\.dismiss) private var dismiss

    // 보관: 백업 파일 · 자동 백업 폴더 · 되살리기
    @State private var sharePayload: SharePayload?
    @State private var makingBackup = false
    @State private var pickFolder = false
    @State private var pickBackup = false
    @State private var importResult: StickerImportResult?
    @State private var importError: String?

    /// 새로 뜯는 스티커의 기본 모양. 카메라와 같은 키를 쓴다.
    @AppStorage("captureStyle") private var captureStyleRaw = StampStyle.liveSticker.rawValue
    /// 펀칭 프레임 — 카메라와 같은 키라 여기서 바꾸면 바로 반영된다.
    @AppStorage(StampFrameLoader.selectionKey) private var stampFrameName = "StampFrame"
    /// 모아둔 움직이는 스티커를 화면 곳곳에서 재생할지 (LiveArt 가 읽는 값)
    @AppStorage("liveAutoPlay") private var liveAutoPlay = true
    /// 꺼짐 = 점 인디케이터, 켜짐 = 책처럼 종이 넘기기
    @AppStorage("pageCurl") private var pageCurl = false

    @State private var showPrintGuide = false
    @ObservedObject private var plans = PunchingPlans.shared
    @State private var showPaywall = false
    @State private var showGraduation = false
    @State private var managingSubscription = false
    /// 복원했는데 찾은 것이 없을 때 그대로 말한다. 조용히 끝나면 단추가 고장 난 줄 안다.
    @State private var restoreMessage: String?

    /// 모양 축만 고른다 — 움직임 축은 그대로 둔다 (움직임은 언제나 기록되고,
    /// 멈춤/움직임은 뜯은 뒤 스티커마다 바꾼다).
    private var cutoutDefault: Binding<Bool> {
        Binding {
            (StampStyle(rawValue: captureStyleRaw) ?? .liveSticker).cutout
        } set: { cutout in
            let moving = (StampStyle(rawValue: captureStyleRaw) ?? .liveSticker).moving
            captureStyleRaw = StampStyle.make(moving: moving, cutout: cutout).rawValue
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("기본 모양", selection: cutoutDefault) {
                        Label("오려낸 스티커", systemImage: "scissors").tag(true)
                        Label("우표 모양", systemImage: "square.dashed").tag(false)
                    }
                    if StampFrameLoader.names.count > 1 {
                        Picker("펀칭 프레임", selection: $stampFrameName) {
                            ForEach(Array(StampFrameLoader.names.enumerated()), id: \.element) { idx, name in
                                Text("프레임 \(idx + 1)").tag(name)
                            }
                        }
                    }
                } header: {
                    Text("뜯기")
                } footer: {
                    Text("오려낼 대상이 없으면 우표 모양으로 뜯어요. 움직임은 언제나 함께 담기니, 뜯은 뒤 스티커마다 모양과 움직임을 바꿀 수 있어요.")
                }

                Section {
                    Toggle("움직임 자동 재생", isOn: $liveAutoPlay)
                    Toggle("책처럼 넘기기", isOn: $pageCurl)
                } header: {
                    Text("보기")
                } footer: {
                    Text("자동 재생을 끄면 어디서나 멈춘 모습으로 보여요. 움직임은 지워지지 않아요.")
                }

                Section {
                    NavigationLink {
                        StickerUseGuide()
                    } label: {
                        Label("메시지·키보드에서 쓰기", systemImage: "message")
                    }
                    Button {
                        showPrintGuide = true
                    } label: {
                        Label("종이 스티커로 인쇄하기", systemImage: "printer")
                    }
                } header: {
                    Text("쓰기")
                }

                keepSection

                Section {
                    HStack {
                        Label("지금 쓰는 칸", systemImage: "seal")
                        Spacer()
                        Text(plans.tier.title).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    if plans.tier < .pro {
                        Button {
                            showPaywall = true
                        } label: {
                            Label("Plus · Pro 보기", systemImage: "sparkles")
                        }
                    }
                    // 구독 중일 때만. 구독을 관리하는 자리 바로 아래에 평생으로 옮겨 가는 길을 늘 둔다.
                    if plans.subscription != nil {
                        Button {
                            managingSubscription = true
                        } label: {
                            Label("구독 관리", systemImage: "creditcard")
                        }
                        Button {
                            showGraduation = true
                        } label: {
                            Label(LeeoLadderText.switchToLifetimeEntry, systemImage: "infinity")
                        }
                    }
                    Button {
                        Task {
                            await plans.restore()
                            if plans.tier == .free {
                                restoreMessage = plans.store.lastError
                                    ?? String(localized: "이 Apple 계정에서 구매한 기록을 찾지 못했어요.")
                            }
                        }
                    } label: {
                        Label("구매 복원", systemImage: "arrow.clockwise")
                    }
                    .disabled(plans.isWorking)
                } header: {
                    Text("펀칭 Plus · Pro")
                } footer: {
                    Text("뜯기, 담기, 메시지와 키보드로 보내기는 언제나 무료예요. 응원하기는 기능을 열지 않아요.")
                }

                Section {
                    LeeoSupportSection<StampCameraSpec>()
                    NavigationLink(LeeoRoadmapText.entry) { RoadmapScreen() }
                    LeeoShareAppLink<StampCameraSpec>()
                    // 개발자 응원하기 — 판매 중인 팁이 있어야 선다.
                    LeeoTipJarLink<StampCameraSpec>(tipJar: StampCameraSpec.tipJar)
                } header: {
                    Text("지원")
                }
            }
            .navigationTitle("설정")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료", systemImage: "checkmark") { dismiss() }
                }
            }
            .sheet(isPresented: $showPrintGuide) {
                PrintGuideView()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showGraduation) {
                LeeoGraduationOfferView(graduate: plans.product(PlanProducts.graduate)) {
                    await plans.refresh()
                }
                .presentationDragIndicator(.visible)
            }
            .manageSubscriptionsSheet(isPresented: $managingSubscription)
            .alert("구매 복원", isPresented: Binding(get: { restoreMessage != nil },
                                                 set: { if !$0 { restoreMessage = nil } })) {
                Button("확인", role: .cancel) { }
            } message: {
                Text(restoreMessage ?? "")
            }
            .task { await plans.refresh() }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(items: payload.items)
            }
            .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result {
                    backup.choose(folder: url)
                    backup.backupNow(collection)
                }
            }
            .fileImporter(isPresented: $pickBackup, allowedContentTypes: [.punchingStickers]) { result in
                switch result {
                case .success(let url):
                    collection.importArchive(at: url) { outcome in
                        switch outcome {
                        case .success(let r): importResult = r
                        case .failure(let e): importError = e.localizedDescription
                        }
                    }
                case .failure(let e):
                    importError = e.localizedDescription
                }
            }
            .alert(item: $importResult) { r in
                Alert(title: Text(StickerImportResult.title(r)),
                      message: Text(StickerImportResult.message(r)))
            }
            .alert("가져오지 못했어요", isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("확인", role: .cancel) { }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    /// 보관 — 스티커는 이 기기 안에 원본 그대로 있고, 언제든 파일로 꺼내 둘 수 있다.
    private var keepSection: some View {
        Section {
            Button {
                makingBackup = true
                collection.makeArchive(album: nil) { url in
                    makingBackup = false
                    if let url { sharePayload = SharePayload(items: [url]) }
                }
            } label: {
                HStack {
                    Label("백업 파일 만들기", systemImage: "archivebox")
                    Spacer()
                    if makingBackup { ProgressView() }
                }
            }
            .disabled(makingBackup || collection.stamps.isEmpty)

            Button { pickFolder = true } label: {
                LabeledContent {
                    Text(backup.folderName ?? String(localized: "꺼짐"))
                } label: {
                    Label("자동 백업 폴더", systemImage: "folder.badge.gearshape")
                }
            }
            if backup.isOn {
                Button {
                    backup.backupNow(collection)
                } label: {
                    LabeledContent {
                        if backup.running {
                            ProgressView()
                        } else if let last = backup.lastBackup {
                            Text(last, format: .relative(presentation: .named))
                        }
                    } label: {
                        Label("지금 백업", systemImage: "arrow.clockwise.icloud")
                    }
                }
                .disabled(backup.running)
                Button(role: .destructive) { backup.turnOff() } label: {
                    Label("자동 백업 끄기", systemImage: "xmark.circle")
                }
            }
            if let err = backup.lastError {
                Text(err).foregroundStyle(.red)
            }

            Button { pickBackup = true } label: {
                Label("백업에서 되살리기", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("보관")
        } footer: {
            Text("스티커는 이 기기 안에 원본 사진과 함께 보관돼요. 자동 백업 폴더로 iCloud Drive 의 폴더를 고르면 앱을 닫을 때마다 그곳에 백업이 저장돼, 새 아이폰에서도 그대로 되살릴 수 있어요. 되살리기는 더하기만 하고 지금 있는 스티커는 지우지 않아요.")
        }
    }
}

extension StickerImportResult {
    static func title(_ r: StickerImportResult) -> String {
        r.added > 0 ? String(localized: "스티커 \(r.added)장을 받았어요")
                    : String(localized: "새로 받은 스티커가 없어요")
    }
    static func message(_ r: StickerImportResult) -> String {
        var parts: [String] = []
        if !r.albums.isEmpty {
            parts.append(String(localized: "수집함: \(r.albums.joined(separator: ", "))"))
        }
        if r.skipped > 0 {
            parts.append(String(localized: "이미 있는 \(r.skipped)장은 건너뛰었어요."))
        }
        return parts.joined(separator: "\n")
    }
}

/// 설정 ▸ 쓰기 ▸ 메시지·키보드에서 쓰기 — 뜯은 스티커를 다른 앱에서 꺼내는 두 길.
private struct StickerUseGuide: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                step(1, "메시지 앱에서 대화를 열어요.")
                step(2, "입력창 옆 ＋ 단추를 누르고 ‘스티커’에서 펀칭 스티커를 골라요.")
                step(3, "꾹 눌러 대화 위 아무 데나 붙여요. 움직이는 스티커는 움직이며 붙어요.")
            } header: {
                Text("메시지")
            } footer: {
                Text("수집함마다 스티커 묶음이 따로 나와요.")
            }

            Section {
                step(1, "아래 ‘설정 열기’ ▸ 키보드 ▸ 펀칭 스티커를 켜요.")
                step(2, "같은 곳에서 ‘전체 접근 허용’도 켜요. 스티커를 복사해 붙이는 데 필요해요.")
                step(3, "아무 앱에서나 키보드의 지구본 단추를 눌러 펀칭 스티커로 바꿔요.")
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label("설정 열기", systemImage: "gear")
                }
            } header: {
                Text("키보드")
            } footer: {
                Text("스티커는 기기 안에서만 오가요. 키보드는 입력한 글자를 읽거나 보내지 않아요.")
            }
        }
        .navigationTitle("메시지·키보드에서 쓰기")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}
