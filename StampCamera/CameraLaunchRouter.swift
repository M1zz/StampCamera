//
//  CameraLaunchRouter.swift
//  StampCamera
//
//  Lets an external entry point (the Control Center control, the Lock Screen
//  control, or a `kkuk://camera` deep link) ask the app to drop whatever it's
//  showing and return to the live camera. ContentView observes `showCamera`
//  and dismisses any open sheets / full-screen covers when it flips.
//

import SwiftUI
import Combine

@MainActor
final class CameraLaunchRouter: ObservableObject {
    static let shared = CameraLaunchRouter()

    /// Bumped each time something requests the camera; observe `.onChange` so a
    /// second request (already on the camera) still re-fires.
    @Published var cameraRequestID = 0

    /// Siri / Spotlight asked to open this collected sticker (its id). ContentView
    /// opens it and clears this.
    @Published var stampRequest: String?

    private init() {}

    func requestCamera() { cameraRequestID += 1 }

    /// 메시지 · AirDrop · 파일 앱에서 연 스티커 묶음(.kkuk). ContentView 가 받아 더한다.
    @Published var pendingImport: URL?

    /// Handles the app's custom URL scheme, e.g. `kkuk://camera`.
    func handle(url: URL) {
        // "kkuk" = StickerArchive.fileExtension (이 파일은 위젯 타깃과 함께 써서 직접 적는다)
        if url.isFileURL, url.pathExtension.lowercased() == "kkuk" {
            pendingImport = url
            return
        }
        if url.scheme == "kkuk" && (url.host == "camera" || url.path == "/camera") {
            requestCamera()
        }
    }
}
