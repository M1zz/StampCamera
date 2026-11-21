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
    let raw: UIImage          // 원본 사진 (방향을 바로 세운 것)
    let shown: UIImage        // 고르는 화면에 보이는 그대로 (셀카는 좌우가 뒤집힌 모습)
    let size: CGSize          // `shown` 이 놓이는 자리의 크기(pt) — 카메라는 화면, 가져온 사진은 사진 비율
    let mirrored: Bool
    let map: SubjectMap?      // 사진 속 대상들
    let faces: [CGRect]       // 얼굴 자리 (0...1, 왼쪽 위 원점)

    /// 카메라로 찍은 사진: 화면(`size`)을 가득 채워 보이던 부분이 `shown` 이 된다. Vision 을 쓰니 뒤에서 부른다.
    static func make(raw original: UIImage, size: CGSize, mirrored: Bool) -> PhotoShot? {
        // 방향은 여기서 한 번만 바로 세운다 — 자를 때마다 12MP 를 다시 그리지 않게
        let raw = original.normalizedUp()
        let side = max(size.width, size.height)
        guard min(size.width, size.height) > 1,
              let shown = StampCompositor.makeStamp(from: raw, previewSize: size,
                                                    windowRect: CGRect(origin: .zero, size: size),
                                                    mirrored: mirrored, clipToShape: false,
                                                    scale: min(2, 1600 / side))?.image else { return nil }
        return PhotoShot(raw: raw, shown: shown, size: size, mirrored: mirrored,
                         map: SubjectLift.subjects(in: shown)?.atomic, faces: SubjectLift.faces(in: shown))
    }

    /// 사진 앱에서 가져온 사진: 사진 전체가 곧 화면이다.
    static func make(photo: UIImage) -> PhotoShot? {
        let s = photo.size
        guard s.width > 1, s.height > 1 else { return nil }
        let k = 800 / max(s.width, s.height)
        return make(raw: photo, size: CGSize(width: s.width * k, height: s.height * k), mirrored: false)
    }

    /// 스티커 한 장의 긴 변(픽셀). 원본이 이보다 작으면 원본 그대로 — 늘리지 않는다.
    static let stickerSide: CGFloat = 1200

    /// 원본 사진에서 `window`(`shown` 기준 0...1) 자리를 원본 해상도로 자른다. 긴 변은 `longSide` 까지.
    /// 화면 크기가 아니라 원본 픽셀을 기준으로 하므로, 작은 대상도 원본에 담긴 만큼 또렷하다.
    func crop(_ window: CGRect, longSide: CGFloat = PhotoShot.stickerSide) -> (image: UIImage, cropNorm: CGRect)? {
        let win = CGRect(x: window.minX * size.width, y: window.minY * size.height,
                         width: window.width * size.width, height: window.height * size.height)
        let side = max(win.width, win.height)
        let px = CGSize(width: raw.size.width * raw.scale, height: raw.size.height * raw.scale)
        guard side > 1, px.width > 0, px.height > 0 else { return nil }
        // 화면 1pt 에 원본 몇 px 이 들어가는지 (makeStamp 와 같은 aspect-fill 셈)
        let pxPerPoint = 1 / max(size.width / px.width, size.height / px.height)
        return StampCompositor.makeStamp(from: raw, previewSize: size, windowRect: win, mirrored: mirrored,
                                         clipToShape: false, scale: min(pxPerPoint, longSide / side))
    }
}

// MARK: - 자동 태그

/// 스티커에 무엇이 담겼는지 알아보고 태그를 단다. 태그는 그냥 글자라, 사용자가 떼거나 더 달 수 있다.
enum StickerTagger {
    static var person: String { String(localized: "사람") }

