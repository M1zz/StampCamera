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
    /// Number of perforation holes along the horizontal edges.
    var teethX: Int = 8
    /// Number of perforation holes along the vertical edges.
    var teethY: Int = 11
    /// Radius of each perforation hole, as a fraction of the per-hole step.
    /// Kept modest so the holes nearest the corners don't meet and eat the
    /// corner away — the corner stays as a clean solid block.
    var biteRatio: CGFloat = 0.32

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

        // Each edge is a straight line with evenly-spaced semicircular holes
        // bitten *inward* — real postage perforations, with flat gaps between
        // the holes and clean square corners.
        p.move(to: CGPoint(x: ox, y: oy))

        // Top edge (left -> right): holes dip downward into the stamp.
        for i in 0..<teethX {
            let cx = ox + (CGFloat(i) + 0.5) * stepX
            p.addLine(to: CGPoint(x: cx - r, y: oy))
            p.addArc(center: CGPoint(x: cx, y: oy), radius: r,
                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        }
        p.addLine(to: CGPoint(x: ox + w, y: oy))

        // Right edge (top -> bottom): holes dip leftward.
        for j in 0..<teethY {
            let cy = oy + (CGFloat(j) + 0.5) * stepY
            p.addLine(to: CGPoint(x: ox + w, y: cy - r))
            p.addArc(center: CGPoint(x: ox + w, y: cy), radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        }
        p.addLine(to: CGPoint(x: ox + w, y: oy + h))

        // Bottom edge (right -> left): holes dip upward.
        for i in stride(from: teethX - 1, through: 0, by: -1) {
            let cx = ox + (CGFloat(i) + 0.5) * stepX
            p.addLine(to: CGPoint(x: cx + r, y: oy + h))
            p.addArc(center: CGPoint(x: cx, y: oy + h), radius: r,
                     startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
        }
        p.addLine(to: CGPoint(x: ox, y: oy + h))

        // Left edge (bottom -> top): holes dip rightward.
        for j in stride(from: teethY - 1, through: 0, by: -1) {
            let cy = oy + (CGFloat(j) + 0.5) * stepY
            p.addLine(to: CGPoint(x: ox, y: cy + r))
            p.addArc(center: CGPoint(x: ox, y: cy), radius: r,
                     startAngle: .degrees(90), endAngle: .degrees(270), clockwise: true)
        }

        p.closeSubpath()
        return p
    }
}

/// A `UIBezierPath` version of the same stamp outline, used for clipping the
/// captured `CGImage` during photo composition.
func stampBezierPath(in rect: CGRect, teethX: Int = 8, teethY: Int = 11, biteRatio: CGFloat = 0.32) -> UIBezierPath {
    let shapePath = StampShape(teethX: teethX, teethY: teethY, biteRatio: biteRatio).path(in: rect)
    return UIBezierPath(cgPath: shapePath.cgPath)
}
