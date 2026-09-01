//
//  CameraPreview.swift
//  StampCamera
//
//  Bridges AVCaptureVideoPreviewLayer into SwiftUI. Uses .resizeAspectFill
//  so the math in StampCompositor (aspect-fill cover) matches what's shown.
//

import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Called when the user taps the live area: `devicePoint` is the
    /// AVFoundation focus point (0...1) and `viewPoint` is where to draw the
    /// focus ring (in the preview's own coordinate space).
    var onFocusTap: ((_ devicePoint: CGPoint, _ viewPoint: CGPoint) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: CameraPreview
        weak var view: PreviewView?
        init(_ parent: CameraPreview) { self.parent = parent }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let p = g.location(in: view)
            let devicePoint = view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: p)
            parent.onFocusTap?(devicePoint, p)
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// The stock-camera "tap to focus" reticle: a square that snaps in, pulses
/// once, then fades. Purely cosmetic feedback for `focusAndExpose`.
struct FocusReticle: View {
    @State private var scale: CGFloat = 1.35
    @State private var opacity: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(Color(hex: 0xFFD60A), lineWidth: 1.5)
            .frame(width: 78, height: 78)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                    scale = 1.0; opacity = 1
                }
                withAnimation(.easeIn(duration: 0.4).delay(0.9)) { opacity = 0 }
            }
    }
}

/// Frosted-glass blur of whatever is behind it. Used to soften the busy live
/// scene outside the stamp frame without making it fully opaque.
struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style = .systemThinMaterial

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
