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
