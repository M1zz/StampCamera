//
//  PuncherFrameView.swift
//  StampCamera
//
//  The on-screen punch frame, styled after the reference image:
//  pastel-blue plastic body, brushed-metal tray, scalloped stamp window,
//  corner gears, ruler ticks, and a tiny center lens.
//
//  `windowRect(in:)` reports the exact stamp-window frame in the overlay's
//  coordinate space so the compositor can crop the photo to match.
//

import SwiftUI

struct PuncherFrameView: View {
    /// Fraction of the available width the whole puncher occupies.
    var widthFraction: CGFloat = 0.78
    var teethX: Int = 9
    var teethY: Int = 12

    /// Reports the stamp window rect (the transparent opening) in the
    /// coordinate space of the given container size.
    static func windowRect(in containerSize: CGSize, widthFraction: CGFloat) -> CGRect {
        let bodyW = containerSize.width * widthFraction
        let bodyH = bodyW * 4.0 / 3.0
        // window inset inside the plastic + metal tray (tuned to the reference)
        let inset = bodyW * 0.20
        let winW = bodyW - inset * 2
        let winH = bodyH - inset * 2
        let cx = containerSize.width / 2
        let cy = containerSize.height / 2
        return CGRect(x: cx - winW / 2, y: cy - winH / 2, width: winW, height: winH)
    }

    var body: some View {
        GeometryReader { geo in
            let bodyW = geo.size.width * widthFraction
            let bodyH = bodyW * 4.0 / 3.0
            let win = Self.windowRect(in: geo.size, widthFraction: widthFraction)

            ZStack {
                // ---- pastel-blue plastic body with the stamp window knocked out ----
                RoundedRectangle(cornerRadius: bodyW * 0.16, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color(hex: 0xD8E6F2), Color(hex: 0xAFC9E0)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: bodyW, height: bodyH)
                    .overlay(
                        RoundedRectangle(cornerRadius: bodyW * 0.16, style: .continuous)
                            .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
                    )
                    // punch the metal tray + stamp hole
                    .overlay(metalTray(win: win, bodyW: bodyW))
                    .compositingGroup()
                    .mask(
                        // body minus stamp hole, so the live camera shows through
                        ZStack {
                            RoundedRectangle(cornerRadius: bodyW * 0.16, style: .continuous)
                                .frame(width: bodyW, height: bodyH)
                            StampShape(teethX: teethX, teethY: teethY)
                                .path(in: win)
                                .fill(style: FillStyle(eoFill: true))
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    )
                    .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 14)

                // ---- scallop highlight outline around the window ----
                StampShape(teethX: teethX, teethY: teethY)
                    .path(in: win)
                    .stroke(Color.white.opacity(0.6), lineWidth: 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // Brushed-metal tray + gears + ruler ticks + center lens
    private func metalTray(win: CGRect, bodyW: CGFloat) -> some View {
        let trayInset = bodyW * 0.10
        let trayRect = win.insetBy(dx: -trayInset, dy: -trayInset)
        return ZStack {
            RoundedRectangle(cornerRadius: bodyW * 0.05, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(hex: 0xE2E5E9), Color(hex: 0x9DA2A8)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: trayRect.width, height: trayRect.height)
                .position(x: trayRect.midX, y: trayRect.midY)
                .overlay(
                    RoundedRectangle(cornerRadius: bodyW * 0.05)
                        .stroke(Color.black.opacity(0.2), lineWidth: 1)
                        .frame(width: trayRect.width, height: trayRect.height)
                        .position(x: trayRect.midX, y: trayRect.midY)
                )

            // ruler ticks along the top inner edge
            HStack(spacing: 4) {
                ForEach(0..<24, id: \.self) { i in
                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: 1, height: i % 4 == 0 ? 9 : 5)
                }
            }
            .position(x: win.midX, y: win.minY - 12)

            // corner gears
            ForEach(Array(corners(of: trayRect).enumerated()), id: \.offset) { _, pt in
                GearView()
                    .frame(width: bodyW * 0.10, height: bodyW * 0.10)
                    .position(pt)
            }

            // tiny center lens at bottom of window
            ZStack {
                Circle().fill(
                    RadialGradient(colors: [Color(hex: 0x5A6068), .black],
                                   center: .center, startRadius: 1, endRadius: bodyW * 0.05))
                Circle().stroke(Color(hex: 0xC8CCD0), lineWidth: 2)
            }
            .frame(width: bodyW * 0.10, height: bodyW * 0.10)
            .position(x: win.midX, y: win.maxY - bodyW * 0.06)
        }
    }

    private func corners(of r: CGRect) -> [CGPoint] {
        let pad = r.width * 0.06
        return [
            CGPoint(x: r.minX + pad, y: r.minY + pad),
            CGPoint(x: r.maxX - pad, y: r.minY + pad),
            CGPoint(x: r.minX + pad, y: r.maxY - pad),
            CGPoint(x: r.maxX - pad, y: r.maxY - pad)
        ]
    }
}

// Small decorative gear
private struct GearView: View {
    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            ZStack {
                ForEach(0..<10, id: \.self) { i in
                    Rectangle()
                        .fill(Color(hex: 0x8B9097))
                        .frame(width: r * 0.3, height: r * 0.5)
                        .offset(y: -r)
                        .rotationEffect(.degrees(Double(i) * 36))
                }
                Circle().fill(
                    LinearGradient(colors: [Color(hex: 0xC9CDD2), Color(hex: 0x7E848B)],
                                   startPoint: .top, endPoint: .bottom))
                    .frame(width: r * 1.4, height: r * 1.4)
                Circle().fill(Color(hex: 0x5C616A))
                    .frame(width: r * 0.5, height: r * 0.5)
            }
            .position(c)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
