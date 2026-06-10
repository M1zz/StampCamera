// MakeAppIcon.swift
// Renders the StampCamera app icon at 1024×1024: a golden perforated stamp
// (the app's real StampShape geometry) on warm notebook-cream paper, with a
// simple, original line-art bear inside — echoing the reference photo without
// copying any trademarked character. Run:  swift tools/MakeAppIcon.swift
//
// Output: tools/AppIcon-1024.png

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// MARK: - helpers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8)  & 0xFF) / 255,
            blue:  CGFloat(hex & 0xFF) / 255,
            alpha: a)
}

let space = CGColorSpaceCreateDeviceRGB()

func rad(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

// The exact stamp outline from StampShape.swift, as a CGPath (top-left origin).
func stampPath(in rect: CGRect, teethX: Int, teethY: Int, biteRatio: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let w = rect.width, h = rect.height
    let ox = rect.minX, oy = rect.minY
    let stepX = w / CGFloat(teethX)
    let stepY = h / CGFloat(teethY)
    let r = min(stepX, stepY) * biteRatio
    let cr = min(stepX, stepY) * 0.12
    let gapX = (w - 2 * cr - 2 * r * CGFloat(teethX)) / CGFloat(teethX + 1)
    let gapY = (h - 2 * cr - 2 * r * CGFloat(teethY)) / CGFloat(teethY + 1)
    func holeX(_ i: Int) -> CGFloat { ox + cr + gapX + r + CGFloat(i) * (2 * r + gapX) }
    func holeY(_ j: Int) -> CGFloat { oy + cr + gapY + r + CGFloat(j) * (2 * r + gapY) }

    p.move(to: CGPoint(x: ox + cr, y: oy))
    for i in 0..<teethX {
        let cx = holeX(i)
        p.addLine(to: CGPoint(x: cx - r, y: oy))
        p.addArc(center: CGPoint(x: cx, y: oy), radius: r,
                 startAngle: rad(180), endAngle: rad(0), clockwise: true)
    }
    p.addLine(to: CGPoint(x: ox + w - cr, y: oy))
    p.addArc(center: CGPoint(x: ox + w - cr, y: oy + cr), radius: cr,
             startAngle: rad(-90), endAngle: rad(0), clockwise: false)
    for j in 0..<teethY {
        let cy = holeY(j)
        p.addLine(to: CGPoint(x: ox + w, y: cy - r))
        p.addArc(center: CGPoint(x: ox + w, y: cy), radius: r,
                 startAngle: rad(-90), endAngle: rad(90), clockwise: true)
    }
    p.addLine(to: CGPoint(x: ox + w, y: oy + h - cr))
    p.addArc(center: CGPoint(x: ox + w - cr, y: oy + h - cr), radius: cr,
             startAngle: rad(0), endAngle: rad(90), clockwise: false)
    for i in stride(from: teethX - 1, through: 0, by: -1) {
        let cx = holeX(i)
        p.addLine(to: CGPoint(x: cx + r, y: oy + h))
        p.addArc(center: CGPoint(x: cx, y: oy + h), radius: r,
                 startAngle: rad(0), endAngle: rad(180), clockwise: true)
    }
    p.addLine(to: CGPoint(x: ox + cr, y: oy + h))
    p.addArc(center: CGPoint(x: ox + cr, y: oy + h - cr), radius: cr,
             startAngle: rad(90), endAngle: rad(180), clockwise: false)
    for j in stride(from: teethY - 1, through: 0, by: -1) {
        let cy = holeY(j)
        p.addLine(to: CGPoint(x: ox, y: cy + r))
        p.addArc(center: CGPoint(x: ox, y: cy), radius: r,
                 startAngle: rad(90), endAngle: rad(270), clockwise: true)
    }
    p.addLine(to: CGPoint(x: ox, y: oy + cr))
    p.addArc(center: CGPoint(x: ox + cr, y: oy + cr), radius: cr,
             startAngle: rad(180), endAngle: rad(270), clockwise: false)
    p.closeSubpath()
    return p
}

func roundedRectPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
}

// MARK: - render

let S: CGFloat = 1024
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("ctx")
}

// Flip to top-left origin so the StampShape math reads the same as SwiftUI.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

let full = CGRect(x: 0, y: 0, width: S, height: S)

// 1) Warm notebook-cream paper background (soft diagonal gradient).
if let g = CGGradient(colorsSpace: space,
                      colors: [rgb(0xF7EFD8), rgb(0xE9DBB8)] as CFArray,
                      locations: [0, 1]) {
    ctx.saveGState()
    ctx.addRect(full); ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: S, y: S), options: [])
    ctx.restoreGState()
}
// faint warm vignette so the stamp pops
if let g = CGGradient(colorsSpace: space,
                      colors: [rgb(0xFFFFFF, 0.0), rgb(0x8A7A4E, 0.18)] as CFArray,
                      locations: [0.55, 1]) {
    ctx.saveGState()
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: S/2, y: S/2), startRadius: S*0.2,
                           endCenter: CGPoint(x: S/2, y: S/2), endRadius: S*0.72, options: [])
    ctx.restoreGState()
}