    static func tags(for image: UIImage) -> [String] {
        guard let cg = image.normalizedUp().cgImage else { return [] }
        let request = VNClassifyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: cg).perform([request])) != nil else { return [] }
        return tags(from: Set((request.results ?? []).filter { $0.confidence >= 0.3 }.map(\.identifier)))
    }

    /// Vision 이 알아본 이름들 → 태그 (많아야 둘). 가장 뚜렷이 가르는 것부터.
    static func tags(from seen: Set<String>) -> [String] {
        var out: [String] = []
        if !seen.isDisjoint(with: ["people", "adult", "child", "baby"]) { out.append(person) }
        if seen.contains("dog") { out.append(String(localized: "강아지")) }
        else if seen.contains("cat") { out.append(String(localized: "고양이")) }
        else if !seen.isDisjoint(with: ["animal", "bird"]) { out.append(String(localized: "동물")) }
        if !seen.isDisjoint(with: ["food", "fruit", "dessert", "drink"]) { out.append(String(localized: "음식")) }
        if !seen.isDisjoint(with: ["flower", "plant", "tree"]) { out.append(String(localized: "식물")) }
        if !seen.isDisjoint(with: ["vehicle", "car"]) { out.append(String(localized: "탈것")) }
        return Array(out.prefix(2))
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
    /// 둘러 그린 영역 안에서 딴 모양 (뜯을 자리 기준, 불투명한 곳이 남는다) — 사진 위에서도 이 모양대로 밝아진다
    var mask: UIImage?
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

    /// 사진 한 장으로 만들 수 있는 스티커 자리들 — 알아본 것을 하나씩 따로:
    /// 큰 대상부터 하나씩 → 얼굴만 크게. 아무것도 못 알아봤을 때만 사진 그대로.
    static func plan(subjects: [UInt8: CGRect], faces: [CGRect], size: CGSize,
                     photoAspect: CGFloat) -> [(kind: StickerCandidate.Kind, window: CGRect, label: UInt8)] {
        var out: [(StickerCandidate.Kind, CGRect, UInt8)] = []
        let ordered = subjects.sorted { a, b in
            let (x, y) = (a.value.width * a.value.height, b.value.width * b.value.height)
            return x != y ? x > y : a.key < b.key
        }
        for (label, box) in ordered { out.append((.subject, padded(box, in: size), label)) }
        // 얼굴: 머리카락과 턱까지 담기게 넓힌다. 대상을 거의 다 차지하는 얼굴은 대상 후보와 겹치니 뺀다
        for face in faces.prefix(6) {
            let wide = CGRect(x: face.midX - face.width * 0.85, y: face.midY - face.height * 1.1,
                              width: face.width * 1.7, height: face.height * 2.0).intersection(unit)
            let center = CGPoint(x: face.midX, y: face.midY)
            guard let owner = ordered.first(where: { $0.value.contains(center) })?.value,
                  wide.width * wide.height < owner.width * owner.height * 0.5 else { continue }
            out.append((.face, wide, 0))
        }
        guard out.isEmpty else { return out }
        // 사진 그대로: 가운데를 우표 비율로
        let w = min(size.width * 0.72, size.height * 0.72 * photoAspect), h = w / max(photoAspect, 0.1)
        out.append((.photo, CGRect(x: (size.width - w) / 2 / size.width, y: (size.height - h) / 2 / size.height,
                                   width: w / size.width, height: h / size.height).intersection(unit), 0))
        return out
    }

    /// 후보와 그 미리보기. Vision 결과에서 그림을 만드니 뒤에서 부른다.
    static func candidates(for shot: PhotoShot, cutout: Bool = true) -> [StickerCandidate] {
        plan(subjects: shot.map?.boxes ?? [:], faces: shot.faces, size: shot.size,
             photoAspect: StampFrameLoader.windowAspect)
            .enumerated().map { i, p in
                var c = StickerCandidate(id: i, kind: p.kind, window: p.window, label: p.label)
                c.thumb = thumb(for: c, in: shot, cutout: cutout)
                return c
            }
    }

    /// 후보가 스티커가 되면 어떤 모습일지 — 실제로 만들 때와 같은 규칙으로 그린다.
    /// `cutout` 이 아니면(기본 모양이 우표) 우표 모양으로. 크게 그릴 때는 실제와 똑같이 다시 오려낸다.
    static func thumb(for c: StickerCandidate, in shot: PhotoShot,
                      cutout: Bool = true, maxSide: CGFloat = 240) -> UIImage? {
        // 아래 줄의 작은 그림은 화면용 사진에서, 가운데 큰 그림은 원본에서 자른다
        let source = maxSide > 400 ? shot.crop(c.window, longSide: maxSide)?.image
                                   : shot.shown.cropped(unit: c.window, maxSide: maxSide)
        guard let crop = source else { return nil }
        switch c.kind {
        case .drawn:
            return (c.mask ?? StickerMask.refine(c.outlineInWindow, in: crop))
                .flatMap { SubjectLift.cut(crop, mask: $0, trim: true) } ?? crop
        case .subject, .everything, .face:
            guard cutout else { return CollectionStore.stampShaped(crop) }
            if maxSide > 400, let cut = SubjectLift.cutout(from: crop) { return cut }
            guard let part = shot.map?.cropped(to: c.window),
                  let mask = part.mask(of: Set(part.kept)),
                  let cut = SubjectLift.cut(crop, mask: mask, trim: true) else {
                return CollectionStore.stampShaped(crop)       // 오려낼 대상이 없으면 우표 모양
            }
            return cut
        case .photo:
            return CollectionStore.stampShaped(crop)
        }
    }

    /// 후보가 움직이는 스티커가 되면 어떤 모습일지 — 고르는 화면에서 바로 움직여 보인다.
    static func clip(for c: StickerCandidate, in shot: PhotoShot, frames: [UIImage], cutout: Bool) -> [UIImage] {
        let win = CGRect(x: c.window.minX * shot.size.width, y: c.window.minY * shot.size.height,
                         width: c.window.width * shot.size.width, height: c.window.height * shot.size.height)
        let side = max(win.width, win.height)
        guard side > 1 else { return [] }
        let master = frames.compactMap {
            StampCompositor.makeStamp(from: $0, previewSize: shot.size, windowRect: win, mirrored: shot.mirrored,
                                      clipToShape: false, scale: min(1.2, 420 / side))?.image
        }
        guard master.count > 1 else { return [] }
        switch c.kind {
        case .photo:
            return CollectionStore.clipLook(master, style: .liveStamp)
        case .drawn:
            // 모양은 첫 장에서 한 번 정하고 모든 장에 같게 — 테두리는 그대로, 안의 장면만 움직인다
            return CollectionStore.clipLook(master, style: .liveSticker,
                                            mask: StickerMask.refine(c.outlineInWindow, in: master[0]))
        case .subject, .everything, .face:
            return CollectionStore.clipLook(master, style: cutout ? .liveSticker : .liveStamp)
        }
    }
}

// MARK: - 손떨림 보정

/// 움직이는 스티커의 손떨림을 잡는다. 모든 장을 가운데 장에 맞춰 옮겨, 스티커는 제자리에 있고
/// 안의 대상만 움직이게 한다. 장면이 통째로 밀린 만큼만 되돌리므로 대상의 움직임은 그대로 남는다.
enum Stabilizer {
    /// 이보다 크게 밀린 장은 흔들림이 아니라 카메라를 옮긴 것으로 보고 손대지 않는다 (긴 변에 대한 비율)
    static let maxShift: CGFloat = 0.08

