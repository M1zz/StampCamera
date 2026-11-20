//
//  ZoomControl.swift
//  StampCamera
//
//  카메라 줌. 평소에는 배율 단추(0.5 · 1× · 2 …)만 보인다.
//  단추를 길게 누르면 각도기 같은 다이얼이 펴지고, 누른 채 좌우로 밀어 배율을 맞춘다.
//  손을 떼면 다이얼은 잠시 뒤 접힌다.
//

import SwiftUI

/// 배율 ↔ 다이얼 위 자리(0...1). 로그 눈금이라 0.5→1 과 1→2 가 같은 거리다.
struct ZoomScale {
    let min: CGFloat
    let max: CGFloat

    func position(of zoom: CGFloat) -> CGFloat {
        let lo = log(Double(Swift.max(min, 0.01))), hi = log(Double(Swift.max(max, min + 0.01)))
        guard hi > lo else { return 0 }
        return CGFloat(Swift.min(1, Swift.max(0, (log(Double(Swift.max(zoom, 0.01))) - lo) / (hi - lo))))
    }

    func zoom(at position: CGFloat) -> CGFloat {
        let lo = log(Double(Swift.max(min, 0.01))), hi = log(Double(Swift.max(max, min + 0.01)))
        return CGFloat(exp(lo + Double(Swift.min(1, Swift.max(0, position))) * (hi - lo)))
    }

    /// 배율 단추 가운데 지금 켜진 것: 지금 배율보다 크지 않은 가장 큰 칸.
    static func activeStop(_ stops: [CGFloat], zoom: CGFloat) -> CGFloat? {
        let sorted = stops.sorted()
        return sorted.last { $0 <= zoom + 0.01 } ?? sorted.first
    }

    static func label(_ zoom: CGFloat) -> String {
        abs(zoom - zoom.rounded()) < 0.05 ? "\(Int(zoom.rounded()))" : String(format: "%.1f", zoom)
    }
}

struct ZoomControl: View {
    @ObservedObject var camera: CameraManager

    @State private var dialing = false
    @State private var base: CGFloat?          // 밀기 시작할 때의 배율
    @State private var hideToken = 0
    @State private var lastTick: CGFloat = .nan

    private var scale: ZoomScale { ZoomScale(min: camera.minZoom, max: camera.maxZoom) }
    /// 이만큼 밀면 가장 넓은 배율에서 가장 좁은 배율까지 간다
    private let travel: CGFloat = 320

