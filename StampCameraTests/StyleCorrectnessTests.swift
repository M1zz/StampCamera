//
//  StyleCorrectnessTests.swift
//  StampCameraTests
//
//  The promise the user cares about most: the style you CHOOSE is the style you
//  GET. A sticker choice must never come out a perforated stamp; a "moving"
//  choice must never come out frozen. These tests pin the two axes (shape /
//  motion) at the one place every look is derived — `CollectionStore.stillLook`
//  / `clipLook` — plus the 2-axis `StampStyle` mapping, style persistence, and
//  the Photos-library import crop.
//

import Testing
import UIKit
@testable import StampCamera

@MainActor
struct StyleCorrectnessTests {

    // A solid opaque tile big enough that perforation visibly changes pixels.
    private func tile(_ color: UIColor = .orange,
                      size: CGSize = CGSize(width: 120, height: 156)) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            color.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // Frames with a square marching across, so a real clip's frames DIFFER.
    private func movingFrames(count: Int, size: CGSize = CGSize(width: 120, height: 156)) -> [UIImage] {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return (0..<count).map { i in
            UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                UIColor.red.setFill()
                let side = size.width * 0.18, travel = size.width - side
                let x = travel * CGFloat(i) / CGFloat(max(count - 1, 1))
                ctx.fill(CGRect(x: x, y: size.height * 0.4, width: side, height: side))
            }
        }
    }

    // MARK: - The 2-axis StampStyle mapping (no axis can flip)

    @Test func 모든_2축_조합이_정확히_왕복한다() {
        for moving in [false, true] {
            for cutout in [false, true] {
                let s = StampStyle.make(moving: moving, cutout: cutout)
                #expect(s.moving == moving)      // 움직임 축 보존
                #expect(s.cutout == cutout)      // 모양 축 보존
            }
        }
    }

    @Test func make는_네_스타일에_정확히_대응한다() {
        #expect(StampStyle.make(moving: false, cutout: false) == .stamp)
        #expect(StampStyle.make(moving: true,  cutout: false) == .liveStamp)
        #expect(StampStyle.make(moving: false, cutout: true)  == .sticker)
        #expect(StampStyle.make(moving: true,  cutout: true)  == .liveSticker)
    }

    @Test func 움직임_플래그는_needsMotion과_일치한다() {
        for s in StampStyle.allCases { #expect(s.moving == s.needsMotion) }
    }

    @Test func 톱니_스타일만_cutout이_아니다() {
        #expect(!StampStyle.stamp.cutout)
        #expect(!StampStyle.liveStamp.cutout)
        #expect(StampStyle.sticker.cutout)
        #expect(StampStyle.liveSticker.cutout)
    }

    // MARK: - stillLook: the shape axis can never flip

    @Test func 우표_스타일은_언제나_톱니가_찍힌다() {
        let img = tile()
        let perforated = CollectionStore.stampShaped(img).pngData()
        #expect(CollectionStore.stillLook(img, style: .stamp).pngData() == perforated)
        #expect(CollectionStore.stillLook(img, style: .liveStamp).pngData() == perforated)
        // 그리고 톱니는 원본과 다르다 (실제로 구멍이 뚫렸다)
        #expect(perforated != img.pngData())
    }

    @Test func 스티커_스타일은_절대_톱니_우표가_되지_않는다() {
        let img = tile()
        let perforated = CollectionStore.stampShaped(img).pngData()
        // cutout이 성공하든(투명 배경) 실패해 원본으로 떨어지든,
        // 결과는 결코 "톱니 우표"와 같을 수 없다 — 스티커가 우표로 둔갑하지 않는다.
        #expect(CollectionStore.stillLook(img, style: .sticker).pngData() != perforated)
        #expect(CollectionStore.stillLook(img, style: .liveSticker).pngData() != perforated)
    }

    @Test func stillLook은_항상_이미지를_돌려준다() {
        // 비옵셔널 반환이라 nil이 될 수 없다 — 빈 결과로 "사라지는" 일이 없다
        let img = tile()
        for s in StampStyle.allCases {
            #expect(CollectionStore.stillLook(img, style: s).size.width > 0)
        }
    }

    // MARK: - clipLook: a moving style is never frozen, never wrong-shape

    @Test func 움직이는_우표는_프레임마다_톱니가_찍히고_움직임이_남는다() {
        let frames = movingFrames(count: 6)
        let clip = CollectionStore.clipLook(frames, style: .liveStamp)
        #expect(clip.count == frames.count)               // 한 장도 잃지 않는다
        // 각 프레임은 같은 입력의 stampShaped와 일치 (톱니가 확실히 찍힘)
        #expect(clip[0].pngData() == CollectionStore.stampShaped(frames[0]).pngData())
        #expect(clip[0].pngData() != clip[3].pngData())   // 여전히 움직인다
    }

    @Test func 움직이는_스티커는_절대_한장으로_얼지_않는다() {
        let frames = movingFrames(count: 6)
        let clip = CollectionStore.clipLook(frames, style: .liveSticker)
        #expect(clip.count >= 2)                           // cutout 성공/실패와 무관하게 ≥2
        #expect(clip[0].pngData() != clip[clip.count - 1].pngData())  // 움직임 보존
    }

    @Test func 한장짜리_입력은_그대로_돌아온다() {
        let one = movingFrames(count: 1)
        #expect(CollectionStore.clipLook(one, style: .liveStamp).count == 1)
        #expect(CollectionStore.clipLook(one, style: .liveSticker).count == 1)
    }

    // MARK: - The chosen style is recorded, persists, and survives reload

    @Test func 선택한_스타일이_정확히_기록되고_되읽힌다() {
        for s in StampStyle.allCases {
            let h = Harness(); defer { h.cleanup() }
            let id = h.add()
            h.store.recordStyle(s, for: id)
            #expect(h.store.style(for: id) == s)           // 즉시
            #expect(h.reopen().style(for: id) == s)        // 재시작 후에도
        }
    }

    @Test func applyStyle는_고른_스타일을_즉시_기록한다() {
        for s in StampStyle.allCases {
            let h = Harness(); defer { h.cleanup() }
            let id = h.add()
            h.store.applyStyle(s, for: id)                 // 파생은 백그라운드지만
            #expect(h.store.style(for: id) == s)           // 선택 기록은 동기적·정확
            #expect(h.reopen().style(for: id) == s)
        }
    }

    // MARK: - Photos-library import center-crop

    @Test func 가져오기_크롭은_요청한_비율과_단위정사각형을_지킨다() throws {
        let wide = tile(.blue, size: CGSize(width: 400, height: 200))   // 2:1
        let out = try #require(StampCompositor.centerCrop(wide, aspect: 0.75)) // 세로 우표 비율
        let ar = out.image.size.width / out.image.size.height
        #expect(abs(ar - 0.75) < 0.02)                     // 출력은 정확히 그 비율
        #expect(out.cropNorm.minX >= 0 && out.cropNorm.minY >= 0)
        #expect(out.cropNorm.maxX <= 1.0001 && out.cropNorm.maxY <= 1.0001)
        // 가로가 넘치는 사진이므로 좌우가 잘리고 세로는 가득 찬다
        #expect(out.cropNorm.height > 0.99)
        #expect(out.cropNorm.width < 1.0)
    }

    @Test func 가져오기_크롭은_가운데_정렬이다() throws {
        let wide = tile(.green, size: CGSize(width: 400, height: 200))
        let out = try #require(StampCompositor.centerCrop(wide, aspect: 0.75))
        // 좌우 여백이 같다 → 중심 정렬
        #expect(abs(out.cropNorm.minX - (1 - out.cropNorm.maxX)) < 0.01)
    }

    // MARK: - Result verification (촬영 후 "요청한 모습이 맞는지" 판정)

    /// 카메라의 `verifyResult`가 쓰는 움직임 불일치 판정과 동일한 술어
    /// (`style.moving && !isPlayablyLive`)가 실제로 맞고 틀림을 가른다.
    @Test func 움직임_요청에_클립이_없으면_불일치로_감지된다() throws {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.recordStyle(.liveStamp, for: id)
        #expect(h.store.style(for: id).moving)
        // 클립 없음 → 재생 가능 라이브 아님 → 불일치(다시 찍기 알림 대상)
        #expect(!h.store.isPlayablyLive(id))

        // 진짜 움직이는 클립을 붙이면 → 일치(알림 없음)
        let clip = try #require(APNG.encode(movingFrames(count: 5), delay: 0.1))
        h.store.setLive(clip, sticker: nil, for: id)
        #expect(h.store.isPlayablyLive(id))
    }

    /// 정지 스타일은 클립이 없어도 불일치가 아니다 (움직임 축을 검사하지 않음).
    @Test func 정지_스타일은_클립이_없어도_불일치가_아니다() {
        let h = Harness(); defer { h.cleanup() }
        for s in [StampStyle.stamp, .sticker] {
            let id = h.add()
            h.store.recordStyle(s, for: id)
            #expect(!h.store.style(for: id).moving)   // 움직임 검사 대상 아님
        }
    }
}
