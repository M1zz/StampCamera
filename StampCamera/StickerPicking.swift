//
//  StickerPicking.swift
//  StampCamera
//
//  사진 한 장에서 스티커 여러 개.
//    · PhotoShot          찍거나 가져온 사진 한 장과, 그 안에서 찾은 대상 · 얼굴
//    · StickerProposals   그 사진으로 만들 수 있는 스티커 후보(대상 하나씩 · 모두 · 얼굴 · 사진 그대로)
//    · SubjectPickView    후보를 고르고, 없는 것은 손으로 둘러 그려 더한다
//    · EdgeEditView       오려낸 가장자리를 지우거나 되살린다
//  손으로 정한 모양은 "불투명한 곳만 남는 그림"(마스크) 하나로 다룬다 — 둘러 그린 것도, 지우개로 손본 것도.
//

import SwiftUI
import UIKit
import Vision
import CoreImage

// MARK: - 찍은 사진 한 장

struct PhotoShot {
    let raw: UIImage          // 원본 사진
    let shown: UIImage        // 고르는 화면에 보이는 그대로 (셀카는 좌우가 뒤집힌 모습)
    let size: CGSize          // `shown` 이 놓이는 자리의 크기(pt) — 카메라는 화면, 가져온 사진은 사진 비율
    let mirrored: Bool
    let map: SubjectMap?      // 사진 속 대상들
    let faces: [CGRect]       // 얼굴 자리 (0...1, 왼쪽 위 원점)

    /// 카메라로 찍은 사진: 화면(`size`)을 가득 채워 보이던 부분이 `shown` 이 된다. Vision 을 쓰니 뒤에서 부른다.
    static func make(raw: UIImage, size: CGSize, mirrored: Bool) -> PhotoShot? {
        let side = max(size.width, size.height)
        guard min(size.width, size.height) > 1,
              let shown = StampCompositor.makeStamp(from: raw, previewSize: size,
                                                    windowRect: CGRect(origin: .zero, size: size),
                                                    mirrored: mirrored, clipToShape: false,
                                                    scale: min(2, 1600 / side))?.image else { return nil }
        return PhotoShot(raw: raw, shown: shown, size: size, mirrored: mirrored,
                         map: SubjectLift.subjects(in: shown), faces: SubjectLift.faces(in: shown))
    }

    /// 사진 앱에서 가져온 사진: 사진 전체가 곧 화면이다.
    static func make(photo: UIImage) -> PhotoShot? {
        let s = photo.size
        guard s.width > 1, s.height > 1 else { return nil }
        let k = 800 / max(s.width, s.height)
        return make(raw: photo, size: CGSize(width: s.width * k, height: s.height * k), mirrored: false)
    }
}

// MARK: - 스티커 후보

struct StickerCandidate: Identifiable {
    enum Kind { case subject, everything, face, photo, drawn }
    let id: Int
    let kind: Kind
    /// 뜯을 자리 (`shown` 기준 0...1)
    let window: CGRect
    /// 대상 번호 — 사진에서 그 대상을 누르면 이 후보가 골라진다
    var label: UInt8 = 0
    /// 손으로 그린 테두리 (`shown` 기준 0...1)
    var outline: [CGPoint] = []
    var thumb: UIImage?

    /// 테두리를 뜯을 자리 기준(0...1)으로 옮긴 것.
    var outlineInWindow: [CGPoint] {
        guard window.width > 0, window.height > 0 else { return [] }
        return outline.map { CGPoint(x: ($0.x - window.minX) / window.width,
                                     y: ($0.y - window.minY) / window.height) }
    }
}

enum StickerProposals {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// 대상 자리를 조금 넉넉하게(긴 변의 5%) 넓힌다 — 가장자리가 잘리지 않게.
    static func padded(_ box: CGRect, in size: CGSize) -> CGRect {
        let pad = max(box.width * size.width, box.height * size.height) * 0.05
        return box.insetBy(dx: -pad / size.width, dy: -pad / size.height).intersection(unit)
    }

