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

    /// Crops the captured photo to the frame's transparent window shape.
    ///
    /// - Parameters:
    ///   - image: full-frame capture from AVCapturePhotoOutput
    ///   - previewSize: size of the on-screen preview area (points)
    ///   - windowRect: on-screen stamp window rect within that preview (points)
    ///   - mask: white-on-clear image of the window's transparent shape
    ///   - mirrored: true for the front camera
    static func makeStamp(from image: UIImage,
                          previewSize: CGSize,
                          windowRect: CGRect,
                          mask: UIImage,
                          mirrored: Bool = false,
                          scale: CGFloat = 3.0) -> UIImage? {

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

        guard let cropped = nCG.cropping(to: srcRect) else { return nil }

        let outSize = CGSize(width: windowRect.width * scale,
                             height: windowRect.height * scale)
        let outRect = CGRect(origin: .zero, size: outSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: outSize, format: format)

        return renderer.image { ctx in
            let c = ctx.cgContext
            // 1) lay the window shape down as the alpha stencil
            mask.draw(in: outRect)
            // 2) paint the photo only where the stencil is opaque
            c.setBlendMode(.sourceIn)
            if mirrored {
                c.translateBy(x: outSize.width, y: 0)
                c.scaleBy(x: -1, y: 1)
            }
            UIImage(cgImage: cropped).draw(in: outRect)
            c.setBlendMode(.normal)
        }
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
