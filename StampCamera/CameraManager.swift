//
//  CameraManager.swift
//  StampCamera
//
//  Wraps AVCaptureSession for live preview + still capture.
//  Publishes the captured UIImage (full frame, un-cropped); the stamp
//  crop happens later in StampCompositor using the on-screen geometry.
//

@preconcurrency import AVFoundation
import UIKit
import Combine

@MainActor
final class CameraManager: NSObject, ObservableObject {

    @Published var isAuthorized = false
    @Published var capturedImage: UIImage?          // raw full-frame capture
    @Published var position: AVCaptureDevice.Position = .back

    // Zoom expressed the way Apple's camera shows it (1.0 = wide, 0.5 = ultra-wide)
    @Published var zoom: CGFloat = 1.0
    @Published var minZoom: CGFloat = 1.0
    @Published var maxZoom: CGFloat = 8.0
    @Published var zoomStops: [CGFloat] = [1.0]

    // Session plumbing lives off the main actor — it is only ever touched
    // on `sessionQueue`, so it is intentionally nonisolated.
    nonisolated let session = AVCaptureSession()
    private nonisolated let photoOutput = AVCapturePhotoOutput()
    private nonisolated let sessionQueue = DispatchQueue(label: "stamp.camera.session")
    private nonisolated(unsafe) var currentInput: AVCaptureDeviceInput?
    // videoZoomFactor that displays as "1.0×" (2.0 on devices with an ultra-wide)
    private nonisolated(unsafe) var baseZoom: CGFloat = 1.0

    // MARK: - Authorization

    func requestAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            isAuthorized = false
        }
        if isAuthorized { configure(position: position) }
    }

    // MARK: - Session setup

    private nonisolated func configure(position: AVCaptureDevice.Position) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            self.attachInput(for: position)

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .quality
            }

            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    private nonisolated func attachInput(for position: AVCaptureDevice.Position) {
        if let currentInput { session.removeInput(currentInput) }
        guard let device = bestDevice(for: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        currentInput = input
        applyZoomConfig(for: device)
    }

    /// Picks the richest multi-camera available so 0.5× (ultra-wide) works.
    private nonisolated func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) {
                return device
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    // MARK: - Zoom

    private nonisolated func applyZoomConfig(for device: AVCaptureDevice) {
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let switchovers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let base = (hasUltraWide ? switchovers.first : nil) ?? 1.0
        let minDisplay = device.minAvailableVideoZoomFactor / base
        let maxDisplay = min(device.maxAvailableVideoZoomFactor, base * 8) / base

        var stops: [CGFloat] = []
        if minDisplay <= 0.5 + 0.01 { stops.append(0.5) }
        stops.append(1.0)
        if maxDisplay >= 2 { stops.append(2.0) }

        baseZoom = base
        if let _ = try? device.lockForConfiguration() {
            device.videoZoomFactor = min(max(base, device.minAvailableVideoZoomFactor),
                                         device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        }
        Task { @MainActor in
            self.minZoom = minDisplay
            self.maxZoom = maxDisplay
            self.zoomStops = stops
            self.zoom = 1.0
        }
    }

    /// Sets the displayed zoom (0.5, 1, 2, …); clamps to the device range.
    func setZoom(_ display: CGFloat) {
        let clamped = min(max(display, minZoom), maxZoom)
        zoom = clamped
        applyDeviceZoom(clamped)
    }

    private nonisolated func applyDeviceZoom(_ display: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            let factor = max(device.minAvailableVideoZoomFactor,
                             min(display * self.baseZoom, device.maxAvailableVideoZoomFactor))
            if let _ = try? device.lockForConfiguration() {
                device.videoZoomFactor = factor
                device.unlockForConfiguration()
            }
        }
    }

    func flipCamera() {
        position = (position == .back) ? .front : .back
        reattachInput(for: position)
    }

    private nonisolated func reattachInput(for position: AVCaptureDevice.Position) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.attachInput(for: position)
            self.session.commitConfiguration()
        }
    }

    // MARK: - Capture

    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        triggerCapture(with: settings)
    }

    private nonisolated func triggerCapture(with settings: AVCapturePhotoSettings) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        Task { @MainActor in
            self.capturedImage = image
        }
    }
}