    static func steady(_ frames: [UIImage]) -> [UIImage] {
        guard frames.count > 2 else { return frames }
        let reference = frames[frames.count / 2]
        guard let ref = small(reference) else { return frames }
        return frames.map { frame in
            guard frame !== reference, let cg = frame.normalizedUp().cgImage, let target = small(frame),
                  let shift = offset(of: target, to: ref) else { return frame }
            let k = CGFloat(cg.width) / CGFloat(target.width)
            return shifted(cg, dx: shift.x * k, dy: shift.y * k) ?? frame
        }
    }

    /// `image` 를 `reference` 에 겹치려면 옮길 거리 (CoreGraphics 좌표 — 왼쪽 아래 원점, 위가 +y).
    /// Vision 의 정렬 값이 이 좌표계라 그대로 쓴다. 너무 크면(카메라를 옮겼다) nil.
    static func offset(of image: CGImage, to reference: CGImage) -> CGPoint? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: image)
        guard (try? VNImageRequestHandler(cgImage: reference).perform([request])) != nil,
              let t = (request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform
        else { return nil }
        let limit = CGFloat(max(reference.width, reference.height)) * maxShift
        guard abs(t.tx) <= limit, abs(t.ty) <= limit else { return nil }
        return CGPoint(x: t.tx, y: t.ty)
    }

    /// 정렬은 작게 줄인 그림으로 한다 — 빠르고, 잔떨림보다 장면 전체의 밀림을 본다.
    private static func small(_ image: UIImage) -> CGImage? {
        image.cropped(unit: StickerProposals.unit, maxSide: 320)?.cgImage
    }

    /// 옮겨 그린다. 옮기며 드러난 가장자리는 원래 장으로 메워 빈 띠가 생기지 않게 한다.
    static func shifted(_ cg: CGImage, dx: CGFloat, dy: CGFloat) -> UIImage? {
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        ctx.draw(cg, in: full)
        ctx.draw(cg, in: full.offsetBy(dx: dx.rounded(), dy: dy.rounded()))
        return ctx.makeImage().map { UIImage(cgImage: $0) }
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

extension StickerMask {
    /// 손가락 길이 끝이 처음 자리로 돌아와 도형을 이루었는지 (`points` 는 화면 점 단위).
    /// 짧게 긋거나 쓸어 넘긴 것은 도형으로 치지 않는다.
    static func closesLoop(_ points: [CGPoint]) -> Bool {
        guard points.count >= 8, let first = points.first, let last = points.last else { return false }
        let xs = points.map(\.x), ys = points.map(\.y)
        let w = (xs.max() ?? 0) - (xs.min() ?? 0), h = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard w >= 36, h >= 36 else { return false }
        let gap = hypot(last.x - first.x, last.y - first.y)
        return gap <= max(44, min(w, h) * 0.35)
    }

    /// 둘러 그린 테두리 둘레에 남겨 두는 여유 — 대상이 테두리 밖으로 조금 삐져나가도 통째로 담기게.
    static func room(around box: CGRect) -> CGRect {
        box.insetBy(dx: -box.width * 0.15, dy: -box.height * 0.15).intersection(StickerProposals.unit)
    }

    /// 둘러 그린 테두리 안에서 대상을 찾아 그 대상만 남기는 모양. 대상이 없으면 그린 모양 그대로.
    /// `points` 는 `image` 기준 0...1. Vision 을 쓰니 뒤에서 부른다.
    static func refine(_ points: [CGPoint], in image: UIImage) -> UIImage? {
        if let map = SubjectLift.subjects(in: image), let mask = refine(points, map: map) { return mask }
        return outline(points, size: image.size)
    }

    /// 대상 지도 위에서 고른다:
    ///  · 대상이 거의(60% 넘게) 테두리 안이면 그 대상을 통째로 — 테두리를 대충 그려도 잘리지 않는다
    ///  · 대상의 일부만 둘렀으면 그 부분만 — 대상의 가장자리를 따라 오리고, 테두리 쪽은 그린 대로 자른다
    ///  · 테두리 안에 대상이 거의 없으면 nil (그린 모양 그대로 쓴다)
    static func refine(_ points: [CGPoint], map: SubjectMap) -> UIImage? {
        guard let inside = coverage(points, width: map.width, height: map.height) else { return nil }
        let lasso = inside.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard lasso > 0 else { return nil }
        var total = [Int](repeating: 0, count: 256), within = total
        for (i, l) in map.labels.enumerated() where l != 0 {
            total[Int(l)] += 1
            if inside[i] { within[Int(l)] += 1 }
        }
        var whole = Set<UInt8>(), part = Set<UInt8>()
        for l in map.boxes.keys where within[Int(l)] * 30 >= lasso {          // 테두리 안의 3% 넘게 차지한 대상만
            if within[Int(l)] * 10 >= total[Int(l)] * 6 { whole.insert(l) } else { part.insert(l) }
        }
        guard !whole.isEmpty || !part.isEmpty else { return nil }
        return image(width: map.width, height: map.height) { i in
            let l = map.labels[i]
            return whole.contains(l) || (part.contains(l) && inside[i])
        }
    }

    /// 테두리 안쪽인 점들 (왼쪽 위부터 한 줄씩).
    static func coverage(_ points: [CGPoint], width: Int, height: Int) -> [Bool]? {
        guard points.count > 2, width > 0, height > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // 메모리의 첫 줄이 그림의 맨 위다 — y 를 뒤집어 그린다
            let w = CGFloat(width), h = CGFloat(height)
            ctx.move(to: CGPoint(x: points[0].x * w, y: (1 - points[0].y) * h))
            for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x * w, y: (1 - p.y) * h)) }
            ctx.closePath()
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fillPath()
            return true
        }
        return drawn ? px.map { $0 > 127 } : nil
    }

    /// 남길 점만 불투명한 그림.
    static func image(width: Int, height: Int, keep: (Int) -> Bool) -> UIImage? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) where keep(i) {
            px[i * 4] = 255; px[i * 4 + 1] = 255; px[i * 4 + 2] = 255; px[i * 4 + 3] = 255
        }
        return px.withUnsafeMutableBytes { raw -> UIImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = ctx.makeImage() else { return nil }
            return UIImage(cgImage: cg)
        }
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
/// 고른 것은 가운데에 스티커 모습 그대로 크게 뜬다(움직임을 켜면 움직인다).
/// 사진 속 대상을 눌러도 골라지고, 후보에 없는 것은 손가락으로 둘러 그려 더한다.
struct SubjectPickView: View {
    let shot: PhotoShot
    var cancelTitle: LocalizedStringKey = "다시 찍기"
    /// 오려낸 스티커로 보이고 담긴다 (시험에서만 끈다)
    var cutout = true
    /// 함께 찍힌 움직임을 가져오는 길. 없으면(가져온 사진) 움직임 단추가 없다.
    /// 처음에는 언제나 멈춘 스티커다 — 움직임 단추를 켰을 때만 움직이는 스티커가 된다
    var motion: (() -> (frames: [UIImage], seconds: Double)?)? = nil
    var onCollect: (_ picks: [StickerCandidate], _ moving: Bool) -> Void
    var onCancel: () -> Void

