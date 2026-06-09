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

    @Test func placeMovesStampOutOfCollection() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.placeInExhibition(id, into: "벽1")
        #expect(h.store.isExhibited(id))
        #expect(h.store.collectedStamps.isEmpty)                                  // left the collection
        #expect(h.store.count(in: CollectionStore.defaultAlbum) == 0)             // album count drops
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

    @Test func reorderByMovingToIndex() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add(), c = h.add()
        for id in [a, b, c] { h.store.placeInExhibition(id, into: "벽") }
        #expect(h.store.stampsInExhibition("벽").map(\.id) == [a, b, c])
        h.store.reorderExhibition("벽", moving: c, to: 0)
        #expect(h.store.stampsInExhibition("벽").map(\.id) == [c, a, b])
    }

    @Test func reorderByOffsets() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add(), c = h.add()
        for id in [a, b, c] { h.store.placeInExhibition(id, into: "벽") }
        h.store.reorderExhibition("벽", from: IndexSet(integer: 0), to: 3)  // a → end
        #expect(h.store.stampsInExhibition("벽").map(\.id) == [b, c, a])
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

    @Test func exhibitionsAndOrderReloadFromDisk() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add(), c = h.add()
        for id in [a, b, c] { h.store.placeInExhibition(id, into: "벽") }
        h.store.reorderExhibition("벽", moving: a, to: 2)   // [b, c, a]

        let again = h.reopen()
        #expect(again.exhibitions.map(\.name) == ["벽"])
        #expect(again.stampsInExhibition("벽").map(\.id) == [b, c, a])
        #expect(again.collectedStamps.isEmpty)              // all three are exhibited
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

    @Test func backgroundSurvivesRenameAndReorder() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(), b = h.add()
        h.store.createExhibition("벽", background: .dot)
        h.store.placeInExhibition(a, into: "벽")
        h.store.placeInExhibition(b, into: "벽")
        h.store.reorderExhibition("벽", moving: b, to: 0)
        h.store.renameExhibition("벽", to: "새벽")
        #expect(h.store.backgroundStyle(of: "새벽") == .dot)
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