// Everything from here is the stamp + art, tilted a touch for a playful feel.
let center = CGPoint(x: S/2, y: S/2)
ctx.saveGState()
ctx.translateBy(x: center.x, y: center.y)
ctx.rotate(by: rad(-6))
ctx.translateBy(x: -center.x, y: -center.y)

// 2) Golden perforated stamp.
let side = S * 0.64
let stampRect = CGRect(x: center.x - side/2, y: center.y - side/2, width: side, height: side)
let stamp = stampPath(in: stampRect, teethX: 7, teethY: 7, biteRatio: 0.196)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x4A3A10, 0.35))
ctx.addPath(stamp); ctx.clip()
if let g = CGGradient(colorsSpace: space,
                      colors: [rgb(0xF2D079), rgb(0xCDA049)] as CFArray,
                      locations: [0, 1]) {
    ctx.drawLinearGradient(g, start: CGPoint(x: stampRect.minX, y: stampRect.minY),
                           end: CGPoint(x: stampRect.maxX, y: stampRect.maxY), options: [])
}
ctx.restoreGState()
// gold keyline
ctx.saveGState()
ctx.addPath(stamp)
ctx.setStrokeColor(rgb(0xB98C36, 0.9)); ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

// 3) White inner paper panel where the drawing sits (leaves a gold perf border).
let panel = stampRect.insetBy(dx: side * 0.115, dy: side * 0.115)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: rgb(0x7A5E18, 0.28))
ctx.addPath(roundedRectPath(panel, side * 0.04))
ctx.setFillColor(rgb(0xFFFDF6)); ctx.fillPath()
ctx.restoreGState()

// 4) Original cute line-art bear (no trademarked character).
let line = rgb(0x2E2820)
let LW: CGFloat = side * 0.017
ctx.setLineCap(.round); ctx.setLineJoin(.round)

let C = CGPoint(x: panel.midX, y: panel.midY - panel.height * 0.06)
let R = panel.width * 0.235          // head radius
let earR = R * 0.46

func fillStroke(_ path: CGPath, fill: CGColor, lw: CGFloat = LW) {
    ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath()
    ctx.addPath(path); ctx.setStrokeColor(line); ctx.setLineWidth(lw); ctx.strokePath()
}

// ears (with inner pads), drawn before the head so the head overlaps cleanly
let earL = CGPoint(x: C.x - R * 0.78, y: C.y - R * 0.82)
let earRt = CGPoint(x: C.x + R * 0.78, y: C.y - R * 0.82)
for e in [earL, earRt] {
    fillStroke(CGPath(ellipseIn: circle(e, earR), transform: nil), fill: rgb(0xFFFDF6))
    ctx.addPath(CGPath(ellipseIn: circle(e, earR * 0.5), transform: nil))
    ctx.setFillColor(rgb(0xE7C49A)); ctx.fillPath()
}

// head
fillStroke(CGPath(ellipseIn: circle(C, R), transform: nil), fill: rgb(0xFFFDF6))

// closed, content eyes (gentle ⌒ arcs)
ctx.setStrokeColor(line); ctx.setLineWidth(LW)
for sx in [-1.0, 1.0] as [CGFloat] {
    let ec = CGPoint(x: C.x + sx * R * 0.40, y: C.y - R * 0.06)
    let e = CGMutablePath()
    e.addArc(center: ec, radius: R * 0.24, startAngle: rad(202), endAngle: rad(338),
             clockwise: false, transform: .identity)
    ctx.addPath(e); ctx.strokePath()
}

// muzzle
let muzzle = CGRect(x: C.x - R * 0.5, y: C.y + R * 0.12, width: R, height: R * 0.74)
fillStroke(CGPath(ellipseIn: muzzle, transform: nil), fill: rgb(0xF6E9D2), lw: LW * 0.9)

// nose
let nose = CGRect(x: C.x - R * 0.16, y: C.y + R * 0.26, width: R * 0.32, height: R * 0.24)
ctx.addPath(roundedRectPath(nose, R * 0.1)); ctx.setFillColor(line); ctx.fillPath()

// mouth: a stem down from the nose, then two little curves
ctx.setStrokeColor(line); ctx.setLineWidth(LW * 0.9)
let m = CGMutablePath()
let mTop = CGPoint(x: C.x, y: C.y + R * 0.5)
m.move(to: mTop); m.addLine(to: CGPoint(x: C.x, y: C.y + R * 0.62))
m.addArc(center: CGPoint(x: C.x - R * 0.16, y: C.y + R * 0.62), radius: R * 0.16,
         startAngle: rad(0), endAngle: rad(110), clockwise: false, transform: .identity)
m.move(to: CGPoint(x: C.x, y: C.y + R * 0.62))
m.addArc(center: CGPoint(x: C.x + R * 0.16, y: C.y + R * 0.62), radius: R * 0.16,
         startAngle: rad(180), endAngle: rad(70), clockwise: true, transform: .identity)
ctx.addPath(m); ctx.strokePath()

ctx.restoreGState()   // end tilt

// MARK: - write PNG

guard let img = ctx.makeImage() else { fatalError("image") }
let outURL = URL(fileURLWithPath: "tools/AppIcon-1024.png")
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    fatalError("dest")
}
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outURL.path)")