    @State private var candidates: [StickerCandidate] = []
    @State private var chosen: Set<Int> = []
    @State private var mask: UIImage?               // 고른 대상 (빛나는 테두리)
    @State private var everyone: UIImage?           // 알아본 대상 모두 (밝게)
    @State private var stroke: [CGPoint] = []      // 지금 그리는 선 (0...1)
    @State private var glow = false                 // 밝은 대상의 테두리가 숨 쉬듯 빛난다
    // 아래 줄에서 누른 스티커는 가운데에 크게 보인다
    @State private var focus: Int?
    @State private var previews: [Int: UIImage] = [:]
    // 움직임을 켜면 고른 스티커마다 움직이는 모습을 만든다
    @State private var clips: [Int: [UIImage]] = [:]
    @State private var making: Set<Int> = []
    @State private var clipDelay = 0.08
    @State private var moving = false
    @State private var waits = 0
    // 담기: 고른 스티커가 하나씩 뿅 튀어 올라 수집함으로 날아간다
    @State private var saving = false
    @State private var popped: Set<Int> = []
    @State private var flown: Set<Int> = []
    // 둘러 그리기 알려 주기: 한 번이라도 그려 보기 전까지, 빈 자리에서 손가락이 동그라미를 그려 보인다
    @AppStorage("pickDrawLearned") private var drawLearned = false
    @State private var nudgeSpot: CGPoint?
    // 필요 없는 것 지우기: 동그라미를 끌어 휴지통에 놓는다
    @State private var dragging: Int?
    @State private var dragPoint: CGPoint = .zero
    @State private var sinking = false              // 휴지통으로 스르르 빨려 드는 중
    @State private var born: Int?                   // 막 둘러 그려 생긴 후보 — 반짝 하고 나타난다

    private static let clipQueue = DispatchQueue(label: "com.devkoan.StampCamera.pickClips", qos: .userInitiated)

    private var picks: [StickerCandidate] { candidates.filter { chosen.contains($0.id) } }

