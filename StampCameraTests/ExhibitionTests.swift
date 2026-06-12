//
//  ExhibitionTests.swift
//  StampCameraTests
//
//  Hanging stamps on exhibition walls: membership, ordering, persistence.
//

import Testing
import Foundation
@testable import StampCamera

@MainActor
struct ExhibitionTests {

    @Test func createExhibition() {
        let h = Harness(); defer { h.cleanup() }
        #expect(h.store.createExhibition("제주") == "제주")
        #expect(h.store.exhibitions.map(\.name) == ["제주"])
        #expect(h.store.createExhibition("   ") == nil)   // blank rejected
    }

    @Test func placeKeepsStampInCollection() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.placeInExhibition(id, into: "벽1")
        #expect(h.store.isExhibited(id))
        // 컬렉션은 참조(플레이리스트) — 수집함에서는 빠지지 않는다
        #expect(h.store.collectedStamps.map(\.id) == [id])
        #expect(h.store.count(in: CollectionStore.defaultAlbum) == 1)
        #expect(h.store.stampsInExhibition("벽1").map(\.id) == [id])
        #expect(h.store.exhibitionCount("벽1") == 1)
    }

    @Test func returnBringsStampBackToItsAlbum() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.placeInExhibition(id, into: "벽1")
        h.store.returnToCollection(id)
        #expect(!h.store.isExhibited(id))
        #expect(h.store.collectedStamps.map(\.id) == [id])
        #expect(h.store.count(in: CollectionStore.defaultAlbum) == 1)
        #expect(h.store.stampsInExhibition("벽1").isEmpty)
    }

    @Test func singleMembershipAcrossExhibitions() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.placeInExhibition(id, into: "A")
        h.store.placeInExhibition(id, into: "B")   // moves, not duplicates
        #expect(h.store.stampsInExhibition("A").isEmpty)
        #expect(h.store.stampsInExhibition("B").map(\.id) == [id])
    }

    @Test func moveExhibitedBetweenWalls() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.placeInExhibition(id, into: "A")
        h.store.moveExhibitedStamp(id, to: "B")
        #expect(h.store.stampsInExhibition("A").isEmpty)
        #expect(h.store.stampsInExhibition("B").map(\.id) == [id])
    }

    @Test func placeAtFreePosition() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add()
        h.store.place(a, into: "벽", page: 0, x: 0.2, y: 0.3)
        h.store.place(b, into: "벽", page: 1, x: 0.8, y: 0.7)
        let pls = h.store.placements(in: "벽")
        #expect(pls.count == 2)
        #expect(pls.first { $0.id == a }?.page == 0)
        #expect(pls.first { $0.id == b }?.page == 1)
        #expect(abs((pls.first { $0.id == a }?.x ?? 0) - 0.2) < 0.0001)
        #expect(h.store.exhibitionCount("벽") == 2)
    }

    @Test func placingSameStampMovesItToFront() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add()
        h.store.place(a, into: "벽", page: 0, x: 0.2, y: 0.2)
        h.store.place(b, into: "벽", page: 0, x: 0.5, y: 0.5)
        h.store.place(a, into: "벽", page: 1, x: 0.9, y: 0.1)   // move a
        let pls = h.store.placements(in: "벽")
        #expect(pls.count == 2)              // not duplicated
        #expect(pls.last?.id == a)           // moved → drawn last (front)
        #expect(pls.first { $0.id == a }?.page == 1)
    }

    @Test func renameExhibition() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.placeInExhibition(id, into: "옛이름")
        h.store.renameExhibition("옛이름", to: "새이름")
        #expect(h.store.exhibitions.map(\.name) == ["새이름"])
        #expect(h.store.stampsInExhibition("새이름").map(\.id) == [id])
    }

    @Test func deleteExhibitionReturnsStampsNotDeletes() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.placeInExhibition(id, into: "벽")
        h.store.deleteExhibition("벽")
        #expect(h.store.exhibitions.isEmpty)
        #expect(h.store.stamps.contains(where: { $0.id == id }))   // stamp still exists
        #expect(h.store.collectedStamps.map(\.id) == [id])         // back in the collection
    }

    @Test func deletingStampRemovesItFromWall() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add()
        h.store.placeInExhibition(a, into: "벽")
        h.store.placeInExhibition(b, into: "벽")
        h.store.delete(a)
        #expect(h.store.stampsInExhibition("벽").map(\.id) == [b])
    }

    // MARK: - Persistence

    @Test func placementsReloadFromDisk() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add(), c = h.add()
        h.store.place(a, into: "벽", page: 0, x: 0.25, y: 0.75)
        h.store.place(b, into: "벽", page: 2, x: 0.6, y: 0.4)
        h.store.place(c, into: "벽", page: 2, x: 0.1, y: 0.9)

        let again = h.reopen()
        #expect(again.exhibitions.map(\.name) == ["벽"])
        let pls = again.placements(in: "벽")
        #expect(pls.count == 3)                                      // layout survives
        #expect(pls.first { $0.id == b }?.page == 2)
        #expect(again.collectedStamps.count == 3)                    // 걸어도 수집함엔 그대로
    }

    @Test func backwardCompatNoExhibitionsFile() {
        let h = Harness(); defer { h.cleanup() }
        h.add(); h.add()
        // no exhibitions.json was ever written
        let again = h.reopen()
        #expect(again.exhibitions.isEmpty)
        #expect(again.collectedStamps.count == 2)           // everything still collected
    }

    // MARK: - Backgrounds

    @Test func createWithBackgroundPersists() {
        let h = Harness(); defer { h.cleanup() }
        h.store.createExhibition("모눈전시", background: .grid)
        #expect(h.store.backgroundStyle(of: "모눈전시") == .grid)
        #expect(h.reopen().backgroundStyle(of: "모눈전시") == .grid)
    }

    @Test func defaultBackgroundIsCream() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.placeInExhibition(id, into: "벽")     // created implicitly
        #expect(h.store.backgroundStyle(of: "벽") == .cream)
    }

    @Test func setBackgroundChangesAndPersists() {
        let h = Harness(); defer { h.cleanup() }
        h.store.createExhibition("벽", background: .cream)
        h.store.setExhibitionBackground("벽", to: .kraft)
        #expect(h.store.backgroundStyle(of: "벽") == .kraft)
        #expect(h.reopen().backgroundStyle(of: "벽") == .kraft)
    }

    @Test func backgroundSurvivesRenameAndRearrange() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add()
        h.store.createExhibition("벽", background: .dot)
        h.store.place(a, into: "벽", page: 0, x: 0.3, y: 0.3)
        h.store.place(b, into: "벽", page: 0, x: 0.6, y: 0.6)
        h.store.renameExhibition("벽", to: "새벽")
        #expect(h.store.backgroundStyle(of: "새벽") == .dot)
        #expect(h.store.placements(in: "새벽").count == 2)   // arrangement carried through rename
    }

    @Test func legacyExhibitionsFileWithoutBackgroundDefaultsCream() throws {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        let json = #"{"exhibitions":[{"name":"벽","stampIDs":["\#(id)"]}]}"#   // no "background" key
        try json.data(using: .utf8)!.write(to: h.dir.appendingPathComponent("exhibitions.json"))
        #expect(h.reopen().backgroundStyle(of: "벽") == .cream)
    }

    @Test func allTenBackgroundStylesExist() {
        #expect(BackgroundStyle.allCases.count == 10)
    }

    @Test func reconcileDropsOrphanIDs() throws {
        let h = Harness(); defer { h.cleanup() }
        let real = h.add()
        // hand-write an exhibitions file that references a ghost id
        let json = #"{"exhibitions":[{"name":"벽","stampIDs":["\#(real)","ghost.png"]}]}"#
        try json.data(using: .utf8)!.write(to: h.dir.appendingPathComponent("exhibitions.json"))

        let again = h.reopen()   // reconcile runs on init
        #expect(again.stampsInExhibition("벽").map(\.id) == [real])  // ghost dropped
    }
}