    var body: some View {
        VStack(spacing: 8) {
            if dialing {
                ZoomDial(zoom: camera.zoom, stops: camera.zoomStops, scale: scale)
                    .frame(height: 78)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { scrub($0.translation.width) }
                        .onEnded { _ in release() })
                    .transition(.opacity.combined(with: .offset(y: 16)))
            }
            chips
        }
        .accessibilityElement()
        .accessibilityLabel("줌")
        .accessibilityValue("\(ZoomScale.label(camera.zoom))×")
        .accessibilityAdjustableAction { direction in
            let stops = camera.zoomStops.sorted()
            let z = camera.zoom
            let next = direction == .increment
                ? stops.first { $0 > z + 0.01 } ?? min(camera.maxZoom, z * 1.5)
                : stops.last { $0 < z - 0.01 } ?? max(camera.minZoom, z / 1.5)
            camera.setZoom(next)
        }
    }

    /// 배율 단추. 누르면 그 배율로, 길게 누르면 다이얼이 펴진다.
    private var chips: some View {
        let active = ZoomScale.activeStop(camera.zoomStops, zoom: camera.zoom)
        return HStack(spacing: 6) {
            ForEach(camera.zoomStops.sorted(), id: \.self) { stop in
                let on = stop == active
                Text(on ? "\(ZoomScale.label(camera.zoom))×" : ZoomScale.label(stop))
                    .font(.system(size: on ? 13 : 12, weight: .bold, design: .rounded))
                    .foregroundStyle(on ? Color.yellow : Color.white)
                    .frame(width: on ? 42 : 32, height: on ? 42 : 32)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .contentShape(Circle())
                    .onTapGesture {
                        Haptics.tick()
                        withAnimation(.easeOut(duration: 0.2)) { camera.setZoom(stop) }
                    }
            }
        }
        .padding(5)
        .background(Capsule().fill(.black.opacity(0.25)))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    if !dialing {
                        Haptics.bounce()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dialing = true }
                    }
                    scrub(drag?.translation.width ?? 0)
                }
                .onEnded { _ in release() }
        )
        .animation(.easeOut(duration: 0.15), value: active)
    }

    /// 누른 채 민 만큼 배율을 바꾼다. 왼쪽으로 밀면 당겨 찍는다(기본 카메라와 같다).
    private func scrub(_ dx: CGFloat) {
        hideToken += 1
        if base == nil { base = camera.zoom }
        guard let base else { return }
        let z = scale.zoom(at: scale.position(of: base) - dx / travel)
        // 배율 칸을 지날 때마다 톡
        if let near = camera.zoomStops.first(where: { abs(scale.position(of: $0) - scale.position(of: z)) < 0.012 }) {
            if near != lastTick { Haptics.tick(); lastTick = near }
            camera.setZoom(near)
        } else {
            lastTick = .nan
            camera.setZoom(z)
        }
    }

    private func release() {
        base = nil
        lastTick = .nan
        hideToken += 1
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard hideToken == token else { return }
            withAnimation(.easeOut(duration: 0.25)) { dialing = false }
        }
    }
}

/// 각도기 모양 다이얼: 큰 원의 윗부분만 보이고, 배율이 바뀌면 눈금이 돈다. 가운데 노란 금이 지금 배율이다.
private struct ZoomDial: View {
    let zoom: CGFloat
    let stops: [CGFloat]
    let scale: ZoomScale
    private let sweep: CGFloat = 110        // 가장 넓은 배율에서 가장 좁은 배율까지 도는 각도

    var body: some View {
        Canvas { ctx, size in
            let radius = size.width * 0.72
            let center = CGPoint(x: size.width / 2, y: radius + 6)
            let here = scale.position(of: zoom)
            func point(_ t: CGFloat, _ r: CGFloat) -> CGPoint {
                let a = (t - here) * sweep * .pi / 180
                return CGPoint(x: center.x + r * sin(a), y: center.y - r * cos(a))
            }
            // 바탕 띠
            var band = Path()
            band.addArc(center: center, radius: radius - 26, startAngle: .degrees(180), endAngle: .degrees(360),
                        clockwise: false)
            ctx.stroke(band, with: .color(.black.opacity(0.5)), lineWidth: 58)
            // 잔 눈금
            for i in 0...60 {
                let t = CGFloat(i) / 60
                var tick = Path()
                tick.move(to: point(t, radius))
                tick.addLine(to: point(t, radius - 7))
                ctx.stroke(tick, with: .color(.white.opacity(0.45)), lineWidth: 1)
            }
            // 배율 칸: 굵은 눈금과 숫자
            for stop in stops {
                let t = scale.position(of: stop)
                var tick = Path()
                tick.move(to: point(t, radius))
                tick.addLine(to: point(t, radius - 13))
                ctx.stroke(tick, with: .color(.white), lineWidth: 2)
                ctx.draw(Text(ZoomScale.label(stop))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white), at: point(t, radius - 28))
            }
            // 지금 배율
            var needle = Path()
            needle.move(to: CGPoint(x: center.x, y: center.y - radius - 4))
            needle.addLine(to: CGPoint(x: center.x, y: center.y - radius + 18))
            ctx.stroke(needle, with: .color(.yellow), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            ctx.draw(Text("\(ZoomScale.label(zoom))×")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundColor(.yellow), at: CGPoint(x: center.x, y: center.y - radius + 50))
        }
        .clipped()
        .allowsHitTesting(true)
    }
}