    /// 사진 한 장으로 만들 수 있는 스티커 자리들. 순서가 곧 보여 주는 순서다:
    /// 큰 대상부터 하나씩 → 모두 함께(둘 이상일 때) → 얼굴만 크게 → 사진 그대로.
    static func plan(subjects: [UInt8: CGRect], faces: [CGRect], size: CGSize,
                     photoAspect: CGFloat) -> [(kind: StickerCandidate.Kind, window: CGRect, label: UInt8)] {
        var out: [(StickerCandidate.Kind, CGRect, UInt8)] = []
        let ordered = subjects.sorted { a, b in
            let (x, y) = (a.value.width * a.value.height, b.value.width * b.value.height)
            return x != y ? x > y : a.key < b.key
        }
        for (label, box) in ordered { out.append((.subject, padded(box, in: size), label)) }
        if ordered.count > 1, let all = ordered.map(\.value).reduce(nil as CGRect?, { $0?.union($1) ?? $1 }) {
            out.append((.everything, padded(all, in: size), 0))
        }
        // 얼굴: 머리카락과 턱까지 담기게 넓힌다. 대상을 거의 다 차지하는 얼굴은 대상 후보와 겹치니 뺀다
        for face in faces.prefix(3) {
            let wide = CGRect(x: face.midX - face.width * 0.85, y: face.midY - face.height * 1.1,
                              width: face.width * 1.7, height: face.height * 2.0).intersection(unit)
            let center = CGPoint(x: face.midX, y: face.midY)
            guard let owner = ordered.first(where: { $0.value.contains(center) })?.value,
                  wide.width * wide.height < owner.width * owner.height * 0.5 else { continue }
            out.append((.face, wide, 0))
        }
        // 사진 그대로: 가운데를 우표 비율로
        let w = min(size.width * 0.72, size.height * 0.72 * photoAspect), h = w / max(photoAspect, 0.1)
        out.append((.photo, CGRect(x: (size.width - w) / 2 / size.width, y: (size.height - h) / 2 / size.height,
                                   width: w / size.width, height: h / size.height).intersection(unit), 0))
        return out
    }

    /// 후보와 그 미리보기. Vision 결과에서 그림을 만드니 뒤에서 부른다.
    static func candidates(for shot: PhotoShot) -> [StickerCandidate] {
        plan(subjects: shot.map?.boxes ?? [:], faces: shot.faces, size: shot.size,
             photoAspect: StampFrameLoader.windowAspect)
            .enumerated().map { i, p in
                var c = StickerCandidate(id: i, kind: p.kind, window: p.window, label: p.label)
                c.thumb = thumb(for: c, in: shot)
                return c
            }
    }

    /// 후보가 스티커가 되면 어떤 모습일지 — 실제로 만들 때와 같은 규칙으로 작게 그린다.
    static func thumb(for c: StickerCandidate, in shot: PhotoShot) -> UIImage? {
        guard let crop = shot.shown.cropped(unit: c.window, maxSide: 240) else { return nil }
        switch c.kind {
        case .photo:
            return crop
        case .drawn:
            return StickerMask.outline(c.outlineInWindow, size: crop.size)
                .flatMap { SubjectLift.cut(crop, mask: $0, trim: true) } ?? crop
        case .subject, .everything, .face:
            guard let part = shot.map?.cropped(to: c.window),
                  let mask = part.mask(of: Set(part.kept)) else { return crop }
            return SubjectLift.cut(crop, mask: mask, trim: true) ?? crop
        }
    }
}

// MARK: - 손으로 정한 모양 (마스크)

