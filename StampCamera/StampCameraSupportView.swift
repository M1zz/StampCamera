//
//  StampCameraSupportView.swift
//  StampCamera
//

import SwiftUI
import LeeoKit

struct StampCameraSupportView: View {
    var body: some View {
        NavigationStack {
            List {
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
