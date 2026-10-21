// lift_subjects.swift — 스크린샷 시드용 피사체 오려내기 (맥에서 실행)
//
// 시뮬레이터는 Vision 의 피사체 분리를 못 돌리므로, 앱이 내보낸 잘린 사진
// (docs/screenshots/seed/crop/*.png)을 앱과 같은 방법으로 오려
// docs/screenshots/seed/cut/*.png 에 둔다. 방법은 SubjectLift.cutout 과 같다:
// 모든 피사체를 그 범위로 잘라 꺼내고, 가장자리를 2px 깎은 뒤 또렷하게 자른다.
// 대상을 못 찾으면 만들지 않는다 → 앱이 그 사진을 우표 모양으로 뜯는다.
//
//   swift tools/lift_subjects.swift docs/screenshots/seed

import Foundation
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/screenshots/seed")
let cropDir = dir.appendingPathComponent("crop"), cutDir = dir.appendingPathComponent("cut")
try? FileManager.default.createDirectory(at: cutDir, withIntermediateDirectories: true)
let ctx = CIContext()

func crispMask(_ image: CIImage) -> CIImage {
    image.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 2.0])
    .applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 16, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 16, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 16, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 16, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: -8, y: -8, z: -8, w: -8)])
    .applyingFilter("CIColorClamp")
    .cropped(to: image.extent)
}

let files = ((try? FileManager.default.contentsOfDirectory(at: cropDir, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
for url in files {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: cg)
    do {
        try handler.perform([request])
        guard let result = request.results?.first else { print("– \(url.lastPathComponent): 대상 없음"); continue }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: true)
        let masked = CIImage(cvPixelBuffer: buffer)
        let out = masked.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: crispMask(masked)])
        guard let cgOut = ctx.createCGImage(out, from: masked.extent),
              let dest = CGImageDestinationCreateWithURL(cutDir.appendingPathComponent(url.lastPathComponent) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { continue }
        CGImageDestinationAddImage(dest, cgOut, nil)
        CGImageDestinationFinalize(dest)
        print("✓ \(url.lastPathComponent) \(cgOut.width)×\(cgOut.height)")
    } catch {
        print("– \(url.lastPathComponent): \(error.localizedDescription)")
    }
}