    var body: some View {
        GeometryReader { geo in
            let frame = fitted(shot.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                photo(frame.size)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                if saving {
                    flying(frame, in: geo.size)
                } else {
                    badges(frame, trash: trashSpot(geo.size))
                    if stroke.isEmpty, dragging == nil, let c = candidates.first(where: { $0.id == focus }) {
                        Color.black.opacity(0.5)
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { focus = nil } }
                        spotlight(c, in: geo.size)
                    }
                    if let id = dragging, let c = candidates.first(where: { $0.id == id }) {
                        trashCan(at: trashSpot(geo.size))
                        carried(c)
                    }
                }
            }
            .coordinateSpace(name: "pick")
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            Label("밝은 것을 누르거나, 원하는 곳을 손가락으로 둘러 그려 보세요", systemImage: "hand.draw")
                .scaledFont(15, weight: .semibold, design: .rounded)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(.top, 16).padding(.horizontal, 20)
                .allowsHitTesting(false)
                .opacity(saving ? 0 : 1)
        }
        .overlay(alignment: .bottom) {
            tray.opacity(saving || dragging != nil ? 0 : 1).allowsHitTesting(!saving && dragging == nil)
        }
        .task {
            let built = await Task.detached { StickerProposals.candidates(for: shot, cutout: cutout) }.value
            withAnimation(.easeOut(duration: 0.2)) {
                candidates = built + candidates          // 그새 그린 것이 있으면 뒤에 둔다
                if chosen.isEmpty, built.count == 1 { chosen = [built[0].id] }   // 하나뿐이면 고를 것도 없다
            }
            guard !drawLearned else { return }
            let spot = emptySpot()
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard stroke.isEmpty, !saving else { return }
            withAnimation(.easeOut(duration: 0.3)) { nudgeSpot = spot }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            withAnimation(.easeOut(duration: 0.4)) { nudgeSpot = nil }
        }
        .task {
            guard let map = shot.map else { return }
            let all = await Task.detached { map.mask(of: nil) }.value
            withAnimation(.easeOut(duration: 0.2)) { everyone = all }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { glow = true }
        }
        .onChange(of: chosen) { _, _ in refreshMask(); prepare() }
        .onChange(of: focus) { _, _ in prepare() }
        .onChange(of: moving) { _, _ in waits = 0; prepare() }
    }

    /// 알아본 것마다 붙는 동그라미. 누르면 초록 V 로 골라지고, 다시 누르면 빠진다.
    /// 끌어서 휴지통에 놓으면 그 후보가 사라진다 (테두리도 함께).
    private func badges(_ frame: CGRect, trash: CGPoint) -> some View {
        ForEach(candidates) { c in
            let on = chosen.contains(c.id)
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, on ? Color.green : Color.clear)
                .font(.system(size: 26, weight: .semibold))
                .shadow(color: .black.opacity(0.55), radius: 3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .opacity(dragging == c.id ? 0 : 1)
                .onTapGesture { toggle(c.id) }
                .gesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("pick"))
                        .onChanged { v in
                            guard !sinking else { return }
                            if dragging == nil {
                                Haptics.tick()
                                withAnimation(.easeOut(duration: 0.15)) { dragging = c.id; focus = nil; nudgeSpot = nil }
                            }
                            let was = overTrash(dragPoint, trash)
                            dragPoint = v.location
                            if overTrash(v.location, trash) != was { Haptics.tick() }
                        }
                        .onEnded { v in
                            guard !sinking else { return }
                            if overTrash(v.location, trash) {
                                sink(c.id, into: trash)
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragging = nil }
                            }
                        }
                )
                .position(x: min(max(frame.minX + c.window.maxX * frame.width - 16, frame.minX + 22), frame.maxX - 22),
                          y: min(max(frame.minY + c.window.minY * frame.height + 16, frame.minY + 22), frame.maxY - 22))
                .accessibilityElement()
                .accessibilityLabel(Text("스티커 후보 \((candidates.firstIndex { $0.id == c.id } ?? 0) + 1)"))
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { toggle(c.id) }
                .accessibilityAction(named: Text("지우기")) { discard(c.id) }
        }
    }

    private func trashSpot(_ size: CGSize) -> CGPoint { CGPoint(x: size.width / 2, y: size.height - 120) }

    private func overTrash(_ p: CGPoint, _ trash: CGPoint) -> Bool { hypot(p.x - trash.x, p.y - trash.y) < 60 }

    /// 끄는 동안 아래 가운데에 뜨는 휴지통. 위에 오면 커지고 빨개진다.
    private func trashCan(at spot: CGPoint) -> some View {
        let hot = overTrash(dragPoint, spot)
        return Image(systemName: hot ? "trash.fill" : "trash")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 68, height: 68)
            .background(Circle().fill(hot ? Color.red : Color.black.opacity(0.6)))
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .scaleEffect(hot ? 1.18 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hot)
            .position(spot)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    /// 손가락에 붙어 다니는 그 후보의 그림.
    private func carried(_ c: StickerCandidate) -> some View {
        Group {
            if let image = c.thumb {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "circle.dashed").font(.system(size: 30)).foregroundStyle(.white)
            }
        }
        .frame(width: 84, height: 84)
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        .modifier(Melt(on: sinking))
        .rotationEffect(.degrees(sinking ? 20 : 0))
        .position(dragPoint)
        .allowsHitTesting(false)
    }

    /// 휴지통에 놓으면: 그림이 작아지고 흐려지며 휴지통 속으로 스르르 들어간 뒤, 사진 위 자리도 천천히 걷힌다.
    private func sink(_ id: Int, into trash: CGPoint) {
        Haptics.bounce()
        withAnimation(.easeIn(duration: 0.55)) {
            sinking = true
            dragPoint = CGPoint(x: trash.x, y: trash.y + 6)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            discard(id)
            withAnimation(.easeOut(duration: 0.25)) { dragging = nil }
            sinking = false
        }
    }

    /// 후보를 지운다: 동그라미 · 테두리 · 밝은 자리 · 아래 줄에서 모두 빠진다.
    private func discard(_ id: Int) {
        withAnimation(.easeOut(duration: 0.6)) {
            candidates.removeAll { $0.id == id }
            chosen.remove(id)
            if focus == id { focus = nil }
        }
        previews[id] = nil
        clips[id] = nil
        guard let map = shot.map else { return }
        let keep = Set(candidates.filter { $0.kind == .subject }.map(\.label))
        DispatchQueue.global(qos: .userInitiated).async {
            let all = keep.isEmpty ? nil : map.mask(of: keep)
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.7)) { everyone = all } }
        }
    }

    /// 담는 동안: 고른 스티커가 제자리에서 뿅 튀어 오른 뒤 왼쪽 아래 수집함으로 날아간다.
    private func flying(_ frame: CGRect, in size: CGSize) -> some View {
        ForEach(picks) { c in
            if let image = previews[c.id] ?? c.thumb {
                let r = CGRect(x: frame.minX + c.window.minX * frame.width, y: frame.minY + c.window.minY * frame.height,
                               width: c.window.width * frame.width, height: c.window.height * frame.height)
                let gone = flown.contains(c.id)
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: r.width, height: r.height)
                    .scaleEffect(gone ? 0.12 : popped.contains(c.id) ? 1.2 : 1)
                    .opacity(gone ? 0 : 1)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
                    .position(gone ? CGPoint(x: 48, y: size.height - 80) : CGPoint(x: r.midX, y: r.midY))
                    .allowsHitTesting(false)
            }
        }
    }

    /// 고른 것을 하나씩 뿅 · 뿅 · 뿅 담는다.
    private func save() {
        let all = picks
        guard !all.isEmpty, !saving else { return }
        let step = 0.17
        withAnimation(.easeOut(duration: 0.15)) { saving = true; focus = nil }
        for (i, c) in all.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + Double(i) * step) {
                Haptics.bounce()
                withAnimation(.spring(response: 0.24, dampingFraction: 0.5)) { _ = popped.insert(c.id) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + Double(i) * step + 0.24) {
                withAnimation(.easeIn(duration: 0.3)) { _ = flown.insert(c.id) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + Double(all.count - 1) * step + 0.6) {
            onCollect(all, moving)
        }
    }

    /// 가운데에 크게: 고른 후보가 스티커가 된 모습. 움직임을 켰으면 움직인다.
    private func spotlight(_ c: StickerCandidate, in size: CGSize) -> some View {
        Group {
            if moving, let frames = clips[c.id], frames.count > 1 {
                LiveStampView(frames: frames, delay: clipDelay)
            } else if let still = previews[c.id] ?? c.thumb {
                Image(uiImage: still).resizable().scaledToFit()
            }
        }
        .allowsHitTesting(false)                          // 그림을 눌러도 뒤가 받아 가운데 그림을 걷는다
        .frame(maxWidth: size.width * 0.74, maxHeight: size.height * 0.46)
        .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
        .overlay(alignment: .topTrailing) {
            // 여기서 V 를 빼면 고른 것에서 빠지고 가운데 그림도 스르르 사라진다
            Button { uncheck(c.id) } label: {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.system(size: 32, weight: .semibold))
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 14, y: -14)
            .accessibilityLabel(Text("스티커 후보 \((candidates.firstIndex { $0.id == c.id } ?? 0) + 1)"))
            .accessibilityAddTraits(.isSelected)
        }
        .position(x: size.width / 2, y: size.height * 0.42)
        .id(c.id)
        .transition(.asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity), removal: .melt))
    }

    /// 고른 것에서 뺀다 — 아래 줄과 가운데 그림에서 스르르 사라지고, 사진 위 그 대상은 어두워진다.
    private func uncheck(_ id: Int) {
        Haptics.tick()
        withAnimation(.easeOut(duration: 0.5)) {
            chosen.remove(id)
            if focus == id { focus = nil }
        }
    }

    /// 미리보기를 준비한다: 가운데에 크게 띄울 그림, 움직임을 켰으면 고른 스티커마다 움직이는 모습.
    private func prepare() {
        let shot = shot, cutout = cutout
        if let id = focus, previews[id] == nil, let c = candidates.first(where: { $0.id == id }) {
            DispatchQueue.global(qos: .userInitiated).async {
                guard let still = StickerProposals.thumb(for: c, in: shot, cutout: cutout, maxSide: 720) else { return }
                DispatchQueue.main.async { previews[id] = still }
            }
        }
        guard moving else { return }
        let need = picks.filter { clips[$0.id] == nil && !making.contains($0.id) }
        guard !need.isEmpty else { return }
        guard let material = motion?(), material.frames.count > 1 else {
            // 움직임 프레임은 셔터 뒤 1초 남짓 지나 도착하고, 손떨림을 잡는 데 조금 더 걸린다
            if waits < 6 {
                waits += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { prepare() }
            }
            return
        }
        making.formUnion(need.map(\.id))
        clipDelay = max(0.06, material.seconds / Double(material.frames.count - 1))
        Self.clipQueue.async {
            for c in need {
                let frames = StickerProposals.clip(for: c, in: shot, frames: material.frames, cutout: cutout)
                DispatchQueue.main.async {
                    making.remove(c.id)
                    if frames.count > 1 { clips[c.id] = frames }
                }
            }
        }
    }

    /// 알아본 대상은 테두리만, 고른 대상은 밝고 테두리가 빛난다.
    private func refreshMask() {
        guard let map = shot.map else { return }
        let keep = Set(picks.filter { $0.kind == .subject }.map(\.label))
        DispatchQueue.global(qos: .userInitiated).async {
            let made = keep.isEmpty ? nil : map.mask(of: keep)
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.15)) { mask = made } }
        }
    }

    /// 사진: 고른 대상은 밝고 나머지는 어둡다. 밝은 곳의 테두리는 은은하게 빛난다.
    /// 누르면 그 대상을 고르고, 손가락으로 끝이 만나게 둘러 그리면 그 영역 안의 것을 딴다.
    private func photo(_ size: CGSize) -> some View {
        let closing = StickerMask.closesLoop(stroke.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
        return ZStack {
            Image(uiImage: shot.shown).resizable()
            Color.black.opacity(0.6)
            if let everyone {
                // 알아본 것마다 흰 테두리만 — 안은 어두운 채로 둔다. 고르면(아래 `bright`) 밝아진다
                ZStack {
                    Color.white
                        .mask { Image(uiImage: everyone).resizable() }
                        .compositingGroup()
                        .shadow(color: .white, radius: 0.8)
                        .shadow(color: .white.opacity(0.9), radius: 1.2)
                    Image(uiImage: shot.shown).resizable()
                        .overlay(Color.black.opacity(0.6))
                        .mask { Image(uiImage: everyone).resizable() }
                }
                .allowsHitTesting(false)
            }
            bright(size)
                .compositingGroup()
                .shadow(color: .white.opacity(glow ? 0.95 : 0.55), radius: glow ? 5 : 3)
                .shadow(color: Color(red: 1, green: 0.85, blue: 0.5).opacity(glow ? 0.7 : 0.3), radius: glow ? 16 : 9)
                .allowsHitTesting(false)
            if stroke.count > 1 {
                // 끝이 처음 자리에 닿으면 실선으로 바뀐다 — 손을 떼면 도형으로 인식한다는 뜻
                path(stroke, size, closed: false)
                    .stroke(closing ? Color.yellow : .white,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round,
                                               dash: closing ? [] : [8, 7]))
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
            if let id = born, let c = candidates.first(where: { $0.id == id }) {
                BirthBurst(shape: path(c.outline, size, closed: true), size: size)
                    .allowsHitTesting(false)
            }
            if let spot = nudgeSpot, stroke.isEmpty, !saving {
                DrawNudge()
                    .frame(width: 108, height: 108)
                    .position(x: spot.x * size.width, y: spot.y * size.height)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let moved = hypot(v.translation.width, v.translation.height)
                    guard moved > 10 || !stroke.isEmpty else { return }       // 누르기와 긋기를 가른다
                    if stroke.isEmpty {
                        nudgeSpot = nil
                        if focus != nil { withAnimation(.easeOut(duration: 0.15)) { focus = nil } }
                        stroke.append(unit(v.startLocation, size))
                    }
                    stroke.append(unit(v.location, size))
                }
                .onEnded { v in
                    if stroke.isEmpty {
                        tap(unit(v.location, size))
                    } else {
                        finishStroke(size)
                    }
                }
        )
    }

    /// 밝게 보이는 부분: 대상(지도), 그리고 고른 "사진 그대로" · 둘러 그린 것.
    private func bright(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let mask {
                Image(uiImage: shot.shown).resizable()
                    .mask { Image(uiImage: mask).resizable() }
            }
            ForEach(candidates.filter { chosen.contains($0.id) && ($0.kind == .photo || $0.kind == .drawn) }) { c in
                Image(uiImage: shot.shown).resizable()
                    .mask { region(c, size) }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// 후보가 차지한 모양. 둘러 그린 것은 그 안에서 딴 모양대로(아직 따는 중이면 그린 모양대로).
    @ViewBuilder
    private func region(_ c: StickerCandidate, _ size: CGSize) -> some View {
        if let m = c.mask {
            Image(uiImage: m).resizable()
                .frame(width: c.window.width * size.width, height: c.window.height * size.height)
                .offset(x: c.window.minX * size.width, y: c.window.minY * size.height)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        } else {
            marker(c, size).fill(.white)
        }
    }

    private func unit(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
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

    /// 손가락 시범을 보일 자리: 알아본 것이 가장 적게 걸리는 빈 곳.
    private func emptySpot() -> CGPoint {
        let spots: [CGPoint] = [(0.5, 0.3), (0.27, 0.3), (0.73, 0.3), (0.5, 0.5), (0.27, 0.5), (0.73, 0.5),
                                (0.27, 0.68), (0.73, 0.68)].map { CGPoint(x: $0.0, y: $0.1) }
        guard let map = shot.map else { return spots[0] }
        func crowd(_ c: CGPoint) -> Int {
            var n = 0
            let x0 = Int((c.x - 0.15) * CGFloat(map.width)), x1 = Int((c.x + 0.15) * CGFloat(map.width))
            let y0 = Int((c.y - 0.1) * CGFloat(map.height)), y1 = Int((c.y + 0.1) * CGFloat(map.height))
            for y in stride(from: max(y0, 0), to: min(y1, map.height), by: 3) {
                for x in stride(from: max(x0, 0), to: min(x1, map.width), by: 3) where map.labels[y * map.width + x] != 0 {
                    n += 1
                }
            }
            return n
        }
        return spots.min { crowd($0) < crowd($1) } ?? spots[0]
    }

    /// 사진에서 대상을 누르면 골라지거나 빠진다. 둘러 그린 자리도 같다.
    private func tap(_ point: CGPoint) {
        if let label = shot.map?.label(near: point), label != 0,
           let c = candidates.first(where: { $0.kind == .subject && $0.label == label }) {
            toggle(c.id)
        } else if let c = candidates.last(where: { $0.kind != .subject && $0.kind != .face && $0.window.contains(point) }) {
            toggle(c.id)
        }
    }

    private func toggle(_ id: Int) {
        Haptics.tick()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
        }
    }

    /// 끝이 만나는 도형이면 후보 하나로 더하고, 그 안의 대상을 찾아 딴다. 아니면(그냥 그은 선) 버린다.
    private func finishStroke(_ size: CGSize) {
        let points = stroke
        withAnimation(.easeOut(duration: 0.15)) { stroke = [] }
        guard StickerMask.closesLoop(points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }),
              let x0 = points.map(\.x).min(), let x1 = points.map(\.x).max(),
              let y0 = points.map(\.y).min(), let y1 = points.map(\.y).max() else { return }
        let c = StickerCandidate(id: (candidates.map(\.id).max() ?? 0) + 1000, kind: .drawn,
                                 window: StickerMask.room(around: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)),
                                 outline: points)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        drawLearned = true
        born = c.id
        withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) {
            candidates.append(c)
            chosen.insert(c.id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { if born == c.id { born = nil } }
        // 영역 안의 대상 찾기는 느리다(Vision) → 뒤에서. 찾으면 사진 위 밝은 곳 · 미리보기가 그 모양으로 바뀐다
        let shot = shot
        DispatchQueue.global(qos: .userInitiated).async {
            guard let crop = shot.shown.cropped(unit: c.window, maxSide: 600) else { return }
            let mask = StickerMask.refine(c.outlineInWindow, in: crop)
            let thumb = mask.flatMap { SubjectLift.cut(crop, mask: $0, trim: true) }
            DispatchQueue.main.async {
                guard let i = candidates.firstIndex(where: { $0.id == c.id }) else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    candidates[i].mask = mask
                    candidates[i].thumb = thumb ?? candidates[i].thumb
                }
            }
        }
    }

    /// 아래 줄: 고른 스티커들(움직임을 켜면 움직인다), 그 아래 다시 찍기 · 움직임 · 담기.
    private var tray: some View {
        VStack(spacing: 14) {
            if !chosen.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(picks) { c in
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { focus = c.id }
                            } label: { cell(c) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("스티커 후보 \((candidates.firstIndex { $0.id == c.id } ?? 0) + 1)"))
                            .transition(.asymmetric(insertion: .scale(scale: 0.3).combined(with: .opacity),
                                                    removal: .melt))
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            HStack(spacing: 10) {
                Button(action: onCancel) { Text(cancelTitle) }
                Spacer(minLength: 4)
                if motion != nil {
                    // 움직이는 스티커로 담을지 — 켜면 고른 스티커들이 움직여 보인다
                    Button {
                        Haptics.tick()
                        moving.toggle()
                    } label: {
                        Image(systemName: moving ? "livephoto" : "livephoto.slash")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 40, height: 38)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                            .foregroundStyle(moving ? .yellow : .white)
                    }
                    .accessibilityLabel("움직임")
                    .accessibilityAddTraits(moving ? .isSelected : [])
                }
                Spacer(minLength: 4)
                Button(action: save) {
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
            .lineLimit(1)
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
        }
        .padding(.top, 14).padding(.bottom, 24)
        .background(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)],
                                   startPoint: .top, endPoint: .center))
    }

    /// 고른 스티커 하나. 움직임을 켰으면 움직인다.
    private func cell(_ c: StickerCandidate) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if moving, let frames = clips[c.id], frames.count > 1 {
                    LiveStampView(frames: frames, delay: clipDelay).padding(6)
                } else if let thumb = c.thumb {
                    Image(uiImage: thumb).resizable().scaledToFit().padding(6)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 72, height: 72)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
            if moving, clips[c.id] == nil {
                ProgressView().controlSize(.mini).tint(.white).padding(6)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.system(size: 18))
                    .padding(4)
            }
        }
    }
}

