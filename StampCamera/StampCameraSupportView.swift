//
//  StampCameraSupportView.swift
//  StampCamera
//

import SwiftUI
import LeeoKit

struct StampCameraSupportView: View {
    /// 새로 찍는 우표가 기본으로 저장될 모습. 카메라 화면의 버튼에서 이리로 옮겨왔다 —
    /// 같은 키를 쓰므로 기존에 고른 값이 그대로 이어진다.
    @AppStorage("captureStyle") private var captureStyleRaw = StampStyle.liveStamp.rawValue

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("기본 모습", selection: $captureStyleRaw) {
                        ForEach(StampStyle.allCases) { style in
                            Label(style.title, systemImage: style.icon)
                                .tag(style.rawValue)
                        }
                    }
                } header: {
                    Text("찍기")
                } footer: {
                    Text("새로 찍는 우표가 이 모습으로 저장돼요. 움직임은 언제나 함께 보관되니, 찍은 뒤 상세에서 다른 모습으로 언제든 바꿀 수 있어요.")
                }

                Section {
                    LeeoSupportSection<StampCameraSpec>()
                } header: {
                    Text("지원")
                }
            }
            .navigationTitle("설정")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}