enum StickerMask {
    /// 테두리 안쪽만 불투명한 그림. `points` 는 조각 기준 0...1.
    static func outline(_ points: [CGPoint], size: CGSize) -> UIImage? {
        guard points.count > 2, size.width > 1, size.height > 1 else { return nil }
        let k = min(1, 700 / max(size.width, size.height))
        let s = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: s, format: fmt).image { _ in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: points[0].x * s.width, y: points[0].y * s.height))
            for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.x * s.width, y: p.y * s.height)) }
            path.close()
            UIColor.white.setFill()
            path.fill()
        }
    }

    /// 불투명한 곳이 차지한 자리 (0...1, 왼쪽 위 원점). 아무것도 없으면 nil.
    static func bounds(of mask: UIImage) -> CGRect? {
        guard let cg = mask.cgImage else { return nil }
        let k = min(1, 256 / CGFloat(max(cg.width, cg.height)))
        let w = max(Int(CGFloat(cg.width) * k), 1), h = max(Int(CGFloat(cg.height) * k), 1)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 127 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
                      width: CGFloat(maxX - minX + 1) / CGFloat(w), height: CGFloat(maxY - minY + 1) / CGFloat(h))
    }
}

extension SubjectLift {
    private static let maskContext = CIContext()

    /// 사진을 마스크의 불투명한 곳만 남기고 오려낸다. `trim` 이면 남은 곳에 맞춰 자른다.
    static func cut(_ image: UIImage, mask: UIImage, trim: Bool) -> UIImage? {
        guard let cg = image.normalizedUp().cgImage, let maskCG = mask.cgImage else { return nil }
        let src = CIImage(cgImage: cg)
        let m = CIImage(cgImage: maskCG)
        let scaled = m.transformed(by: CGAffineTransform(scaleX: src.extent.width / m.extent.width,
                                                         y: src.extent.height / m.extent.height))
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        blend.setValue(src, forKey: kCIInputImageKey)
        blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        blend.setValue(crispEdgeMask(fromAlphaOf: scaled), forKey: kCIInputMaskImageKey)
        var extent = src.extent
        if trim {
            guard let b = StickerMask.bounds(of: mask) else { return nil }
            // Core Image 는 왼쪽 아래가 원점이다
            extent = CGRect(x: b.minX * extent.width, y: (1 - b.maxY) * extent.height,
                            width: b.width * extent.width, height: b.height * extent.height)
                .insetBy(dx: -2, dy: -2).intersection(src.extent).integral
            guard extent.width > 1, extent.height > 1 else { return nil }
        }
        guard let out = blend.outputImage, let cgOut = maskContext.createCGImage(out, from: extent) else { return nil }
        return UIImage(cgImage: cgOut)
    }

    /// 자동으로 오려낸 모양을 마스크 그림으로 — 가장자리 손보기의 출발점.
    static func autoMask(of image: UIImage) -> UIImage? {
        guard let m = subjectMask(from: image),
              let cg = maskContext.createCGImage(m.applyingFilter("CIMaskToAlpha"), from: m.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 사진 속 얼굴 자리 (0...1, 왼쪽 위 원점), 큰 것부터.
    static func faces(in image: UIImage) -> [CGRect] {
        guard let cg = image.normalizedUp().cgImage else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: cg).perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY,
                          width: $0.boundingBox.width, height: $0.boundingBox.height) }
            .sorted { $0.width * $0.height > $1.width * $1.height }
    }
}

extension SubjectMap {
    /// 지도의 한 부분(0...1)만 떼어 낸 지도 — 조각 안에서 누가 남는지 따질 때 쓴다.
    func cropped(to r: CGRect) -> SubjectMap? {
        let x0 = max(Int((r.minX * CGFloat(width)).rounded(.down)), 0)
        let y0 = max(Int((r.minY * CGFloat(height)).rounded(.down)), 0)
        let x1 = min(Int((r.maxX * CGFloat(width)).rounded(.up)), width)
        let y1 = min(Int((r.maxY * CGFloat(height)).rounded(.up)), height)
        guard x1 > x0, y1 > y0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { out.append(contentsOf: labels[(y * width + x0)..<(y * width + x1)]) }
        return SubjectMap(width: x1 - x0, height: y1 - y0, labels: out)
    }
}

