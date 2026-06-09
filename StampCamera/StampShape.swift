//
//  StampShape.swift
//  StampCamera
//
//  A postage-stamp outline: a rounded rectangle whose edges are bitten by
//  semicircular perforations (the classic stamp "teeth"), with the four corners
//  rounded so they read as teeth too — not hard square blocks.
//
//  This single shape is the source of truth for the crop mask applied to the
//  captured photo, so the saved stamp has authentic perforated edges.
//

import SwiftUI

struct StampShape: Shape {
    /// Number of perforation holes along the horizontal edges.
    var teethX: Int = 6
    /// Number of perforation holes along the vertical edges.
    var teethY: Int = 8
    /// Radius of each perforation hole, as a fraction of the per-hole step.
    var biteRatio: CGFloat = 0.196

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let ox = rect.minX
        let oy = rect.minY

        let stepX = w / CGFloat(teethX)
        let stepY = h / CGFloat(teethY)
        // One uniform radius for every edge so the holes stay perfectly round
        // even when the window isn't square.
        let r = min(stepX, stepY) * biteRatio
        // Only a gentle corner round — leaving a solid margin between the corner
        // and the first hole, so the corners stay full instead of getting gnawed
        // away by the perforations.
        let cr = min(stepX, stepY) * 0.12

        // Distribute holes so EVERY gap is equal — including the corner margins —
        // instead of the corners running long. Each edge of length L is:
        //   L = 2·cr (corner rounds) + teeth·2r (holes) + (teeth+1)·gap
        let gapX = (w - 2 * cr - 2 * r * CGFloat(teethX)) / CGFloat(teethX + 1)
        let gapY = (h - 2 * cr - 2 * r * CGFloat(teethY)) / CGFloat(teethY + 1)
        func holeX(_ i: Int) -> CGFloat { ox + cr + gapX + r + CGFloat(i) * (2 * r + gapX) }
        func holeY(_ j: Int) -> CGFloat { oy + cr + gapY + r + CGFloat(j) * (2 * r + gapY) }

        // Each edge is a straight line with evenly-spaced semicircular holes
        // bitten *inward*; the corners are convex rounds. Traversed clockwise.
        p.move(to: CGPoint(x: ox + cr, y: oy))

        // Top edge (left -> right): holes dip downward into the stamp.
        for i in 0..<teethX {
            let cx = holeX(i)
            p.addLine(to: CGPoint(x: cx - r, y: oy))
            p.addArc(center: CGPoint(x: cx, y: oy), radius: r,
                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        }
        p.addLine(to: CGPoint(x: ox + w - cr, y: oy))
        // top-right corner (convex)
        p.addArc(center: CGPoint(x: ox + w - cr, y: oy + cr), radius: cr,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)

        // Right edge (top -> bottom): holes dip leftward.
        for j in 0..<teethY {
            let cy = holeY(j)
            p.addLine(to: CGPoint(x: ox + w, y: cy - r))
            p.addArc(center: CGPoint(x: ox + w, y: cy), radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        }
        p.addLine(to: CGPoint(x: ox + w, y: oy + h - cr))
        // bottom-right corner (convex)
        p.addArc(center: CGPoint(x: ox + w - cr, y: oy + h - cr), radius: cr,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)

        // Bottom edge (right -> left): holes dip upward.
        for i in stride(from: teethX - 1, through: 0, by: -1) {
            let cx = holeX(i)
            p.addLine(to: CGPoint(x: cx + r, y: oy + h))
            p.addArc(center: CGPoint(x: cx, y: oy + h), radius: r,
                     startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
        }
        p.addLine(to: CGPoint(x: ox + cr, y: oy + h))
        // bottom-left corner (convex)
        p.addArc(center: CGPoint(x: ox + cr, y: oy + h - cr), radius: cr,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)

        // Left edge (bottom -> top): holes dip rightward.
        for j in stride(from: teethY - 1, through: 0, by: -1) {
            let cy = holeY(j)
            p.addLine(to: CGPoint(x: ox, y: cy + r))
            p.addArc(center: CGPoint(x: ox, y: cy), radius: r,
                     startAngle: .degrees(90), endAngle: .degrees(270), clockwise: true)
        }
        p.addLine(to: CGPoint(x: ox, y: oy + cr))
        // top-left corner (convex)
        p.addArc(center: CGPoint(x: ox + cr, y: oy + cr), radius: cr,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)

        p.closeSubpath()
        return p
    }
}

/// A `UIBezierPath` version of the same stamp outline, used for clipping the
/// captured `CGImage` during photo composition.
func stampBezierPath(in rect: CGRect, teethX: Int = 6, teethY: Int = 8, biteRatio: CGFloat = 0.196) -> UIBezierPath {
    let shapePath = StampShape(teethX: teethX, teethY: teethY, biteRatio: biteRatio).path(in: rect)
    return UIBezierPath(cgPath: shapePath.cgPath)
}
