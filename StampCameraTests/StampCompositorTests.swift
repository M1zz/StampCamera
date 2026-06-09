//
//  StampCompositorTests.swift
//  StampCameraTests
//
//  Mapping the on-screen window back into source pixels, and the crop metadata.
//

import Testing
import UIKit
@testable import StampCamera

struct StampCompositorTests {

    /// A scale-1 image so its pixel size equals its point size (deterministic math).
    private func image(_ size: CGSize) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // image 100×100, preview 200×200 (coverScale 2), window (40,50,60,40)
    private let img = CGSize(width: 100, height: 100)
    private let preview = CGSize(width: 200, height: 200)
    private let window = CGRect(x: 40, y: 50, width: 60, height: 40)

    @Test func returnsAResult() {
        let out = StampCompositor.makeStamp(from: image(img), previewSize: preview, windowRect: window)
        #expect(out != nil)
    }

    @Test func cropNormMapsWindowToSourcePixels() throws {
        let out = try #require(StampCompositor.makeStamp(from: image(img),
                                                         previewSize: preview, windowRect: window))
        #expect(abs(out.cropNorm.minX - 0.20) < 0.001)
        #expect(abs(out.cropNorm.minY - 0.25) < 0.001)
        #expect(abs(out.cropNorm.width - 0.30) < 0.001)
        #expect(abs(out.cropNorm.height - 0.20) < 0.001)
    }

    @Test func cropNormStaysInUnitSquare() throws {
        let out = try #require(StampCompositor.makeStamp(from: image(img),
                                                         previewSize: preview, windowRect: window))
        #expect(out.cropNorm.minX >= 0)
        #expect(out.cropNorm.minY >= 0)
        #expect(out.cropNorm.maxX <= 1.0001)
        #expect(out.cropNorm.maxY <= 1.0001)
    }

    @Test func mirroredFlipsHorizontally() throws {
        let normal = try #require(StampCompositor.makeStamp(from: image(img),
                                                            previewSize: preview, windowRect: window))
        let mirrored = try #require(StampCompositor.makeStamp(from: image(img),
                                                              previewSize: preview, windowRect: window,
                                                              mirrored: true))
        // mirrored.minX == 1 − (normal.minX + width)
        #expect(abs(mirrored.cropNorm.minX - (1 - (normal.cropNorm.minX + normal.cropNorm.width))) < 0.001)
        #expect(abs(mirrored.cropNorm.width - normal.cropNorm.width) < 0.001)
    }

    @Test func outputSizeIsWindowTimesScale() throws {
        let out = try #require(StampCompositor.makeStamp(from: image(img),
                                                         previewSize: preview, windowRect: window,
                                                         scale: 3))
        #expect(abs(out.image.size.width - window.width * 3) < 1)
        #expect(abs(out.image.size.height - window.height * 3) < 1)
    }

    // MARK: - normalizedUp

    @Test func normalizedUpKeepsUpImageSize() {
        let up = image(CGSize(width: 30, height: 20))   // already .up
        let n = up.normalizedUp()
        #expect(n.imageOrientation == .up)
        #expect(abs(n.size.width - 30) < 1)
        #expect(abs(n.size.height - 20) < 1)
    }
}
