//
//  KkukControlWidget.swift
//  KkukControls  (Widget Extension target — iOS 18+)
//
//  A Control Center / Lock Screen control that opens the 꾹 camera in one tap.
//  Drives the SAME OpenKkukCameraIntent the app uses, so there is one code path.
//
//  Setup (see KkukControls/SETUP.md):
//   • This file belongs to the KkukControls widget-extension target.
//   • OpenKkukCameraIntent.swift must also be a member of this target
//     (it already builds in the app target; tick KkukControls too).
//   • Xcode's Widget Extension template generates a @main WidgetBundle — add
//     `KkukCameraControl()` to its body and delete the duplicate below.
//

import WidgetKit
import SwiftUI
import AppIntents

@main
struct KkukControlsBundle: WidgetBundle {
    var body: some Widget {
        KkukCameraControl()
    }
}

struct KkukCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.devkoan.StampCamera.OpenCamera") {
            ControlWidgetButton(action: OpenKkukCameraIntent()) {
                Label("꾹 카메라", systemImage: "camera.fill")
            }
        }
        .displayName("꾹 카메라")
        .description("꾹 카메라를 바로 엽니다.")
    }
}
