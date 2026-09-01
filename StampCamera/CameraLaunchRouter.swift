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

    private init() {}

    func requestCamera() { cameraRequestID += 1 }

    /// Handles the app's custom URL scheme, e.g. `kkuk://camera`.
    func handle(url: URL) {
        if url.scheme == "kkuk" && (url.host == "camera" || url.path == "/camera") {
            requestCamera()
        }
    }
}
