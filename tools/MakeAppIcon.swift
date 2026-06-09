// MakeAppIcon.swift
// Renders the StampCamera app icon at 1024×1024 by reusing the real
// perforated-stamp geometry from StampShape.swift, set inside the pastel-blue
// puncher frame. Run:  swift tools/MakeAppIcon.swift
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
    func rad(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

    p.move(to: CGPoint(x: ox + cr, y: oy))
    // top edge
    for i in 0..<teethX {
        let cx = holeX(i)
        p.addLine(to: CGPoint(x: cx - r, y: oy))
        p.addArc(center: CGPoint(x: cx, y: oy), radius: r,
                 startAngle: rad(180), endAngle: rad(0), clockwise: true)
    }
    p.addLine(to: CGPoint(x: ox + w - cr, y: oy))
    p.addArc(center: CGPoint(x: ox + w - cr, y: oy + cr), radius: cr,
             startAngle: rad(-90), endAngle: rad(0), clockwise: false)
    // right edge
    for j in 0..<teethY {
        let cy = holeY(j)
        p.addLine(to: CGPoint(x: ox + w, y: cy - r))
        p.addArc(center: CGPoint(x: ox + w, y: cy), radius: r,
                 startAngle: rad(-90), endAngle: rad(90), clockwise: true)
    }
    p.addLine(to: CGPoint(x: ox + w, y: oy + h - cr))
    p.addArc(center: CGPoint(x: ox + w - cr, y: oy + h - cr), radius: cr,
             startAngle: rad(0), endAngle: rad(90), clockwise: false)
    // bottom edge
    for i in stride(from: teethX - 1, through: 0, by: -1) {
        let cx = holeX(i)
        p.addLine(to: CGPoint(x: cx + r, y: oy + h))
        p.addArc(center: CGPoint(x: cx, y: oy + h), radius: r,
                 startAngle: rad(0), endAngle: rad(180), clockwise: true)
    }
    p.addLine(to: CGPoint(x: ox + cr, y: oy + h))
    p.addArc(center: CGPoint(x: ox + cr, y: oy + h - cr), radius: cr,
             startAngle: rad(90), endAngle: rad(180), clockwise: false)
    // left edge
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

// 1) Pastel-blue puncher body — full-bleed diagonal gradient (the "frame").
if let g = CGGradient(colorsSpace: space,
                      colors: [rgb(0xCFE3F5), rgb(0x8FB4D8)] as CFArray,
                      locations: [0, 1]) {
    ctx.saveGState()
    ctx.addRect(full); ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: S, y: S), options: [])
    ctx.restoreGState()
}

// 2) Brushed-metal tray — a rounded frame the stamp sits in.
let trayRect = CGRect(x: S * 0.205, y: S * 0.205, width: S * 0.59, height: S * 0.59)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36,
              color: rgb(0x000000, 0.32))
ctx.addPath(roundedRectPath(trayRect, S * 0.07)); ctx.clip()
if let g = CGGradient(colorsSpace: space,
                      colors: [rgb(0xEDEFF2), rgb(0x9DA2A8)] as CFArray,
                      locations: [0, 1]) {
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: trayRect.minY),
                           end: CGPoint(x: 0, y: trayRect.maxY), options: [])
}
ctx.restoreGState()
// tray inner rim
ctx.saveGState()
ctx.addPath(roundedRectPath(trayRect, S * 0.07))
ctx.setStrokeColor(rgb(0x000000, 0.18)); ctx.setLineWidth(2)
ctx.strokePath()
ctx.restoreGState()

// 3) The white perforated stamp, centred in the tray.
let stampRect = trayRect.insetBy(dx: S * 0.072, dy: S * 0.072)
let stamp = stampPath(in: stampRect, teethX: 7, teethY: 7, biteRatio: 0.196)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16,
              color: rgb(0x244055, 0.35))
ctx.addPath(stamp)
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()
// faint inner keyline on the stamp
ctx.saveGState()
ctx.addPath(stamp)
ctx.setStrokeColor(rgb(0xBFD3E6, 0.9)); ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// 4) Camera lens in the stamp centre — ties "stamp" to "camera".
let lensR = S * 0.108
let lensC = CGPoint(x: stampRect.midX, y: stampRect.midY)
let lensRect = CGRect(x: lensC.x - lensR, y: lensC.y - lensR,
                      width: lensR * 2, height: lensR * 2)
// outer metal ring
ctx.saveGState()
ctx.addEllipse(in: lensRect.insetBy(dx: -S * 0.012, dy: -S * 0.012)); ctx.clip()
if let g = CGGradient(colorsSpace: space,
                      colors: [rgb(0xCBCFD4), rgb(0x7E848B)] as CFArray,
                      locations: [0, 1]) {
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: lensRect.minY),
                           end: CGPoint(x: 0, y: lensRect.maxY), options: [])
}
ctx.restoreGState()
// glass
ctx.saveGState()
ctx.addEllipse(in: lensRect); ctx.clip()
if let g = CGGradient(colorsSpace: space,
                      colors: [rgb(0x5A6068), rgb(0x111418)] as CFArray,
                      locations: [0, 1]) {
    ctx.drawRadialGradient(g, startCenter: lensC, startRadius: 1,
                           endCenter: lensC, endRadius: lensR, options: [])
}
ctx.restoreGState()
// aperture glint
ctx.saveGState()
let glint = CGRect(x: lensC.x - lensR * 0.42, y: lensC.y - lensR * 0.58,
                   width: lensR * 0.5, height: lensR * 0.38)
ctx.addEllipse(in: glint)
ctx.setFillColor(rgb(0xFFFFFF, 0.32)); ctx.fillPath()
ctx.restoreGState()

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
