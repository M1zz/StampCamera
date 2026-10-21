//
//  StampCameraSupportView.swift
//  StampCamera
//
//  앱의 하나뿐인 설정 화면 — 카메라 오른쪽 위 톱니에서 연다.
//  구역은 앱의 세 칸(뜯기 · 보기 · 쓰기)과 지원 순서다 (IDENTITY.md §3).
//

import SwiftUI
import LeeoKit

struct StampCameraSupportView: View {
    @Environment(\.dismiss) private var dismiss

    /// 새로 뜯는 스티커의 기본 모양. 카메라와 같은 키를 쓴다.
    @AppStorage("captureStyle") private var captureStyleRaw = StampStyle.liveSticker.rawValue
    /// 펀칭 프레임 — 카메라와 같은 키라 여기서 바꾸면 바로 반영된다.
    @AppStorage(StampFrameLoader.selectionKey) private var stampFrameName = "StampFrame"
    /// 모아둔 움직이는 스티커를 화면 곳곳에서 재생할지 (LiveArt 가 읽는 값)
    @AppStorage("liveAutoPlay") private var liveAutoPlay = true
    /// 꺼짐 = 점 인디케이터, 켜짐 = 책처럼 종이 넘기기
    @AppStorage("pageCurl") private var pageCurl = false

    @State private var showPrintGuide = false

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

                Section {
                    LeeoSupportSection<StampCameraSpec>()
                    NavigationLink(LeeoRoadmapText.entry) { RoadmapScreen() }
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
                    Button("완료") { dismiss() }
                }
            }
            .sheet(isPresented: $showPrintGuide) {
                PrintGuideView()
            }
        }
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

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}
