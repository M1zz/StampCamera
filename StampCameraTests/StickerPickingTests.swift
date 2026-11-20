//
//  StickerPickingTests.swift
//  StampCameraTests
//
//  사진 한 장에서 스티커 여러 개: 후보 자리, 손으로 정한 모양(마스크), 줌 눈금.
//

import Testing
import UIKit
@testable import StampCamera

struct StickerProposalTests {
    private let size = CGSize(width: 400, height: 800)

    @Test func 큰_대상부터_하나씩_그리고_모두_그리고_사진_그대로() {
        let plan = StickerProposals.plan(
            subjects: [1: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                       2: CGRect(x: 0.5, y: 0.3, width: 0.4, height: 0.5)],
            faces: [], size: size, photoAspect: 0.75)
        #expect(plan.map(\.kind) == [.subject, .subject, .everything, .photo])
        #expect(plan[0].label == 2)                      // 큰 것이 먼저
        #expect(plan[2].window.contains(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7)))
    }

    @Test func 대상이_하나면_모두는_없다() {
        let plan = StickerProposals.plan(subjects: [1: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)],
                                         faces: [], size: size, photoAspect: 0.75)
        #expect(plan.map(\.kind) == [.subject, .photo])
    }

    @Test func 대상이_없어도_사진_그대로는_있다() {
        let plan = StickerProposals.plan(subjects: [:], faces: [], size: size, photoAspect: 0.75)
        #expect(plan.map(\.kind) == [.photo])
        let w = plan[0].window
        #expect(abs(w.midX - 0.5) < 0.001 && abs(w.midY - 0.5) < 0.001)
        // 우표 비율(가로/세로 0.75)을 화면 점 단위로 지킨다
        #expect(abs((w.width * size.width) / (w.height * size.height) - 0.75) < 0.01)
    }

    @Test func 자리는_넉넉하게_넓히되_사진을_벗어나지_않는다() {
        let padded = StickerProposals.padded(CGRect(x: 0, y: 0.4, width: 0.5, height: 0.2), in: size)
        #expect(padded.minX == 0)
        #expect(padded.width > 0.5 && padded.height > 0.2)
        #expect(StickerProposals.unit.contains(padded))
    }

    @Test func 얼굴은_대상보다_훨씬_작을_때만_따로_제안한다() {
        let person = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        let small = CGRect(x: 0.42, y: 0.15, width: 0.12, height: 0.08)
        let plan = StickerProposals.plan(subjects: [1: person], faces: [small], size: size, photoAspect: 0.75)
        #expect(plan.map(\.kind) == [.subject, .face, .photo])
        // 얼굴이 대상의 거의 전부면 겹치니 뺀다
        let big = CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.4)
        let none = StickerProposals.plan(subjects: [1: person], faces: [big], size: size, photoAspect: 0.75)
        #expect(none.map(\.kind) == [.subject, .photo])
        // 대상 밖의 얼굴(포스터 속 얼굴 등)도 뺀다
        let outside = CGRect(x: 0.02, y: 0.02, width: 0.05, height: 0.04)
        let out = StickerProposals.plan(subjects: [1: person], faces: [outside], size: size, photoAspect: 0.75)
        #expect(out.map(\.kind) == [.subject, .photo])
    }

    @Test func 그린_테두리는_뜯을_자리_기준으로_옮겨진다() {
        let c = StickerCandidate(id: 1, kind: .drawn, window: CGRect(x: 0.2, y: 0.4, width: 0.4, height: 0.2),
                                 outline: [CGPoint(x: 0.2, y: 0.4), CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.4, y: 0.5)])
        let p = c.outlineInWindow
        #expect(abs(p[0].x) < 0.001 && abs(p[0].y) < 0.001)
        #expect(abs(p[1].x - 1) < 0.001 && abs(p[1].y - 1) < 0.001)
        #expect(abs(p[2].x - 0.5) < 0.001 && abs(p[2].y - 0.5) < 0.001)
    }
}

