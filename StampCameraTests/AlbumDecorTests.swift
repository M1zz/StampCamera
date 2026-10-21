//
//  AlbumDecorTests.swift
//  StampCameraTests
//
//  수집함 하나로 묶기 (IDENTITY.md §3·§5): each album's paper and hand-arranged
//  order (자유롭게 꾸미기), and the one-time move of old 컬렉션 into 수집함.
//

import Testing
import Foundation
@testable import StampCamera

@MainActor
struct AlbumDecorTests {

    // MARK: - Order (자유롭게 꾸미기)

    @Test func albumIsInTimeOrderUntilArranged() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add(), c = h.add()
        let album = CollectionStore.defaultAlbum
        #expect(h.store.stamps(in: album).map(\.id) == [a, b, c])
        #expect(!h.store.isArranged(album))
    }

    @Test func reorderMovesAStickerAndPersists() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add(), c = h.add()
        let album = CollectionStore.defaultAlbum
        h.store.reorder(in: album, moving: c, to: 0)
        #expect(h.store.stamps(in: album).map(\.id) == [c, a, b])
        #expect(h.store.isArranged(album))
        #expect(h.reopen().stamps(in: album).map(\.id) == [c, a, b])
    }

    @Test func newCaptureLandsAfterTheArrangedOnes() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add()
        let album = CollectionStore.defaultAlbum
        h.store.reorder(in: album, moving: b, to: 0)
        let fresh = h.add()
        #expect(h.store.stamps(in: album).map(\.id) == [b, a, fresh])
    }

    @Test func resetOrderGoesBackToTimeOrder() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add()
        let album = CollectionStore.defaultAlbum
        h.store.reorder(in: album, moving: b, to: 0)
        h.store.resetOrder(album)
        #expect(h.store.stamps(in: album).map(\.id) == [a, b])
        #expect(!h.store.isArranged(album))
    }

    @Test func deletedOrMovedStickersDropOutOfTheOrder() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add(), c = h.add()
        let album = CollectionStore.defaultAlbum
        h.store.reorder(in: album, moving: c, to: 0)       // [c, a, b]
        h.store.delete(a)
        h.store.move(b, to: "여행")
        #expect(h.store.stamps(in: album).map(\.id) == [c])
        #expect(h.store.stamps(in: "여행").map(\.id) == [b])
    }

    // MARK: - Paper

    @Test func backgroundDefaultsToCreamAndPersists() {
        let h = Harness(); defer { h.cleanup() }
        let album = CollectionStore.defaultAlbum
        #expect(h.store.backgroundStyle(of: album) == .cream)
        h.store.setBackground(.kraft, for: album)
        #expect(h.store.backgroundStyle(of: album) == .kraft)
        #expect(h.reopen().backgroundStyle(of: album) == .kraft)
    }

    @Test func renameCarriesDecorAndDeleteDropsIt() {
        let h = Harness(); defer { h.cleanup() }
        h.store.createAlbum("제주")
        let a = h.add(), b = h.add()
        h.store.setBackground(.grid, for: "제주")
        h.store.reorder(in: "제주", moving: b, to: 0)
        h.store.renameAlbum("제주", to: "제주도")
        #expect(h.store.backgroundStyle(of: "제주도") == .grid)
        #expect(h.store.stamps(in: "제주도").map(\.id) == [b, a])
        #expect(h.store.decor["제주"] == nil)
        h.store.deleteAlbum("제주도")
        #expect(h.store.decor["제주도"] == nil)
    }

    // MARK: - 컬렉션 → 수집함 (one-time)

    private func writeLegacy(_ json: String, in h: Harness) throws {
        try Data(json.utf8).write(to: h.dir.appendingPathComponent("exhibitions.json"))
    }

    @Test func collectionsBecomeAlbumsWithTheirStickersPaperAndOrder() throws {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add(), c = h.add()
        try writeLegacy("""
        {"exhibitions":[{"name":"바다","background":"kraft",
          "placements":[{"id":"\(c)","page":0,"x":0.3,"y":0.3},{"id":"\(a)","page":0,"x":0.5,"y":0.5}]}]}
        """, in: h)

        let s = h.reopen()
        #expect(s.albums == [CollectionStore.defaultAlbum, "바다"])
        #expect(s.stamps(in: "바다").map(\.id) == [c, a])          // order kept
        #expect(s.stamps(in: CollectionStore.defaultAlbum).map(\.id) == [b])
        #expect(s.backgroundStyle(of: "바다") == .kraft)
        #expect(!h.fileExists("exhibitions.json"))
        #expect(h.fileExists("exhibitions.migrated.json"))      // kept, renamed
    }

    @Test func aNameAlreadyTakenGetsMarked() throws {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add()
        try writeLegacy("""
        {"exhibitions":[{"name":"\(CollectionStore.defaultAlbum)","placements":[{"id":"\(a)","page":0,"x":0.3,"y":0.3}]}]}
        """, in: h)
        let s = h.reopen()
        let marked = "\(CollectionStore.defaultAlbum) (컬렉션)"
        #expect(s.albums.contains(marked))
        #expect(s.stamps(in: marked).map(\.id) == [a])
    }

    @Test func legacySlotsAndMissingStickersAreHandled() throws {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add()
        try writeLegacy("""
        {"exhibitions":[
          {"name":"옛날","slots":["\(b)",null,"gone.png","\(a)"]},
          {"name":"빈 것","placements":[]},
          {"name":"중복","placements":[{"id":"\(a)","page":0,"x":0.1,"y":0.1}]}]}
        """, in: h)
        let s = h.reopen()
        #expect(s.stamps(in: "옛날").map(\.id) == [b, a])
        #expect(s.albums.contains("빈 것"))                     // the user made it — keep it
        #expect(s.stamps(in: "중복").isEmpty)                    // one sticker, one home
    }

    @Test func migrationRunsOnlyOnce() throws {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add()
        try writeLegacy("""
        {"exhibitions":[{"name":"바다","placements":[{"id":"\(a)","page":0,"x":0.3,"y":0.3}]}]}
        """, in: h)
        let first = h.reopen()
        first.move(a, to: CollectionStore.defaultAlbum)          // user moves it back
        let again = h.reopen()
        #expect(again.stamps(in: CollectionStore.defaultAlbum).map(\.id) == [a])
        #expect(again.albums.filter { $0.hasPrefix("바다") } == ["바다"])
    }
}
