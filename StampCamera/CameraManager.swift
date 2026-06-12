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
    @Published var permissionDenied = false         // true only once access is actually refused
    @Published var capturedImage: UIImage?          // raw full-frame capture
    /// "Live stamp" frames: extracted from the real Live-Photo movie (spanning
    /// before AND after the shutter), or — on devices without Live Photo —
    /// a ~1.2s post-shutter burst off the video stream. Delivered after
    /// `capturedImage`.
    @Published var capturedLiveFrames: [UIImage]?
    /// Real-time span of `capturedLiveFrames`, so playback keeps true speed.
    var capturedLiveSeconds: Double = 1.2
    @Published var position: AVCaptureDevice.Position = .back

    // Zoom expressed the way Apple's camera shows it (1.0 = wide, 0.5 = ultra-wide)
    @Published var zoom: CGFloat = 1.0
    @Published var minZoom: CGFloat = 1.0
    @Published var maxZoom: CGFloat = 8.0
    @Published var zoomStops: [CGFloat] = [1.0]

    // Session plumbing lives off the main actor — it is only ever touched
    // on `sessionQueue`, so it is intentionally nonisolated.
    nonisolated let session = AVCaptureSession()
    // Stills come from AVCapturePhotoOutput at full sensor resolution (the
    // photo pipeline: Smart HDR, fusion, the lot). That brings the system
    // shutter sound with it — accepted, the punch quality is worth it. The
    // video stream below still feeds the preview and the live-stamp burst,
    // and doubles as a fallback if a photo capture errors out.
    private nonisolated let photoOutput = AVCapturePhotoOutput()
    private nonisolated let videoOutput = AVCaptureVideoDataOutput()
    private nonisolated let ciContext = CIContext()
    private nonisolated let sessionQueue = DispatchQueue(label: "stamp.camera.session")
    private nonisolated let videoQueue = DispatchQueue(label: "stamp.camera.video")
    private nonisolated(unsafe) var captureRequested = false   // touched only on videoQueue
    // live-burst state — touched only on videoQueue. A short ring of small
    // frames is kept at all times (the pre-shutter moment, like a Live
    // Photo's rolling buffer); on capture it seeds the burst.
    private nonisolated(unsafe) var liveRequested = false
    private nonisolated(unsafe) var liveFrames: [UIImage] = []
    private nonisolated(unsafe) var liveTargetCount = 12
    private nonisolated(unsafe) var preRoll: [UIImage] = []
    private nonisolated(unsafe) var preTick = 0
    private nonisolated let preRollMax = 7          // ≈0.7s before the shutter
    private nonisolated let liveFrameCount = 12     // ≈1.2s after it
    private nonisolated let liveFrameStride = 3     // every 3rd frame (30fps → 10fps)
    private nonisolated(unsafe) var currentInput: AVCaptureDeviceInput?
    // videoZoomFactor that displays as "1.0×" (2.0 on devices with an ultra-wide)
    private nonisolated(unsafe) var baseZoom: CGFloat = 1.0

    // MARK: - Authorization

    func requestAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            permissionDenied = false
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorized = granted
            permissionDenied = !granted
        default:
            isAuthorized = false
            permissionDenied = true
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

            // NOTE: deliberately NOT enabling Live-Photo capture — pairing it
            // with a video data output proved flaky in the field (the movie
            // can silently fail and frames can stall). The pre-shutter moment
            // comes from our own rolling ring on the video stream instead.
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .quality
            }
            if self.session.canAddOutput(self.videoOutput) {
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                self.session.addOutput(self.videoOutput)
            }
            self.configureVideoConnection()
            self.configurePhotoConnection()

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
            self.configureVideoConnection()
            self.configurePhotoConnection()
        }
    }

    // MARK: - Capture

    /// Orients the video output upright (portrait) and un-mirrored, so the
    /// grabbed frames match what AVCapturePhotoOutput used to hand back — the
    /// front-camera flip is handled later by StampCompositor's `mirrored` flag.
    private nonisolated func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    /// Like the video connection: portrait, un-mirrored, and allowed up to the
    /// sensor's full photo resolution.
    private nonisolated func configurePhotoConnection() {
        if let connection = photoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        if let format = currentInput?.device.activeFormat,
           let best = format.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = best
        }
    }

    /// Fires a full-resolution photo capture; the cropping that follows uses
    /// the same aspect-fill mapping, so registration is unchanged. With
    /// `live`, the burst clip starts from the pre-shutter ring (the moment
    /// you reacted to) and keeps rolling ~1.2s after — all off our own video
    /// stream, no special capture modes to fail.
    func capturePhoto(live: Bool = false) {
        if live {
            videoQueue.async { [weak self] in
                guard let self else { return }
                self.liveFrames = self.preRoll          // the moment BEFORE the shutter
                self.preRoll = []
                self.liveTargetCount = self.liveFrames.count + self.liveFrameCount
                self.liveRequested = true
            }
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = .balanced   // 12MP + HDR, still snappy
            settings.flashMode = .off
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    /// Pauses the capture session — the system's green camera light goes off
    /// while the user is browsing, not shooting.
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// Resumes the session when the camera screen is front and centre again.
    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        if error == nil,
           let data = photo.fileDataRepresentation(),
           let image = UIImage(data: data) {
            Task { @MainActor in self.capturedImage = image }
        } else {
            // photo pipeline hiccuped — fall back to grabbing the next video frame
            videoQueue.async { [weak self] in self?.captureRequested = true }
        }
    }

}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if captureRequested {
            captureRequested = false
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                let image = UIImage(cgImage: cg)   // already upright portrait, .up
                Task { @MainActor in self.capturedImage = image }
            }
        }

        // a steady ~10fps trickle of small frames: while idle they fill a
        // short ring (the pre-shutter moment); while a burst is rolling they
        // extend it until the clip is full
        preTick += 1
        guard preTick % liveFrameStride == 0 else { return }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1, 720 / max(ci.extent.width, ci.extent.height))
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(small, from: small.extent) else { return }
        let frame = UIImage(cgImage: cg)

        if liveRequested {
            liveFrames.append(frame)
            if liveFrames.count >= liveTargetCount {
                liveRequested = false
                let frames = liveFrames
                liveFrames = []
                Task { @MainActor in
                    self.capturedLiveSeconds =
                        Double(frames.count * self.liveFrameStride) / 30.0
                    self.capturedLiveFrames = frames
                }
            }
        } else {
            preRoll.append(frame)
            if preRoll.count > preRollMax { preRoll.removeFirst() }
        }
    }
}