struct StickerMaskTests {
    private func solid(_ size: CGSize, _ color: UIColor = .red) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// 가운데 네모(가로 25~75%, 세로 50~90%)를 둘러 그린 모양.
    private var box: [CGPoint] {
        [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.5), CGPoint(x: 0.75, y: 0.9), CGPoint(x: 0.25, y: 0.9)]
    }

    @Test func 그린_테두리_안쪽만_남는다() throws {
        let mask = try #require(StickerMask.outline(box, size: CGSize(width: 200, height: 200)))
        let b = try #require(StickerMask.bounds(of: mask))
        #expect(abs(b.minX - 0.25) < 0.02 && abs(b.maxX - 0.75) < 0.02)
        #expect(abs(b.minY - 0.5) < 0.02 && abs(b.maxY - 0.9) < 0.02)      // 위아래가 뒤집히지 않는다
    }

    @Test func 점이_모자라면_모양을_만들지_않는다() {
        #expect(StickerMask.outline([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], size: CGSize(width: 50, height: 50)) == nil)
    }

    @Test func 빈_마스크는_자리가_없다() {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        let empty = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: fmt).image { _ in }
        #expect(StickerMask.bounds(of: empty) == nil)
    }

    @Test func 마스크대로_오리고_남은_곳에_맞춰_자른다() throws {
        let photo = solid(CGSize(width: 400, height: 400))
        let mask = try #require(StickerMask.outline(box, size: photo.size))
        let cut = try #require(SubjectLift.cut(photo, mask: mask, trim: true))
        #expect(abs(cut.size.width - 200) < 12)
        #expect(abs(cut.size.height - 160) < 12)
        // 자르지 않으면 조각 크기 그대로 — 움직이는 프레임이 흔들리지 않는다
        let whole = try #require(SubjectLift.cut(photo, mask: mask, trim: false))
        #expect(whole.size == photo.size)
    }

    @Test func 손으로_정한_모양은_자동_오려내기보다_먼저다() throws {
        let photo = solid(CGSize(width: 300, height: 300))
        let mask = try #require(StickerMask.outline(box, size: photo.size))
        let still = CollectionStore.stillLook(photo, style: .sticker, mask: mask)
        #expect(still.size.width < 200)                                   // 그린 모양대로 잘렸다
        let frames = [photo, solid(photo.size, .blue), solid(photo.size, .green)]
        let clip = CollectionStore.clipLook(frames, style: .liveSticker, mask: mask)
        #expect(clip.count == 3)
        #expect(clip.allSatisfy { $0.size == photo.size })
        // 우표 모양에서는 손으로 정한 모양을 쓰지 않는다
        #expect(CollectionStore.stillLook(photo, style: .stamp, mask: mask).pngData()
                == CollectionStore.stillLook(photo, style: .stamp).pngData())
    }

    @Test func 지도의_한_부분만_떼어_낼_수_있다() throws {
        var px = [UInt8](repeating: 0, count: 100)
        for y in 2...7 { for x in 2...5 { px[y * 10 + x] = 1 } }
        for y in 0...9 { px[y * 10 + 9] = 2 }
        let map = try #require(SubjectMap(width: 10, height: 10, labels: px))
        let left = try #require(map.cropped(to: CGRect(x: 0, y: 0, width: 0.7, height: 1)))
        #expect(left.width == 7 && left.height == 10)
        #expect(left.count == 1)
        #expect(left.kept == [1])
    }
}

struct ZoomScaleTests {
    private let scale = ZoomScale(min: 0.5, max: 8)

    @Test func 로그_눈금이라_두_배마다_같은_거리다() {
        #expect(abs(scale.position(of: 0.5)) < 0.001)
        #expect(abs(scale.position(of: 8) - 1) < 0.001)
        let a = scale.position(of: 1) - scale.position(of: 0.5)
        let b = scale.position(of: 2) - scale.position(of: 1)
        #expect(abs(a - b) < 0.001)
    }

    @Test func 자리와_배율은_서로_되돌아온다() {
        for z in [0.5, 1, 1.7, 3, 8] as [CGFloat] {
            #expect(abs(scale.zoom(at: scale.position(of: z)) - z) < 0.001)
        }
        #expect(abs(scale.zoom(at: -1) - 0.5) < 0.001)      // 범위 밖은 끝에 붙는다
        #expect(abs(scale.zoom(at: 2) - 8) < 0.001)
    }

