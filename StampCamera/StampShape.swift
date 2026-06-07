//
//  StampShape.swift
//  StampCamera
//
//  A postage-stamp outline: a rounded rectangle whose edges are bitten by
//  semicircular perforations (the classic stamp "teeth").
//
//  This single shape is the source of truth for BOTH:
//    1. the on-screen punch frame overlay
//    2. the crop mask applied to the captured photo
//  so what you see in the viewfinder is exactly what gets saved.
//

import SwiftUI

struct StampShape: Shape {
    /// Number of perforation teeth along the horizontal edges.
    var teethX: Int = 9
    /// Number of perforation teeth along the vertical edges.
    var teethY: Int = 12
    /// Radius of each perforation bite, as a fraction of the per-tooth step.
    var biteRatio: CGFloat = 0.5

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let ox = rect.minX
        let oy = rect.minY

        let stepX = w / CGFloat(teethX)
        let stepY = h / CGFloat(teethY)
        let rX = stepX * biteRatio
        let rY = stepY * biteRatio

        // Start at top-left corner.
        p.move(to: CGPoint(x: ox, y: oy))

        // Top edge (left -> right): scallop bumps arc outward (upward).
        for i in 0..<teethX {
            let x0 = ox + CGFloat(i) * stepX
            let x1 = x0 + stepX
            p.addLine(to: CGPoint(x: x0, y: oy))
            p.addArc(center: CGPoint(x: x0 + stepX / 2, y: oy),
                     radius: rX, startAngle: .degrees(180), endAngle: .degrees(0),
                     clockwise: true)
            p.addLine(to: CGPoint(x: x1, y: oy))
        }

        // Right edge (top -> bottom).
        for i in 0..<teethY {
            let y0 = oy + CGFloat(i) * stepY
            let y1 = y0 + stepY
            p.addLine(to: CGPoint(x: ox + w, y: y0))
            p.addArc(center: CGPoint(x: ox + w, y: y0 + stepY / 2),
                     radius: rY, startAngle: .degrees(-90), endAngle: .degrees(90),
                     clockwise: true)
            p.addLine(to: CGPoint(x: ox + w, y: y1))
        }

        // Bottom edge (right -> left).
        for i in stride(from: teethX - 1, through: 0, by: -1) {
            let x1 = ox + CGFloat(i + 1) * stepX
            let x0 = ox + CGFloat(i) * stepX
            p.addLine(to: CGPoint(x: x1, y: oy + h))
            p.addArc(center: CGPoint(x: x0 + stepX / 2, y: oy + h),
                     radius: rX, startAngle: .degrees(0), endAngle: .degrees(180),
                     clockwise: true)
            p.addLine(to: CGPoint(x: x0, y: oy + h))
        }

        // Left edge (bottom -> top).
        for i in stride(from: teethY - 1, through: 0, by: -1) {
            let y1 = oy + CGFloat(i + 1) * stepY
            let y0 = oy + CGFloat(i) * stepY
            p.addLine(to: CGPoint(x: ox, y: y1))
            p.addArc(center: CGPoint(x: ox, y: y0 + stepY / 2),
                     radius: rY, startAngle: .degrees(90), endAngle: .degrees(270),
                     clockwise: true)
            p.addLine(to: CGPoint(x: ox, y: y0))
        }

        p.closeSubpath()
        return p
    }
}

/// A `UIBezierPath` version of the same stamp outline, used for clipping the
/// captured `CGImage` during photo composition.
func stampBezierPath(in rect: CGRect, teethX: Int = 9, teethY: Int = 12, biteRatio: CGFloat = 0.5) -> UIBezierPath {
    let shapePath = StampShape(teethX: teethX, teethY: teethY, biteRatio: biteRatio).path(in: rect)
    return UIBezierPath(cgPath: shapePath.cgPath)
}
