// 펀칭 웹 체험 그림: 앱과 같은 CIFilter(StampInk)와 Vision(SubjectLift)로 미리 만든다.
//   swiftc -O docs/site/demo-images.swift -o /tmp/demo-images && /tmp/demo-images docs/screenshots/seed docs/img/demo
// 대상을 못 찾은 장면(beach)은 마스크가 없고, 체험에서 우표 모양으로 뜯긴다.
import Foundation
import CoreImage
import Vision
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let seed = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let ctx = CIContext()
let W = 420, H = 560
// name, file, crop (x, y, w) in source pixels, from top-left; h = w * 4/3
let scenes: [(String, String, Double, Double, Double)] = [
    ("corgi", "a-01-corgi.jpg", 160, 470, 960),
    ("cone", "a-08-cone.jpg", 380, 300, 900),
    ("beach", "a-08-cone.jpg", 0, 560, 450),
]
func inks(_ img: CIImage) -> [(String, CIImage)] {
    func f(_ n: String, _ p: [String: Any] = [:]) -> CIImage { img.applyingFilter(n, parameters: p) }
    return [("original", img), ("sepia", f("CISepiaTone", [kCIInputIntensityKey: 0.85])),
            ("mono", f("CIPhotoEffectNoir")), ("faded", f("CIPhotoEffectInstant")),
            ("chrome", f("CIPhotoEffectChrome")), ("process", f("CIPhotoEffectProcess"))]
}
func write(_ img: CIImage, _ url: URL, _ type: UTType, _ q: Double = 0.8) {
    let cg = ctx.createCGImage(img, from: img.extent)!
    let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
    CGImageDestinationFinalize(d)
}
var meta: [String] = []
for (name, file, x, y, w) in scenes {
    let src = CIImage(contentsOf: seed.appendingPathComponent(file))!
    let h = w * 4 / 3, fullH = src.extent.height
    // CIImage origin is bottom-left
    let rect = CGRect(x: x, y: fullH - y - h, width: w, height: h)
    let crop = src.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    let cg = ctx.createCGImage(crop, from: crop.extent)!
    let scale = Double(W) / w
    let small = crop.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    for (ink, img) in inks(small) { write(img, out.appendingPathComponent("\(name)-\(ink).jpg"), .jpeg) }
    // subject mask, same request as SubjectLift
    let req = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: cg)
    try? handler.perform([req])
    guard let r = req.results?.first,
          let buf = try? r.generateScaledMaskForImage(forInstances: r.allInstances, from: handler) else {
        print("\(name): 대상 없음"); meta.append("\(name): null"); continue
    }
    let base = CIImage(cvPixelBuffer: buf)
    let m = base
        .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 2.0])
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 16, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 16, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 16, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -8, y: -8, z: -8, w: 1)])
        .applyingFilter("CIColorClamp").cropped(to: base.extent)
    let ms = m.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: Double(W) / m.extent.width, kCIInputAspectRatioKey: 1])
        .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    write(ms, out.appendingPathComponent("\(name)-mask.png"), .png)
    print("\(name): ok \(m.extent)")
    meta.append("\(name): ok")
}
print(meta)