    @Test func 켜진_배율_단추는_지금_배율보다_크지_않은_가장_큰_칸이다() {
        let stops: [CGFloat] = [0.5, 1, 2]
        #expect(ZoomScale.activeStop(stops, zoom: 0.5) == 0.5)
        #expect(ZoomScale.activeStop(stops, zoom: 1.4) == 1)
        #expect(ZoomScale.activeStop(stops, zoom: 5) == 2)
        #expect(ZoomScale.activeStop(stops, zoom: 0.3) == 0.5)
    }

    @Test func 배율_글자() {
        #expect(ZoomScale.label(1) == "1")
        #expect(ZoomScale.label(0.5) == "0.5")
        #expect(ZoomScale.label(1.44) == "1.4")
    }
}

struct CustomMaskStoreTests {
    @Test func 잇달아_담아도_이름이_겹치지_않고_원본을_나눠_쓴다() {
        let h = Harness()
        defer { h.cleanup() }
        let photo = TestSupport.image(.blue, size: CGSize(width: 40, height: 40))
        let a = h.store.add(TestSupport.image(), original: photo,
                            cropNorm: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let b = h.store.add(TestSupport.image(), sharingOriginalOf: a,
                            cropNorm: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        let c = h.store.add(TestSupport.image(), sharingOriginalOf: a)
        #expect(Set([a, b, c]).count == 3)
        #expect(h.fileExists("\(b).orig.jpg"))
        #expect(h.store.cropInfo(for: b)?.rect.minX == 0.5)
        // 하나를 지워도 다른 스티커의 원본은 남는다
        h.store.delete(a)
        #expect(h.fileExists("\(b).orig.jpg"))
        #expect(h.store.printStamp(for: b, longSidePx: 20, clipToShape: false) != nil)
    }

    @Test func 손으로_정한_모양은_저장되고_지우면_함께_사라진다() throws {
        let h = Harness()
        defer { h.cleanup() }
        let id = h.add()
        #expect(h.store.customMask(for: id) == nil)
        let mask = try #require(StickerMask.outline(
            [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.5, y: 0.8)],
            size: CGSize(width: 60, height: 60)))
        h.store.setCustomMask(mask, for: id)
        #expect(h.fileExists("\(id).cut"))
        #expect(h.reopen().customMask(for: id) != nil)
        #expect(h.store.style(for: id).cutout)                 // 손으로 정한 모양은 오려낸 스티커다
        #expect(h.store.archiveFiles(album: nil).contains { $0.path == "\(id).cut" })
        h.store.setCustomMask(nil, for: id)
        #expect(!h.fileExists("\(id).cut"))
        h.store.setCustomMask(mask, for: id)
        h.store.delete(id)
        #expect(!h.fileExists("\(id).cut"))
    }
}

// MARK: - 직접 그린 영역 안의 대상 따기 · 원본 해상도

struct DrawnRefineTests {
    /// 20×20 지도: 1번은 가운데 네모(6...13), 2번은 오른쪽 아래 큰 덩어리(14...19 × 10...19).
    private func map() throws -> SubjectMap {
        var px = [UInt8](repeating: 0, count: 400)
        for y in 6...13 { for x in 6...13 { px[y * 20 + x] = 1 } }
        for y in 10...19 { for x in 14...19 { px[y * 20 + x] = 2 } }
        return try #require(SubjectMap(width: 20, height: 20, labels: px))
    }

