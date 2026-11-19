// MakeAppIcon.swift
// 펀칭 앱 아이콘 — "꾹 눌러 뜯은, 움직이는 스티커".
//
//   따뜻한 노랑→코랄 바탕 위에, 갓 뜯어 모서리가 벗겨지는 흰 스티커 한 장.
//   스티커 가운데엔 펀칭기의 둥근 창(렌즈)이 있고, 왼쪽 위 짧은 선 셋이 움직임을 말한다.
//   그림은 이 다섯 가지뿐이다: 바탕 · 스티커 · 렌즈 · 벗겨진 모서리 · 움직임 선.
//   (반짝이 · 렌즈 테 · 종이 그라데이션은 2026-11 에 덜어 냈다)
//
//   아이콘의 원본은 이 파일 하나다. 한 번 돌리면 아래를 모두 다시 그린다.
//     · 앱 아이콘 라이트 · 다크 · 틴트   StampCamera/Assets.xcassets/AppIcon.appiconset/
//     · 메시지 확장 아이콘 12개 크기     sticker/Assets.xcassets/iMessage App Icon.stickersiconset/
//     · 소개 페이지 아이콘               docs/icon.png
//
// Run (레포 최상단에서):  swift tools/MakeAppIcon.swift

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func rad(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

/// 한 장의 색. 모양은 모두 같다.
struct Look {
    var background: [UInt32]
    var sticker: UInt32
    var lens: UInt32
    var glint: UInt32
    var flap: UInt32
    var marks: UInt32
    var shadow: UInt32

    static let light = Look(background: [0xFFCF5C, 0xFF7A52], sticker: 0xFFFFFF, lens: 0x2B2140,
                            glint: 0xFFFFFF, flap: 0xEDE6DA, marks: 0xFFFFFF, shadow: 0x8A3210)
    /// 다크: 어두운 바탕에 주황 스티커
    static let dark = Look(background: [0x2B2B30, 0x0E0E10], sticker: 0xFFAD66, lens: 0x2E1F14,
                           glint: 0xFFD2A8, flap: 0xE08F52, marks: 0xFFAD66, shadow: 0x000000)
    /// 틴트: 검은 바탕에 회색 — 색은 시스템이 입힌다
    static let tinted = Look(background: [0x000000, 0x000000], sticker: 0xDCDCDC, lens: 0x5A5A5A,
                             glint: 0xF2F2F2, flap: 0xA8A8A8, marks: 0xDCDCDC, shadow: 0x000000)
}

let space = CGColorSpaceCreateDeviceRGB()

/// x + y <= c 인 반평면(keep) 또는 그 반대쪽.
func halfPlane(_ c: CGFloat, keep: Bool) -> CGPath {
    let p = CGMutablePath(), B: CGFloat = 4000
    p.addLines(between: [CGPoint(x: -B, y: c + B), CGPoint(x: c + B, y: -B),
                         keep ? CGPoint(x: -B, y: -B) : CGPoint(x: B, y: B)])
    p.closeSubpath()
    return p
}

/// 그림은 1024 칸 기준으로 그리고, 캔버스의 짧은 변에 맞춰 줄여 가운데에 놓는다.
/// (메시지 확장 아이콘은 4:3 이라 바탕만 옆으로 더 넓어진다)
func render(_ look: Look, width: Int, height: Int) -> CGImage {
    let W = CGFloat(width), H = CGFloat(height)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)        // 왼쪽 위가 원점

    let bg = CGGradient(colorsSpace: space, colors: look.background.map { rgb($0) } as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: W * 0.25, y: 0), end: CGPoint(x: W * 0.75, y: H),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    let unit = min(W, H) / 1024
    ctx.translateBy(x: W / 2, y: H / 2)
    ctx.scaleBy(x: unit, y: unit)

    // 스티커 (가운데가 원점, 살짝 기울인다)
    let half: CGFloat = 310, corner: CGFloat = 130
    let fold: CGFloat = 340          // 벗겨지는 선: x + y = fold (오른쪽 아래 모서리가 들린다)
    let body = CGPath(roundedRect: CGRect(x: -half, y: -half, width: half * 2, height: half * 2),
                      cornerWidth: corner, cornerHeight: corner, transform: nil)
    let stuck = body.intersection(halfPlane(fold, keep: true))          // 아직 붙어 있는 쪽
    let lifted = body.intersection(halfPlane(fold, keep: false))        // 들린 모서리
    let flap = lifted.copy(using: [CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: fold, ty: fold)])!

    ctx.translateBy(x: 28, y: 28)
    ctx.rotate(by: rad(-9))

    // 움직임 선 셋 — 방금 뜯겼고, 움직인다
    ctx.setLineCap(.round); ctx.setStrokeColor(rgb(look.marks)); ctx.setLineWidth(28)
    let from = CGPoint(x: -half + corner * 0.29, y: -half + corner * 0.29)
    for (deg, len) in [(CGFloat(198), CGFloat(64)), (225, 88), (252, 64)] {
        let a = rad(deg), r0: CGFloat = 72
        ctx.move(to: CGPoint(x: from.x + cos(a) * r0, y: from.y + sin(a) * r0))
        ctx.addLine(to: CGPoint(x: from.x + cos(a) * (r0 + len), y: from.y + sin(a) * (r0 + len)))
    }
    ctx.strokePath()

    // 스티커 종이 한 장과 그림자 하나
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22 * unit), blur: 44 * unit, color: rgb(look.shadow, 0.30))
    ctx.addPath(stuck); ctx.setFillColor(rgb(look.sticker)); ctx.fillPath()
    ctx.restoreGState()

    // 렌즈: 한 색 원과 반짝임 하나
    ctx.saveGState()
    ctx.addPath(stuck); ctx.clip()
    let c = CGPoint(x: -30, y: -30), r: CGFloat = 160
    ctx.setFillColor(rgb(look.lens))
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    ctx.setFillColor(rgb(look.glint, 0.92))
    ctx.fillEllipse(in: CGRect(x: c.x - r * 0.52, y: c.y - r * 0.56, width: r * 0.34, height: r * 0.34))
    ctx.restoreGState()

    // 벗겨진 모서리: 접는 선에 비춰 뒤집은 종이 뒷면
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -8 * unit, height: -14 * unit), blur: 22 * unit, color: rgb(look.shadow, 0.28))
    ctx.addPath(flap); ctx.setFillColor(rgb(look.flap)); ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func write(_ look: Look, _ width: Int, _ height: Int, to path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(look, width: width, height: height), nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("쓰지 못했다: \(path)") }
    print("wrote \(path)")
}

// MARK: write

let appIcon = "StampCamera/Assets.xcassets/AppIcon.appiconset"
write(.light, 1024, 1024, to: "\(appIcon)/AppIcon-1024.png")
write(.dark, 1024, 1024, to: "\(appIcon)/AppIcon-dark.png")
write(.tinted, 1024, 1024, to: "\(appIcon)/AppIcon-tinted.png")

let messages = "sticker/Assets.xcassets/iMessage App Icon.stickersiconset"
for (w, h) in [(58, 58), (87, 87), (54, 40), (81, 60), (64, 48), (96, 72), (120, 90), (180, 135),
               (134, 100), (148, 110), (1024, 768), (1024, 1024)] {
    write(.light, w, h, to: "\(messages)/imsg-\(w)x\(h).png")
}

write(.light, 256, 256, to: "docs/icon.png")
