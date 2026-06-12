//
//  LiveStampTests.swift
//  StampCameraTests
//
//  The live-stamp pipeline, end to end minus the camera: synthetic moving
//  frames → window crop → APNG encode → store → decode → playback indexing.
//  The headline assertion everywhere: decoded frames actually DIFFER — a
//  "clip" of identical frames is exactly the looks-frozen bug.
//

import Testing
import UIKit
@testable import StampCamera

@MainActor
struct LiveStampTests {

    /// Synthesizes `count` preview-sized frames with a square marching across
    /// the window region, so every frame is visibly different.
    private func movingFrames(count: Int, size: CGSize) -> [UIImage] {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return (0..<count).map { i in
            UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                UIColor.red.setFill()
                // marches across but always stays inside the canvas
                let side = size.width * 0.18
                let travel = size.width - side
                let x = travel * CGFloat(i) / CGFloat(max(count - 1, 1))
                ctx.fill(CGRect(x: x, y: size.height * 0.4, width: side, height: side))
            }
        }
    }

    private let preview = CGSize(width: 400, height: 533)
    private let window = CGRect(x: 60, y: 120, width: 200, height: 260)

    @Test func 크롭된_프레임들은_서로_다르다() throws {
        let cropped = movingFrames(count: 8, size: preview).compactMap {
            StampCompositor.makeStamp(from: $0, previewSize: preview,
                                      windowRect: window, scale: 1.0)?.image
        }
        #expect(cropped.count == 8)
        #expect(cropped[0].pngData() != cropped[4].pngData())
    }

    @Test func 인코딩_저장_디코딩_왕복후에도_움직임이_남는다() throws {
        let h = Harness(); defer { h.cleanup() }
        let cropped = movingFrames(count: 8, size: preview).compactMap {
            StampCompositor.makeStamp(from: $0, previewSize: preview,
                                      windowRect: window, scale: 1.0)?.image
        }
        let apng = try #require(APNG.encode(cropped, delay: 0.11))

        let id = h.add()
        h.store.setLive(apng, sticker: nil, for: id)
        #expect(h.store.hasLive(id))

        let clip = try #require(h.store.liveClip(for: id))
        #expect(clip.frames.count == 8)
        #expect(abs(clip.delay - 0.11) < 0.02)                       // tempo survives
        #expect(clip.frames[0].pngData() != clip.frames[4].pngData()) // motion survives
    }

    @Test func 썸네일_디코딩도_프레임별로_다르고_작게_나온다() throws {
        let h = Harness(); defer { h.cleanup() }
        let cropped = movingFrames(count: 6, size: preview).compactMap {
            StampCompositor.makeStamp(from: $0, previewSize: preview,
                                      windowRect: window, scale: 1.0)?.image
        }
        let apng = try #require(APNG.encode(cropped, delay: 0.12))
        let id = h.add()
        h.store.setLive(apng, sticker: nil, for: id)

        let small = try #require(h.store.liveClip(for: id, maxPixel: 120))
        #expect(small.frames.count == 6)
        #expect(max(small.frames[0].size.width, small.frames[0].size.height) <= 120)
        #expect(small.frames[0].pngData() != small.frames[3].pngData())
    }

    @Test func 핫클립은_즉시_올라가고_최신_한장만_남는다() {
        let h = Harness(); defer { h.cleanup() }
        let frames = movingFrames(count: 4, size: CGSize(width: 80, height: 104))
        let a = h.add(.red), b = h.add(.blue)
        h.store.setHotClip(frames, delay: 0.1, for: a)
        #expect(h.store.hotClips[a] != nil)
        h.store.setHotClip(frames, delay: 0.1, for: b)
        #expect(h.store.hotClips[a] == nil)        // only the freshest is held
        #expect(h.store.hotClips[b]?.frames.count == 4)
    }

    @Test func 메시지_스티커는_500KB_예산을_지킨다() throws {
        // photo-noise frames compress worst — the budget's hardest case
        let size = CGSize(width: 480, height: 620)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        var rng = SystemRandomNumberGenerator()
        let frames: [UIImage] = (0..<12).map { _ in
            UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                for _ in 0..<500 {
                    UIColor(hue: CGFloat(Double.random(in: 0...1, using: &rng)),
                            saturation: 1, brightness: 1, alpha: 1).setFill()
                    ctx.fill(CGRect(x: CGFloat(Double.random(in: 0..<460, using: &rng)),
                                    y: CGFloat(Double.random(in: 0..<600, using: &rng)),
                                    width: 24, height: 24))
                }
            }
        }
        let sticker = APNG.encodeForMessages(frames, delay: 0.12)
        if let sticker {
            #expect(sticker.count <= 480_000)   // inside Messages' limit
            // and it still animates
            let src = try #require(CGImageSourceCreateWithData(sticker as CFData, nil))
            #expect(CGImageSourceGetCount(src) > 1)
        }
        // nil is a legal outcome (budget miss → still sticker), never a broken file
    }

    @Test func 모션마스터는_저장하고_그대로_되읽는다() throws {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        let frames = movingFrames(count: 5, size: CGSize(width: 120, height: 156))
        h.store.setMotionMaster(frames, delay: 0.2, for: id)
        #expect(h.store.hasMotionMaster(id))
        let master = try #require(h.store.motionMaster(for: id))
        #expect(master.frames.count == 5)
        #expect(abs(master.delay - 0.2) < 0.001)
        #expect(master.frames[0].jpegData(compressionQuality: 1)
                != master.frames[3].jpegData(compressionQuality: 1))
    }

    @Test func 스타일_전환은_클립을_만들고_되돌리면_지운다() async throws {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        #expect(h.store.style(for: id) == .stamp)        // 클립 없음 → 정지 우표
        h.store.setMotionMaster(movingFrames(count: 6, size: CGSize(width: 120, height: 156)),
                                delay: 0.12, for: id)
        h.store.applyStyle(.liveStamp, for: id)
        #expect(h.store.style(for: id) == .liveStamp)    // 선택은 즉시 기록
        for _ in 0..<60 where !h.store.hasLive(id) {     // 파생은 백그라운드 — 대기
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(h.store.hasLive(id))
        let clip = try #require(h.store.liveClip(for: id))
        #expect(clip.frames.count == 6)

        h.store.applyStyle(.stamp, for: id)              // 정지로 되돌리면
        for _ in 0..<60 where h.store.hasLive(id) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(!h.store.hasLive(id))                    // 클립이 내려간다
        #expect(h.store.hasMotionMaster(id))             // 마스터는 영구 보관
    }

    @Test func 마스터없는_옛우표도_모습을_바꿨다_되돌리면_움직임이_산다() async throws {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        // 마스터 시스템 이전의 우표: 클립만 있고 .frames 마스터는 없다
        let frames = movingFrames(count: 6, size: CGSize(width: 120, height: 156))
        let apng = try #require(APNG.encode(frames, delay: 0.12))
        h.store.setLive(apng, sticker: nil, for: id)
        #expect(!h.store.hasMotionMaster(id))
        #expect(h.store.canMove(id))                     // 라이브 칩은 켜져 있어야

        h.store.applyStyle(.stamp, for: id)              // 정지로 바꿔도
        for _ in 0..<60 where h.store.hasLive(id) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(!h.store.hasLive(id))                    // 클립은 내려가지만
        #expect(h.store.hasMotionMaster(id))             // 구조 백필로 마스터가 남는다

        h.store.applyStyle(.liveStamp, for: id)          // 라이브로 되돌리면
        for _ in 0..<60 where !h.store.hasLive(id) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let clip = try #require(h.store.liveClip(for: id))
        #expect(clip.frames.count == 6)                  // 움직임이 살아난다
        #expect(clip.frames[0].pngData() != clip.frames[3].pngData())
    }

    @Test func 라이브_표식은_진짜_재생가능한_클립에만_붙는다() throws {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        #expect(!h.store.isPlayablyLive(id))                  // 클립 없음 → 표식 없음

        // 1프레임짜리 가짜 클립: 파일은 있지만 움직이지 않는다
        let single = try #require(APNG.encode(
            [TestSupport.image(.blue, size: CGSize(width: 40, height: 52))], delay: 0.1))
        h.store.setLive(single, sticker: nil, for: id)
        #expect(h.store.hasLive(id))                          // 파일은 존재하지만
        #expect(!h.store.isPlayablyLive(id))                  // 표식은 거짓말하지 않는다

        // 진짜 움직이는 클립으로 교체하면 표식이 켜진다
        let real = try #require(APNG.encode(
            movingFrames(count: 5, size: CGSize(width: 80, height: 104)), delay: 0.1))
        h.store.setLive(real, sticker: nil, for: id)
        #expect(h.store.isPlayablyLive(id))
    }

    @Test func 재생_인덱스는_시간에_따라_모든_프레임을_순환한다() {
        let frames = movingFrames(count: 5, size: CGSize(width: 40, height: 52))
        let view = LiveStampView(frames: frames, delay: 0.1)
        // sample a full cycle: every frame appears, in order, wrapping around
        let indices = (0..<10).map { view.frameIndex(at: Double($0) * 0.1 + 0.001) }
        #expect(indices == [0, 1, 2, 3, 4, 0, 1, 2, 3, 4])
        #expect(view.frameIndex(at: 123.456) < frames.count)   // never out of bounds
    }
}
