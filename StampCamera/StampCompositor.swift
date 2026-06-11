//
//  StampCompositor.swift
//  StampCamera
//
//  Takes the raw captured photo + the on-screen stamp-window geometry and
//  crops it to the frame's transparent window shape — just the cropped piece,
//  no decoration.
//
//  The key correctness piece is mapping the on-screen window rect (in the
//  preview's aspect-fill coordinate space) back into pixels of the captured
//  image, which has its own resolution and aspect ratio.
//

import UIKit

enum StampCompositor {

    /// Crops the captured photo to the inner stamp shape (the perforated
    /// "teeth" outline) sitting inside the frame's window.
    ///
    /// - Parameters:
    ///   - image: full-frame capture from AVCapturePhotoOutput
    ///   - previewSize: size of the on-screen preview area (points)
    ///   - windowRect: on-screen stamp window rect within that preview (points)
    ///   - mirrored: true for the front camera
    /// Returns the cropped stamp plus the crop region as a 0...1 rect in the
    /// orientation-normalized source image — so the original photo can later be
    /// re-cropped with a different border.
    static func makeStamp(from image: UIImage,
                          previewSize: CGSize,
                          windowRect: CGRect,
                          mirrored: Bool = false,
                          clipToShape: Bool = true,
                          scale: CGFloat = 3.0) -> (image: UIImage, cropNorm: CGRect)? {

        // Normalize to .up so pixel coordinates are predictable.
        let normalized = image.normalizedUp()
        guard let nCG = normalized.cgImage else { return nil }

        let imgW = CGFloat(nCG.width)
        let imgH = CGFloat(nCG.height)

        // --- aspect-fill mapping: how the image is scaled to fill previewSize ---
        let coverScale = max(previewSize.width / imgW, previewSize.height / imgH)
        let dispW = imgW * coverScale
        let dispH = imgH * coverScale
        let dispX = (previewSize.width - dispW) / 2
        let dispY = (previewSize.height - dispH) / 2

        // window rect -> source pixels
        var sx = (windowRect.minX - dispX) / coverScale
        let sy = (windowRect.minY - dispY) / coverScale
        let sw = windowRect.width / coverScale
        let sh = windowRect.height / coverScale

        if mirrored { sx = imgW - sx - sw }
        let srcRect = CGRect(x: sx, y: sy, width: sw, height: sh)
        let cropNorm = CGRect(x: sx / imgW, y: sy / imgH, width: sw / imgW, height: sh / imgH)

        guard let cropped = nCG.cropping(to: srcRect) else { return nil }

        let outSize = CGSize(width: windowRect.width * scale,
                             height: windowRect.height * scale)
        let outRect = CGRect(origin: .zero, size: outSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: outSize, format: format)

        let stampImage = renderer.image { ctx in
            let c = ctx.cgContext
            // Clip the context to the stamp perforation shape, then paint the
            // photo. The holes bite inward, so the body fills the whole window
            // — no inset needed. Clipping is reliable regardless of blend-mode
            // quirks of UIImage.draw(in:) — which silently ignored the
            // .sourceIn stencil and dumped the whole rectangle.
            if clipToShape {
                c.addPath(stampBezierPath(in: outRect).cgPath)
                c.clip()
            }
            if mirrored {
                c.translateBy(x: outSize.width, y: 0)
                c.scaleBy(x: -1, y: 1)
            }
            UIImage(cgImage: cropped).draw(in: outRect)
        }
        return (stampImage, cropNorm)
    }
}

extension UIImage {
    /// Returns a copy with orientation baked in as .up.
    func normalizedUp() -> UIImage {
        if imageOrientation == .up { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
