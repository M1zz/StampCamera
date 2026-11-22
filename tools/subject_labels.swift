// subject_labels.swift — 스크린샷 고르기 장면용 대상 지도 (맥에서 실행)
//
// 시뮬레이터는 Vision 의 대상 나누기를 못 돌리므로, 앱이 내보낸 고르기 화면 사진
// (docs/screenshots/seed/crop/backdrop.png)에서 대상을 나눠 번호 그림(회색 값 = 대상 번호)으로 둔다
// → docs/screenshots/seed/cut/backdrop-labels.png. 앱(DEBUG)은 이것을 SubjectMap 으로 읽는다.
//
//   swift tools/subject_labels.swift <사진> <번호 그림>

import Foundation
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("사용법: <사진> <번호 그림>"); exit(1) }
// 맥의 Vision 은 긴 사진의 지도를 어긋나게 준다 → 정사각 바탕 가운데에 직접 놓고 나눈 뒤, 사진 자리만 잘라 낸다
let side = max(cg.width, cg.height)
let sq = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
sq.setFillColor(gray: 0.5, alpha: 1); sq.fill(CGRect(x: 0, y: 0, width: side, height: side))
sq.draw(cg, in: CGRect(x: (side - cg.width) / 2, y: (side - cg.height) / 2, width: cg.width, height: cg.height))
let request = VNGenerateForegroundInstanceMaskRequest()
try VNImageRequestHandler(cgImage: sq.makeImage()!).perform([request])
guard let result = request.results?.first else { print("대상 없음"); exit(2) }
let buf = result.instanceMask
CVPixelBufferLockBaseAddress(buf, .readOnly)
let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), row = CVPixelBufferGetBytesPerRow(buf)
let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
let fw = cg.width * w / side, fh = cg.height * h / side
let ox = (w - fw) / 2, oy = (h - fh) / 2
var out = [UInt8](repeating: 0, count: fw * fh)
for y in 0..<fh { for x in 0..<fw { out[y * fw + x] = base[(y + oy) * row + x + ox] } }
CVPixelBufferUnlockBaseAddress(buf, .readOnly)
let (w2, h2) = (fw, fh)
let provider = CGDataProvider(data: Data(out) as CFData)!
let img = CGImage(width: w2, height: h2, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w2,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("\(result.allInstances.count)개 · \(w2)×\(h2)")