extension UIImage {
    /// 그림의 한 부분(0...1)을 잘라, 긴 변이 `maxSide` 를 넘지 않게 줄인다.
    func cropped(unit r: CGRect, maxSide: CGFloat) -> UIImage? {
        guard let cg = normalizedUp().cgImage else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let px = CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H)
            .integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard px.width > 1, px.height > 1, let part = cg.cropping(to: px) else { return nil }
        let k = min(1, maxSide / max(px.width, px.height))
        guard k < 1 else { return UIImage(cgImage: part) }
        let s = CGSize(width: (px.width * k).rounded(), height: (px.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: s, format: fmt).image { _ in
            UIImage(cgImage: part).draw(in: CGRect(origin: .zero, size: s))
        }
    }
}

/// `size` 비율을 지키며 `box` 안에 가득 맞춘 자리.
private func fitted(_ size: CGSize, in box: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: box) }
    let k = min(box.width / size.width, box.height / size.height)
    let w = size.width * k, h = size.height * k
    return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
}

// MARK: - 고르는 화면

/// 사진 한 장에서 스티커로 만들 것을 고른다. 아래 줄에 후보가 놓이고, 여러 개를 골라 한 번에 담는다.
/// 사진 속 대상을 눌러도 골라지고, 후보에 없는 것은 손가락으로 둘러 그려 더한다.
struct SubjectPickView: View {
    let shot: PhotoShot
    var cancelTitle: LocalizedStringKey = "다시 찍기"
    var onCollect: ([StickerCandidate]) -> Void
    var onCancel: () -> Void

    @State private var candidates: [StickerCandidate] = []
    @State private var chosen: Set<Int> = []
    @State private var mask: UIImage?
    @State private var drawing = false
    @State private var stroke: [CGPoint] = []      // 지금 그리는 선 (0...1)

    var body: some View {
        GeometryReader { geo in
            let frame = fitted(shot.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                photo(frame.size)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            Text(drawing ? "원하는 부분을 손가락으로 둘러 그려 주세요" : "스티커로 만들 것을 눌러 주세요")
                .scaledFont(15, weight: .semibold, design: .rounded)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(.top, 16).padding(.horizontal, 20)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) { tray }
        .task {
            let built = await Task.detached { StickerProposals.candidates(for: shot) }.value
            let made = await Task.detached { shot.map?.mask() }.value
            withAnimation(.easeOut(duration: 0.2)) {
                candidates = built + candidates          // 그새 그린 것이 있으면 뒤에 둔다
                mask = made
                if chosen.isEmpty, let first = built.first { chosen = [first.id] }
            }
        }
    }

    /// 사진: 대상만 밝고 나머지는 어둡다. 고른 것은 흰 테두리로 표시한다.
    private func photo(_ size: CGSize) -> some View {
        ZStack {
            Image(uiImage: shot.shown).resizable()
            Color.black.opacity(0.6)
            if let mask {
                Image(uiImage: shot.shown).resizable()
                    .mask { Image(uiImage: mask).resizable() }
            }
            // 대상이 아닌 자리(사진 그대로 · 직접 그린 것)는 고르면 그 안이 밝아진다
            let plain = candidates.filter { chosen.contains($0.id) && ($0.kind == .photo || $0.kind == .drawn) }
            if !plain.isEmpty {
                Image(uiImage: shot.shown).resizable()
                    .mask { ZStack { ForEach(plain) { marker($0, size).fill(.white) } } }
            }
            ForEach(candidates.filter { chosen.contains($0.id) }) { c in
                marker(c, size).stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            if stroke.count > 1 {
                path(stroke, size, closed: false)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [8, 7]))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard drawing else { return }
                    stroke.append(CGPoint(x: min(max(v.location.x / size.width, 0), 1),
                                          y: min(max(v.location.y / size.height, 0), 1)))
                }
                .onEnded { v in
                    if drawing {
                        finishStroke()
                    } else if abs(v.translation.width) < 12, abs(v.translation.height) < 12 {
                        tap(CGPoint(x: v.location.x / size.width, y: v.location.y / size.height))
                    }
                }
        )
    }

