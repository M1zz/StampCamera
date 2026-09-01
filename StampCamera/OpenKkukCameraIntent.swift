//
//  OpenKkukCameraIntent.swift
//  StampCamera  (shared with the KkukControls widget extension)
//
//  The App Intent behind the Control Center / Lock Screen control. Running it
//  foregrounds the app and routes straight to the live camera.
//
//  ⚠️ Target membership: add this file to BOTH the StampCamera app target and
//  the KkukControls widget-extension target (File Inspector ▸ Target Membership)
//  so the control can reference the intent and the app can run it.
//

import AppIntents

struct OpenKkukCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "꾹 카메라 열기"
    static let description = IntentDescription("꾹 카메라를 바로 엽니다.")

    // Foreground the app when the control is tapped; `perform()` then runs in
    // the app process, where the router lives.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CameraLaunchRouter.shared.requestCamera()
        return .result()
    }
}

/// Surfaces "꾹 카메라 열기" as a system App Shortcut. This alone lets the user
/// add a camera button to Control Center and the Lock Screen via the Shortcuts
/// app today — the dedicated ControlWidget (KkukControls) is the polished
/// one-tap version on top of the same intent.
struct KkukAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenKkukCameraIntent(),
            phrases: [
                "\(.applicationName) 열기",
                "\(.applicationName)으로 사진 찍기"
            ],
            shortTitle: "카메라 열기",
            systemImageName: "camera.fill"
        )
    }
}