/// 스르르: 흐려지고 작아지며 사라진다.
private struct Melt: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.blur(radius: on ? 10 : 0).scaleEffect(on ? 0.35 : 1).opacity(on ? 0 : 1)
    }
}

extension AnyTransition {
    static var melt: AnyTransition { .modifier(active: Melt(on: true), identity: Melt(on: false)) }
}

/// 둘러 그린 자리가 스티커로 태어날 때: 그 모양이 하얗게 번쩍이고, 테두리가 빛나며 퍼지고, 별이 흩어진다.
private struct BirthBurst: View {
    let shape: Path
    let size: CGSize
    @State private var go = false
    @State private var fade = false

    var body: some View {
        let box = shape.boundingRect
        let center = CGPoint(x: box.midX, y: box.midY)
        let anchor = UnitPoint(x: center.x / max(size.width, 1), y: center.y / max(size.height, 1))
        let reach = max(box.width, box.height) / 2 + 34
        ZStack {
            shape.fill(.white).opacity(go ? 0 : 0.8)
            shape.stroke(.white, style: StrokeStyle(lineWidth: go ? 1.5 : 7, lineJoin: .round))
                .shadow(color: Color(red: 1, green: 0.85, blue: 0.45), radius: 14)
                .scaleEffect(go ? 1.18 : 1, anchor: anchor)
                .opacity(fade ? 0 : 1)
            ForEach(0..<10, id: \.self) { i in
                let a = Double(i) / 10 * 2 * .pi + 0.3
                Image(systemName: "sparkle")
                    .font(.system(size: i.isMultiple(of: 2) ? 18 : 11, weight: .bold))
                    .foregroundStyle(i.isMultiple(of: 3) ? Color(red: 1, green: 0.9, blue: 0.5) : .white)
                    .shadow(color: .white, radius: 4)
                    .scaleEffect(go ? 0.5 : 1.1)
                    .position(x: center.x + (go ? cos(a) * reach : cos(a) * 12),
                              y: center.y + (go ? sin(a) * reach : sin(a) * 12))
                    .opacity(fade ? 0 : 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            withAnimation(.easeOut(duration: 0.65)) { go = true }
            withAnimation(.easeIn(duration: 0.35).delay(0.45)) { fade = true }
        }
    }
}

/// 둘러 그리기 시범: 점선 동그라미가 그려지고 손가락이 그 끝을 따라 돈다.
private struct DrawNudge: View {
    @State private var turn = false

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2 - 8
            ZStack {
                Circle()
                    .trim(from: 0, to: turn ? 1 : 0.02)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 7]))
                    .rotationEffect(.degrees(-90))
                    .padding(8)
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .offset(x: 9, y: 13)                       // 손가락 끝이 선 위에 오게
                    .rotationEffect(.degrees(turn ? -360 : 0))  // 손은 돌지 않고 바로 서 있게
                    .offset(y: -r)
                    .rotationEffect(.degrees(turn ? 360 : 0))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: false)) { turn = true }
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