    private func marker(_ c: StickerCandidate, _ size: CGSize) -> Path {
        if c.kind == .drawn { return path(c.outline, size, closed: true) }
        let r = CGRect(x: c.window.minX * size.width, y: c.window.minY * size.height,
                       width: c.window.width * size.width, height: c.window.height * size.height)
        return Path(roundedRect: r, cornerRadius: 14)
    }

    private func path(_ points: [CGPoint], _ size: CGSize, closed: Bool) -> Path {
        var p = Path()
        p.addLines(points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
        if closed { p.closeSubpath() }
        return p
    }

    /// 사진 속 대상을 누르면 그 대상의 후보가 골라지거나 빠진다.
    private func tap(_ point: CGPoint) {
        guard let label = shot.map?.label(near: point), label != 0,
              let c = candidates.first(where: { $0.kind == .subject && $0.label == label }) else { return }
        toggle(c.id)
    }

    private func toggle(_ id: Int) {
        Haptics.tick()
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    /// 둘러 그린 선을 닫아 후보 하나로 더한다. 너무 작거나 짧으면 버린다.
    private func finishStroke() {
        let points = stroke
        stroke = []
        let xs = points.map(\.x), ys = points.map(\.y)
        guard points.count >= 8, let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(),
              x1 - x0 > 0.06, y1 - y0 > 0.04 else { return }
        var c = StickerCandidate(id: (candidates.map(\.id).max() ?? 0) + 1000, kind: .drawn,
                                 window: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), outline: points)
        c.thumb = StickerProposals.thumb(for: c, in: shot)
        Haptics.bounce()
        withAnimation(.easeOut(duration: 0.2)) {
            candidates.append(c)
            chosen.insert(c.id)
            drawing = false
        }
    }

    /// 아래 줄: 후보들, 그 아래 다시 찍기 · 직접 그리기 · 담기.
    private var tray: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(candidates) { c in
                        Button { toggle(c.id) } label: { cell(c) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("스티커 후보 \((candidates.firstIndex { $0.id == c.id } ?? 0) + 1)"))
                            .accessibilityAddTraits(chosen.contains(c.id) ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
            }
            HStack {
                Button(action: onCancel) { Text(cancelTitle) }
                Spacer()
                Button {
                    Haptics.tick()
                    withAnimation(.easeOut(duration: 0.15)) { drawing.toggle(); stroke = [] }
                } label: {
                    Label("직접 그리기", systemImage: "lasso")
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill(drawing ? Color.white : Color.white.opacity(0.18)))
                        .foregroundStyle(drawing ? .black : .white)
                }
                Spacer()
                Button {
                    onCollect(candidates.filter { chosen.contains($0.id) })
                } label: {
                    Text("\(chosen.count)개 담기")
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(Color.white))
                        .foregroundStyle(.black)
                }
                .disabled(chosen.isEmpty)
                .opacity(chosen.isEmpty ? 0.4 : 1)
            }
            .scaledFont(15, weight: .semibold, design: .rounded)
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
        }
        .padding(.top, 14).padding(.bottom, 24)
        .background(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)],
                                   startPoint: .top, endPoint: .center))
    }

    private func cell(_ c: StickerCandidate) -> some View {
        let on = chosen.contains(c.id)
        return ZStack(alignment: .topTrailing) {
            Group {
                if let thumb = c.thumb {
                    Image(uiImage: thumb).resizable().scaledToFit().padding(6)
                } else {
                    Image(systemName: "photo").foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 72, height: 72)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(on ? 1 : 0.2), lineWidth: on ? 2.5 : 1))
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(on ? Color.black : Color.white.opacity(0.7), on ? Color.white : Color.clear)
                .font(.system(size: 20))
                .padding(4)
        }
    }
}

// MARK: - 가장자리 손보기

/// 손보기 화면에 넘길 재료.
struct EdgeMaterial: Identifiable {
    let id = UUID()
    let photo: UIImage       // 오려내기 전 네모 조각
    let mask: UIImage?       // 지금 모양 (불투명한 곳이 남는다)
}