    private func square(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> [CGPoint] {
        [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
    }

    @Test func 테두리_안쪽_칸을_위아래_그대로_칠한다() throws {
        let inside = try #require(StickerMask.coverage(square(0, 0, 1, 0.5), width: 10, height: 10))
        #expect(inside[1 * 10 + 5])          // 위쪽
        #expect(!inside[8 * 10 + 5])         // 아래쪽
    }

    @Test func 대충_둘러도_안의_대상을_통째로_딴다() throws {
        // 1번(6~13)의 한쪽 가장자리를 빼먹고(6~12, 77%) 둘러도 — 대부분이 안에 있으니 — 1번 전체가 남는다
        let mask = try #require(StickerMask.refine(square(0.31, 0.31, 0.66, 0.66), map: try map()))
        let b = try #require(StickerMask.bounds(of: mask))
        #expect(abs(b.minX - 0.30) < 0.001 && abs(b.maxX - 0.70) < 0.001)
        #expect(abs(b.minY - 0.30) < 0.001 && abs(b.maxY - 0.70) < 0.001)
    }

    @Test func 넓게_둘러도_바탕은_버리고_대상만_남긴다() throws {
        let mask = try #require(StickerMask.refine(square(0.1, 0.1, 0.72, 0.72), map: try map()))
        let b = try #require(StickerMask.bounds(of: mask))
        #expect(abs(b.minX - 0.30) < 0.001 && abs(b.maxX - 0.70) < 0.001)
    }

    @Test func 대상의_일부만_두르면_그_부분만_남긴다() throws {
        // 2번(세로 10~19)의 윗부분(10~12)만 두른다 → 2번 가운데 테두리 안쪽만
        let mask = try #require(StickerMask.refine(square(0.68, 0.48, 1.0, 0.65), map: try map()))
        let b = try #require(StickerMask.bounds(of: mask))
        #expect(b.minX >= 0.69)                               // 1번은 들어오지 않는다
        #expect(b.maxY <= 0.66)                               // 테두리 아래로 내려가지 않는다
        #expect(abs(b.minY - 0.5) < 0.06)                     // 2번의 윗가장자리에서 시작
    }

    @Test func 안에_대상이_없으면_그린_모양_그대로() throws {
        #expect(StickerMask.refine(square(0, 0, 0.25, 0.25), map: try map()) == nil)
    }

    @Test func 둘러_그린_자리는_여유를_둔다() {
        let room = StickerMask.room(around: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        #expect(room.contains(CGRect(x: 0.37, y: 0.37, width: 0.26, height: 0.26)))
        #expect(StickerMask.room(around: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)).minX == 0)
    }
}

struct SourceResolutionTests {
    private func photo(_ w: CGFloat, _ h: CGFloat) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    private func shot(_ raw: UIImage, size: CGSize) -> PhotoShot {
        PhotoShot(raw: raw, shown: raw, size: size, mirrored: false, map: nil, faces: [])
    }

    @Test func 작은_대상도_원본에_담긴_만큼_또렷하게_자른다() throws {
        // 3000×4000 원본을 300×400 화면에 비춘다 → 화면 1pt 에 원본 10px
        let s = shot(photo(3000, 4000), size: CGSize(width: 300, height: 400))
        let out = try #require(s.crop(CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)))   // 화면 30×40pt
        #expect(abs(out.image.size.width * out.image.scale - 300) < 2)                    // 원본 300px 그대로
        #expect(abs(out.cropNorm.minX - 0.4) < 0.001)
    }

    @Test func 큰_대상은_긴_변을_스티커_크기로_맞춘다() throws {
        let s = shot(photo(3000, 4000), size: CGSize(width: 300, height: 400))
        let out = try #require(s.crop(CGRect(x: 0, y: 0, width: 1, height: 1)))
        let long = max(out.image.size.width, out.image.size.height) * out.image.scale
        #expect(abs(long - PhotoShot.stickerSide) < 2)
    }

    @Test func 원본보다_크게_늘리지_않는다() throws {
        let s = shot(photo(300, 400), size: CGSize(width: 300, height: 400))
        let out = try #require(s.crop(CGRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(abs(max(out.image.size.width, out.image.size.height) * out.image.scale - 400) < 2)
    }
}

// MARK: - 손떨림 보정

struct StabilizerTests {
    /// 손떨림처럼 장면이 통째로 밀린 장: 큰 무늬 그림에서 (ox, oy)(왼쪽 위 원점)부터 200×160 을 잘라 낸다.
    private static let scene: [UInt8] = {
        let W = 400, H = 360
        var px = [UInt8](repeating: 0, count: W * H)
        var seed: UInt64 = 7
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        for _ in 0..<160 {
            let cx = rnd() * Double(W), cy = rnd() * Double(H), r = 8 + rnd() * 30, v = rnd() * 255
            for y in 0..<H { for x in 0..<W {
                let dx = Double(x) - cx, dy = Double(y) - cy
                if dx * dx + dy * dy < r * r { px[y * W + x] = UInt8((Double(px[y * W + x]) + v) / 2) }
            } }
        }
        return px
    }()

    private func frame(_ ox: Int, _ oy: Int) -> UIImage {
        let w = 200, h = 160
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let v = Self.scene[(y + oy) * 400 + x + ox]
            rgba[(y * w + x) * 4] = v; rgba[(y * w + x) * 4 + 1] = v; rgba[(y * w + x) * 4 + 2] = v
        } }
        let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return UIImage(cgImage: ctx.makeImage()!)
    }

    /// 두 장의 가운데 부분이 얼마나 다른지 (0 = 같다).
    private func difference(_ a: UIImage, _ b: UIImage) -> Double {
        func gray(_ img: UIImage) -> [UInt8] {
            let cg = img.cgImage!
            var px = [UInt8](repeating: 0, count: cg.width * cg.height)
            let ctx = CGContext(data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                bytesPerRow: cg.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return px
        }
        let x = gray(a), y = gray(b)
        var sum = 0.0, n = 0.0
        for row in 40..<120 { for col in 50..<150 {
            sum += abs(Double(x[row * 200 + col]) - Double(y[row * 200 + col])); n += 1
        } }
        return sum / n
    }

    @Test func 밀린_장을_가운데_장에_맞춰_되돌린다() {
        let reference = frame(100, 100)
        let shaken = [frame(90, 94), reference, frame(106, 103)]     // 장면이 이리저리 밀렸다
        let steady = Stabilizer.steady(shaken)
        #expect(steady.count == 3)
        #expect(steady[1] === reference)                             // 가운데 장은 그대로
        #expect(difference(shaken[0], reference) > 10)               // 보정 전에는 어긋나 있고
        #expect(difference(steady[0], reference) < 3)                // 보정하면 겹친다
        #expect(difference(steady[2], reference) < 3)
    }

    @Test func 크게_옮긴_장은_흔들림으로_보지_않는다() {
        let reference = frame(100, 100)
        let moved = frame(10, 100)                                   // 긴 변의 45% 를 옮겼다
        #expect(Stabilizer.steady([moved, reference, reference])[0] === moved)
    }

    @Test func 두_장_이하는_손대지_않는다() {
        let one = [frame(100, 100), frame(90, 90)]
        let out = Stabilizer.steady(one)
        #expect(out[0] === one[0] && out[1] === one[1])
    }
}

// MARK: - 단추 없이 둘러 그리기

struct ClosesLoopTests {
    /// 가운데 (cx, cy), 반지름 r 인 원을 `sweep` 도만큼 그린 손가락 길.
    private func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, sweep: CGFloat) -> [CGPoint] {
        stride(from: 0, through: sweep, by: 10).map {
            CGPoint(x: cx + r * cos($0 * .pi / 180), y: cy + r * sin($0 * .pi / 180))
        }
    }

    @Test func 끝이_처음_자리로_돌아오면_도형이다() {
        #expect(StickerMask.closesLoop(arc(200, 300, 80, sweep: 360)))
        #expect(StickerMask.closesLoop(arc(200, 300, 80, sweep: 330)))     // 조금 덜 닫혀도 된다
    }

    @Test func 반쯤_그리다_만_것은_도형이_아니다() {
        #expect(!StickerMask.closesLoop(arc(200, 300, 80, sweep: 200)))
    }

    @Test func 그냥_그은_선은_도형이_아니다() {
        let line = (0...20).map { CGPoint(x: 100 + CGFloat($0) * 10, y: 300) }
        #expect(!StickerMask.closesLoop(line))
    }

    @Test func 너무_작은_동그라미는_누른_것으로_본다() {
        #expect(!StickerMask.closesLoop(arc(200, 300, 12, sweep: 360)))
    }
}
