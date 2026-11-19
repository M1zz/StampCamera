//
//  StickerArchiveTests.swift
//  StampCameraTests
//
//  백업 · 수집함 보내기(.kkuk) 왕복, 받은 파일 검사, 테두리 · 글자, 찾기.
//

import Testing
import UIKit
@testable import StampCamera

@MainActor
struct StickerArchiveTests {

    private func archive(_ store: CollectionStore, album: String?) async -> URL? {
        await withCheckedContinuation { c in store.makeArchive(album: album) { c.resume(returning: $0) } }
    }
    private func importing(_ url: URL, into store: CollectionStore) async -> StickerImportResult? {
        await withCheckedContinuation { c in
            store.importArchive(at: url) { r in c.resume(returning: try? r.get()) }
        }
    }

    // MARK: - 받은 파일 검사

    @Test func onlyKnownFileShapesAreAccepted() {
        #expect(StickerArchive.isAllowed("1700000000000.png"))
        #expect(StickerArchive.isAllowed("1700000000000.png.orig.jpg"))
        #expect(StickerArchive.isAllowed("1700000000000.png.frames/03.jpg"))
        #expect(StickerArchive.isAllowed("albums.json"))
        #expect(!StickerArchive.isAllowed("../1700000000000.png"))
        #expect(!StickerArchive.isAllowed("/etc/passwd"))
        #expect(!StickerArchive.isAllowed("1700000000000.png.frames/../../x.jpg"))
        #expect(!StickerArchive.isAllowed("Library/Preferences/x.plist"))
        #expect(!StickerArchive.isAllowed("evil.sh"))
    }

    @Test func notOurFileIsRejected() throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID()).kkuk")
        try Data("hello".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("junk-out-\(UUID())")
        #expect(throws: (any Error).self) { _ = try StickerArchive.read(junk, into: dest) }
    }

    // MARK: - 전체 백업

    @Test func fullBackupRestoresIntoFreshStore() async throws {
        let a = Harness(); defer { a.cleanup() }
        let first = a.add(.red)
        a.store.setCaption("바다", for: first)
        a.store.createAlbum("여행")
        let second = a.add(.blue)
        a.store.setBackground(.kraft, for: "여행")

        let url = try #require(await archive(a.store, album: nil))
        let b = Harness(); defer { b.cleanup() }
        let r = try #require(await importing(url, into: b.store))

        #expect(r.added == 2)
        #expect(r.skipped == 0)
        #expect(Set(b.store.stamps.map(\.id)) == [first, second])
        #expect(b.store.stamps.first { $0.id == first }?.caption == "바다")
        #expect(b.store.stamps.first { $0.id == second }?.album == "여행")
        #expect(b.store.albums.contains("여행"))
        #expect(b.store.backgroundStyle(of: "여행") == .kraft)
        // 다시 열어도 남아 있다
        #expect(b.reopen().stamps.count == 2)
    }

    @Test func restoringTwiceSkipsWhatIsAlreadyThere() async throws {
        let a = Harness(); defer { a.cleanup() }
        a.add(.red); a.add(.green)
        let url = try #require(await archive(a.store, album: nil))
        let again = try #require(await importing(url, into: a.store))
        #expect(again.added == 0)
        #expect(again.skipped == 2)
        #expect(a.store.stamps.count == 2)
    }

    // MARK: - 수집함 보내기

    @Test func packCarriesOnlyThatAlbum() async throws {
        let a = Harness(); defer { a.cleanup() }
        a.add(.red)                       // 내 수집함
        a.store.createAlbum("고양이")
        let cat1 = a.add(.orange)
        let cat2 = a.add(.brown)

        let url = try #require(await archive(a.store, album: "고양이"))
        #expect(url.pathExtension == "kkuk")
        let b = Harness(); defer { b.cleanup() }
        let r = try #require(await importing(url, into: b.store))

        #expect(r.added == 2)
        #expect(r.albums == ["고양이"])
        #expect(Set(b.store.stamps(in: "고양이").map(\.id)) == [cat1, cat2])
        #expect(b.store.count(in: CollectionStore.defaultAlbum) == 0)
    }

    // MARK: - 테두리 · 글자

    @Test func plainDecorLeavesImageAlone() {
        let img = TestSupport.image(.red, size: CGSize(width: 40, height: 40))
        #expect(StickerDecor().apply(to: img) === img)
    }

    @Test func outlineGrowsCanvasEvenly() {
        let img = TestSupport.image(.red, size: CGSize(width: 100, height: 60))
        let cg = try! #require(img.cgImage)
        let out = StickerDecor(outline: .thick, color: 0xFFFFFF).apply(to: img)
        let ocg = try! #require(out.cgImage)
        #expect(ocg.width > cg.width)
        #expect(ocg.width - cg.width == ocg.height - cg.height)   // 사방 같은 두께
    }

    @Test func decorIsStoredPerSticker() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add(.red)
        h.store.setStickerDecor(StickerDecor(outline: .medium, color: 0xFFD60A, label: " 안녕 "), for: id)
        let d = h.reopen().stickerDecor(for: id)
        #expect(d.outline == .medium)
        #expect(d.color == 0xFFD60A)
        #expect(d.label == "안녕")
    }

    // MARK: - 찾기

    @Test func searchMatchesCaptionAlbumAndLabel() {
        let h = Harness(); defer { h.cleanup() }
        let sea = h.add(.blue)
        h.store.setCaption("제주 바다", for: sea)
        h.store.createAlbum("고양이")
        let cat = h.add(.orange)
        h.store.setStickerDecor(StickerDecor(label: "냥"), for: cat)

        #expect(h.store.search("바다").map(\.id) == [sea])
        #expect(h.store.search("고양이").map(\.id) == [cat])
        #expect(h.store.search("냥").map(\.id) == [cat])
        #expect(h.store.search("제주 바다").map(\.id) == [sea])
        #expect(h.store.search("제주 고양이").isEmpty)
        #expect(h.store.search("   ").isEmpty)
    }
}
