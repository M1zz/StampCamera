// MakeAppIcon.swift
// 펀칭 앱 아이콘 (1024×1024) — "꾹 눌러 뜯은, 움직이는 스티커".
//
//   따뜻한 노랑→주황 바탕(이전 아이콘의 색을 잇는다) 위에, 갓 뜯어 모서리가
//   벗겨지는 흰 스티커 한 장. 스티커 가운데엔 펀칭기의 둥근 창(렌즈)이 뚫려
//   있고, 왼쪽 위 짧은 선 셋이 움직임을 말한다.
//
// Run:  swift tools/MakeAppIcon.swift [출력 경로]
// 기본 출력: StampCamera/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func rad(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

let S: CGFloat = 1024
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// top-left origin, y down
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

// MARK: background — warm sunrise gradient
let bg = CGGradient(colorsSpace: space, colors: [rgb(0xFFD65C), rgb(0xFF8A4C), rgb(0xFF6A5A)] as CFArray,
                    locations: [0, 0.62, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: S * 0.3, y: 0), end: CGPoint(x: S * 0.7, y: S),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// MARK: the sticker (local coords: centre origin, rotated)
let half: CGFloat = 318          // half side
let corner: CGFloat = 132        // rounded-square radius
let fold: CGFloat = 330          // peel line: x + y = fold (bottom-right corner lifts)
let body = CGPath(roundedRect: CGRect(x: -half, y: -half, width: half * 2, height: half * 2),
                  cornerWidth: corner, cornerHeight: corner, transform: nil)
/// Half-plane x + y <= c (keep = true) or > c, as a big polygon.
func halfPlane(_ c: CGFloat, keep: Bool) -> CGPath {
    let p = CGMutablePath(), B: CGFloat = 4000
    if keep {
        p.addLines(between: [CGPoint(x: -B, y: c + B), CGPoint(x: c + B, y: -B), CGPoint(x: -B, y: -B)])
    } else {
        p.addLines(between: [CGPoint(x: -B, y: c + B), CGPoint(x: c + B, y: -B), CGPoint(x: B, y: B)])
    }
    p.closeSubpath()
    return p
}

let stuck = body.intersection(halfPlane(fold, keep: true))           // still on the page
let lifted = body.intersection(halfPlane(fold, keep: false))         // the corner coming off
let flap = lifted.copy(using: [CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: fold, ty: fold)])!

ctx.saveGState()
ctx.translateBy(x: S / 2 + 30, y: S / 2 + 30)
ctx.rotate(by: rad(-9))

// pop marks — three short strokes bursting from the top-left corner: it just
// came off, and it moves
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.95))
ctx.setLineWidth(30)
let cornerPt = CGPoint(x: -half + corner * 0.29, y: -half + corner * 0.29)
for (deg, len) in [(CGFloat(198), CGFloat(70)), (225, 96), (252, 70)] {
    let a = rad(deg), r0: CGFloat = 70
    ctx.move(to: CGPoint(x: cornerPt.x + cos(a) * r0, y: cornerPt.y + sin(a) * r0))
    ctx.addLine(to: CGPoint(x: cornerPt.x + cos(a) * (r0 + len), y: cornerPt.y + sin(a) * (r0 + len)))
}
ctx.strokePath()
ctx.restoreGState()

// drop shadow of the stuck-down part
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 46, color: rgb(0x7A2A10, 0.38))
ctx.addPath(stuck); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()

// face: white sticker paper, the punched window, a spark
ctx.saveGState()
ctx.addPath(stuck); ctx.clip()
let face = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xFFF7EC)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(face, start: CGPoint(x: -half, y: -half), end: CGPoint(x: half, y: half), options: [])
// the punched window: a deep navy lens with a cream rim
let lensC = CGPoint(x: -34, y: -34), lensR: CGFloat = 168
ctx.setFillColor(rgb(0xF1E6D2))
ctx.fillEllipse(in: CGRect(x: lensC.x - lensR - 26, y: lensC.y - lensR - 26, width: (lensR + 26) * 2, height: (lensR + 26) * 2))
let lens = CGGradient(colorsSpace: space, colors: [rgb(0x3D2C52), rgb(0x241A33)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: lensC.x - lensR, y: lensC.y - lensR, width: lensR * 2, height: lensR * 2)); ctx.clip()
ctx.drawRadialGradient(lens, startCenter: CGPoint(x: lensC.x - 50, y: lensC.y - 60), startRadius: 0,
                       endCenter: lensC, endRadius: lensR, options: [.drawsAfterEndLocation])
ctx.restoreGState()
// lens glints
ctx.setFillColor(rgb(0xFFFFFF, 0.9))
ctx.fillEllipse(in: CGRect(x: lensC.x - 92, y: lensC.y - 98, width: 62, height: 62))
ctx.setFillColor(rgb(0xFFFFFF, 0.45))
ctx.fillEllipse(in: CGRect(x: lensC.x - 22, y: lensC.y - 112, width: 26, height: 26))
// a little four-point spark, top-right of the face
func spark(_ c: CGPoint, _ r: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
    ctx.addPath(p); ctx.fillPath()
}
ctx.setFillColor(rgb(0xFFB020))
spark(CGPoint(x: 186, y: -196), 62)
ctx.restoreGState()

// the peeled flap: the cut-off corner reflected across the fold line,
// showing the sticker's paper back
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: -10, height: -18), blur: 26, color: rgb(0x5A2010, 0.35))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.addPath(flap); ctx.clip()
let back = CGGradient(colorsSpace: space, colors: [rgb(0xD9D2C6), rgb(0xF4F0E8), rgb(0xE3DDD2)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(back, start: CGPoint(x: fold / 2, y: fold / 2), end: CGPoint(x: fold / 2 - 140, y: fold / 2 - 140),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.endTransparencyLayer()
ctx.restoreGState()

ctx.restoreGState()

// MARK: write
let img = ctx.makeImage()!
let outPath = CommandLine.arguments.dropFirst().first
    ?? "StampCamera/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
