// MakeAppIcon.swift
// 펀칭 앱 아이콘 (1024×1024) — "꾹 눌러 뜯은, 움직이는 스티커".
//
//   따뜻한 노랑→주황 바탕(이전 아이콘의 색을 잇는다) 위에, 갓 뜯어 모서리가
//   벗겨지는 흰 스티커 한 장. 스티커 가운데엔 펀칭기의 둥근 창(렌즈)이 뚫려
//   있고, 왼쪽 위 짧은 선 셋이 움직임을 말한다.
//
//   라이트 · 다크 · 틴트 세 장을 같은 그림에서 색만 바꿔 그린다 (아이콘의 원본은 이 파일 하나).
//   다크는 어두운 바탕에 주황 스티커, 틴트는 검은 바탕에 회색 — 색은 시스템이 입힌다.
//
// Run:  swift tools/MakeAppIcon.swift [출력 폴더]
// 기본 출력: StampCamera/Assets.xcassets/AppIcon.appiconset/AppIcon-{1024,dark,tinted}.png

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func rad(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

/// 한 장의 색. 모양은 셋이 똑같다.
struct Look {
    var file: String
    var background: [UInt32]
    var marks: UInt32
    var shadow: UInt32
    var face: [UInt32]
    var rim: UInt32
    var lens: [UInt32]
    var glint: UInt32
    var spark: UInt32
    var back: [UInt32]
}
let looks = [
    Look(file: "AppIcon-1024.png", background: [0xFFD65C, 0xFF8A4C, 0xFF6A5A], marks: 0xFFFFFF, shadow: 0x7A2A10,
         face: [0xFFFFFF, 0xFFF7EC], rim: 0xF1E6D2, lens: [0x3D2C52, 0x241A33], glint: 0xFFFFFF,
         spark: 0xFFB020, back: [0xD9D2C6, 0xF4F0E8, 0xE3DDD2]),
    Look(file: "AppIcon-dark.png", background: [0x2B2B30, 0x1A1A1D, 0x0E0E10], marks: 0xFFAD66, shadow: 0x000000,
         face: [0xFFB06A, 0xFFA65C], rim: 0xF5A25C, lens: [0x4A2F1C, 0x2C1E14], glint: 0xFFB878,
         spark: 0xC98A52, back: [0xD98A52, 0xFFB272, 0xE89B60]),
    Look(file: "AppIcon-tinted.png", background: [0x000000, 0x000000, 0x000000], marks: 0xD6D6D6, shadow: 0x000000,
         face: [0xDCDCDC, 0xD0D0D0], rim: 0xC4C4C4, lens: [0x767676, 0x5C5C5C], glint: 0xEDEDED,
         spark: 0xA8A8A8, back: [0xA6A6A6, 0xE4E4E4, 0xBABABA]),
]

let S: CGFloat = 1024
let space = CGColorSpaceCreateDeviceRGB()

func render(_ look: Look) -> CGImage {
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// top-left origin, y down
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

// MARK: background — warm sunrise gradient
let bg = CGGradient(colorsSpace: space, colors: look.background.map { rgb($0) } as CFArray,
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
ctx.setStrokeColor(rgb(look.marks, 0.95))
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
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 46, color: rgb(look.shadow, 0.38))
ctx.addPath(stuck); ctx.setFillColor(rgb(look.face[0])); ctx.fillPath()
ctx.restoreGState()

// face: white sticker paper, the punched window, a spark
ctx.saveGState()
ctx.addPath(stuck); ctx.clip()
let face = CGGradient(colorsSpace: space, colors: look.face.map { rgb($0) } as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(face, start: CGPoint(x: -half, y: -half), end: CGPoint(x: half, y: half), options: [])
// the punched window: a deep navy lens with a cream rim
let lensC = CGPoint(x: -34, y: -34), lensR: CGFloat = 168
ctx.setFillColor(rgb(look.rim))
ctx.fillEllipse(in: CGRect(x: lensC.x - lensR - 26, y: lensC.y - lensR - 26, width: (lensR + 26) * 2, height: (lensR + 26) * 2))
let lens = CGGradient(colorsSpace: space, colors: look.lens.map { rgb($0) } as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: lensC.x - lensR, y: lensC.y - lensR, width: lensR * 2, height: lensR * 2)); ctx.clip()
ctx.drawRadialGradient(lens, startCenter: CGPoint(x: lensC.x - 50, y: lensC.y - 60), startRadius: 0,
                       endCenter: lensC, endRadius: lensR, options: [.drawsAfterEndLocation])
ctx.restoreGState()
// lens glints
ctx.setFillColor(rgb(look.glint, 0.9))
ctx.fillEllipse(in: CGRect(x: lensC.x - 92, y: lensC.y - 98, width: 62, height: 62))
ctx.setFillColor(rgb(look.glint, 0.45))
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
ctx.setFillColor(rgb(look.spark))
spark(CGPoint(x: 186, y: -196), 62)
ctx.restoreGState()

// the peeled flap: the cut-off corner reflected across the fold line,
// showing the sticker's paper back
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: -10, height: -18), blur: 26, color: rgb(look.shadow == 0 ? 0x000000 : 0x5A2010, 0.35))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.addPath(flap); ctx.clip()
let back = CGGradient(colorsSpace: space, colors: look.back.map { rgb($0) } as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(back, start: CGPoint(x: fold / 2, y: fold / 2), end: CGPoint(x: fold / 2 - 140, y: fold / 2 - 140),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.endTransparencyLayer()
ctx.restoreGState()

ctx.restoreGState()

return ctx.makeImage()!
}

// MARK: write
let outDir = CommandLine.arguments.dropFirst().first ?? "StampCamera/Assets.xcassets/AppIcon.appiconset"
for look in looks {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(look.file)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(look), nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path)")
}