/// 마스크를 붓으로 고치는 판. 불투명 = 남김, 투명 = 지움.
final class MaskCanvas: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var canUndo = false
    private var ctx: CGContext?
    private var history: [CGImage] = []

    func load(size: CGSize, start: UIImage?) {
        guard ctx == nil, size.width > 1, size.height > 1 else { return }
        let k = min(1, 700 / max(size.width, size.height))
        let w = max(Int(size.width * k), 1), h = max(Int(size.height * k), 1)
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        if let cg = start?.cgImage {
            c.draw(cg, in: full)
        } else {
            c.setFillColor(UIColor.white.cgColor)
            c.fill(full)
        }
        ctx = c
        publish()
    }

    /// 붓질 하나를 시작한다 — 되돌릴 수 있게 지금 모습을 적어 둔다.
    func begin() {
        guard let snap = ctx?.makeImage() else { return }
        history.append(snap)
        if history.count > 12 { history.removeFirst() }
        canUndo = true
    }

    /// `a` → `b` (0...1, 왼쪽 위 원점)로 긋는다. `width` 는 그림 긴 변에 대한 비율.
    func line(from a: CGPoint, to b: CGPoint, width: CGFloat, erase: Bool) {
        guard let c = ctx else { return }
        let w = CGFloat(c.width), h = CGFloat(c.height)
        c.setBlendMode(erase ? .clear : .normal)
        c.setStrokeColor(UIColor.white.cgColor)
        c.setLineCap(.round)
        c.setLineWidth(width * max(w, h))
        c.move(to: CGPoint(x: a.x * w, y: (1 - a.y) * h))
        c.addLine(to: CGPoint(x: b.x * w, y: (1 - b.y) * h))
        c.strokePath()
        publish()
    }

    func undo() {
        guard let c = ctx, let last = history.popLast() else { return }
        let full = CGRect(x: 0, y: 0, width: c.width, height: c.height)
        c.setBlendMode(.copy)
        c.draw(last, in: full)
        canUndo = !history.isEmpty
        publish()
    }

    private func publish() {
        image = ctx?.makeImage().map { UIImage(cgImage: $0) }
    }
}

/// 오려낸 가장자리를 손본다: 지우기로 잘못 붙은 곳을 떼고, 되살리기로 잘린 곳을 돌려놓는다.
struct EdgeEditView: View {
    let material: EdgeMaterial
    /// 고친 모양. nil 이면 자동으로 오려낸 모양으로 되돌린다.
    var onDone: (UIImage?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var canvas = MaskCanvas()
    @State private var erasing = true
    @State private var last: CGPoint?
    private let brush: CGFloat = 0.07

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GeometryReader { geo in
                    let frame = fitted(material.photo.size, in: geo.size)
                    ZStack {
                        Image(uiImage: material.photo).resizable().opacity(0.28)
                        if let mask = canvas.image {
                            Image(uiImage: material.photo).resizable()
                                .mask { Image(uiImage: mask).resizable() }
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .background(Color(white: 0.5).opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let p = CGPoint(x: v.location.x / frame.width, y: v.location.y / frame.height)
                                if last == nil { canvas.begin() }
                                canvas.line(from: last ?? p, to: p, width: brush, erase: erasing)
                                last = p
                            }
                            .onEnded { _ in last = nil }
                    )
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                Picker("", selection: $erasing) {
                    Label("지우기", systemImage: "eraser").tag(true)
                    Label("되살리기", systemImage: "paintbrush.pointed").tag(false)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                HStack {
                    Button { canvas.undo() } label: { Label("되돌리기", systemImage: "arrow.uturn.backward") }
                        .disabled(!canvas.canUndo)
                    Spacer()
                    Button {
                        onDone(nil)
                        dismiss()
                    } label: { Label("자동으로 다시 오려내기", systemImage: "wand.and.stars") }
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(20)
            .navigationTitle("오려낸 가장자리 손보기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        onDone(canvas.image)
                        dismiss()
                    }
                }
            }
            .onAppear { canvas.load(size: material.photo.size, start: material.mask) }
        }
    }
}
