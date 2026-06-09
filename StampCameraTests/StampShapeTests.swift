//
//  StampShapeTests.swift
//  StampCameraTests
//
//  The perforated stamp outline: bounds, holes, and equal-gap spacing.
//

import Testing
import SwiftUI
@testable import StampCamera

struct StampShapeTests {

    let rect = CGRect(x: 0, y: 0, width: 300, height: 400)
    let teethX = 6, teethY = 8
    let bite: CGFloat = 0.196

    // Re-derive the same hole centres the shape uses, to probe specific points.
    private func geometry() -> (r: CGFloat, cr: CGFloat, gapX: CGFloat, holeX: (Int) -> CGFloat) {
        let stepX = rect.width / CGFloat(teethX)
        let stepY = rect.height / CGFloat(teethY)
        let r = min(stepX, stepY) * bite
        let cr = min(stepX, stepY) * 0.12
        let gapX = (rect.width - 2 * cr - 2 * r * CGFloat(teethX)) / CGFloat(teethX + 1)
        let holeX: (Int) -> CGFloat = { i in rect.minX + cr + gapX + r + CGFloat(i) * (2 * r + gapX) }
        return (r, cr, gapX, holeX)
    }

    private func makePath() -> Path {
        StampShape(teethX: teethX, teethY: teethY, biteRatio: bite).path(in: rect)
    }

    @Test func boundingBoxMatchesRect() {
        let b = makePath().boundingRect
        #expect(abs(b.minX - rect.minX) < 1)
        #expect(abs(b.minY - rect.minY) < 1)
        #expect(abs(b.maxX - rect.maxX) < 1)
        #expect(abs(b.maxY - rect.maxY) < 1)
    }

    @Test func centerIsInside() {
        #expect(makePath().contains(CGPoint(x: rect.midX, y: rect.midY)))
    }

    @Test func farOutsideIsNotInside() {
        let p = makePath()
        #expect(!p.contains(CGPoint(x: rect.minX - 40, y: rect.midY)))
        #expect(!p.contains(CGPoint(x: rect.midX, y: rect.maxY + 40)))
    }

    @Test func perforationBitesAtHoleCenter() {
        let p = makePath()
        let g = geometry()
        let yJustInside = rect.minY + g.r * 0.5
        // a point inside the top-edge hole is bitten out (not in the path)
        #expect(!p.contains(CGPoint(x: g.holeX(0), y: yJustInside)))
        // the solid tooth between two holes is still in the path
        let gapMid = (g.holeX(0) + g.holeX(1)) / 2
        #expect(p.contains(CGPoint(x: gapMid, y: yJustInside)))
    }

    @Test func gapsAreEqualIncludingCorner() {
        let g = geometry()
        let cornerGap = (g.holeX(0) - g.r) - (rect.minX + g.cr)       // corner round → first hole
        let interGap  = (g.holeX(1) - g.r) - (g.holeX(0) + g.r)       // between holes 0 and 1
        #expect(abs(cornerGap - interGap) < 0.5)                      // essentially identical
        #expect(cornerGap > 0)
    }

    @Test func biggerBiteRatioDigsDeeper() {
        // hole radii: min(step)=50 → small r=5, big r=15. Probe between them.
        let minStep = min(rect.width / CGFloat(teethX), rect.height / CGFloat(teethY))
        let cr = minStep * 0.12
        func holeX0(_ bite: CGFloat) -> CGFloat {
            let r = minStep * bite
            let gap = (rect.width - 2 * cr - 2 * r * CGFloat(teethX)) / CGFloat(teethX + 1)
            return rect.minX + cr + gap + r
        }
        let depth: CGFloat = 8   // 5 < 8 < 15
        let small = StampShape(teethX: teethX, teethY: teethY, biteRatio: 0.10).path(in: rect)
        let big = StampShape(teethX: teethX, teethY: teethY, biteRatio: 0.30).path(in: rect)
        #expect(small.contains(CGPoint(x: holeX0(0.10), y: rect.minY + depth)))   // shallow → still solid
        #expect(!big.contains(CGPoint(x: holeX0(0.30), y: rect.minY + depth)))    // deep → bitten away
    }

    @Test func bezierPathBoundsMatchRect() {
        let bez = stampBezierPath(in: rect)
        #expect(abs(bez.bounds.width - rect.width) < 1)
        #expect(abs(bez.bounds.height - rect.height) < 1)
    }
}
