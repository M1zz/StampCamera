//
//  CollectionStoreTests.swift
//  StampCameraTests
//
//  Stamps, albums, sidecar persistence, and the pre-crop original.
//

import Testing
import UIKit
@testable import StampCamera

@MainActor
struct CollectionStoreTests {

    // MARK: - Baseline

    @Test func freshStoreHasOneDefaultAlbum() {
        let h = Harness(); defer { h.cleanup() }
        #expect(h.store.albums == [CollectionStore.defaultAlbum])
        #expect(h.store.activeAlbum == CollectionStore.defaultAlbum)
        #expect(h.store.stamps.isEmpty)
        #expect(h.store.exhibitions.isEmpty)
        #expect(h.store.collectedStamps.isEmpty)
    }

    // MARK: - Add

    @Test func addStoresStampAndImageFile() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add(.red)
        #expect(h.store.stamps.count == 1)
        #expect(h.store.stamps.first?.id == id)
        #expect(h.store.stamps.first?.album == CollectionStore.defaultAlbum)
        #expect(h.store.stamps.first?.caption == "")
        #expect(h.fileExists(id))                 // the png itself
        #expect(h.fileExists(id + ".grp"))        // album sidecar
        #expect(h.fileExists(id + ".json"))       // meta sidecar
    }

    @Test func addGivesDistinctIDsAndCounts() {
        let h = Harness(); defer { h.cleanup() }
        let a = h.add(.red), b = h.add(.green), c = h.add(.blue)
        #expect(Set([a, b, c]).count == 3)
        #expect(h.store.stamps.count == 3)
        #expect(h.store.count(in: CollectionStore.defaultAlbum) == 3)
        #expect(h.store.collectedStamps.count == 3)
    }

    @Test func addGoesIntoActiveAlbum() {
        let h = Harness(); defer { h.cleanup() }
        h.store.createAlbum("여행")
        let id = h.add()
        #expect(h.store.stamps.first(where: { $0.id == id })?.album == "여행")
    }

    // MARK: - Caption / place / move

    @Test func captionPersists() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.setCaption("좋은 순간", for: id)
        #expect(h.store.stamps.first?.caption == "좋은 순간")
        #expect(h.reopen().stamps.first?.caption == "좋은 순간")
    }

    @Test func placePersists() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.setPlace("서울 종로구", for: id)
        #expect(h.store.stamps.first?.place == "서울 종로구")
        #expect(h.reopen().stamps.first?.place == "서울 종로구")
    }

    @Test func moveChangesAlbumAndPersists() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.createAlbum("여행")          // also becomes active
        h.store.move(id, to: "여행")
        #expect(h.store.stamps.first?.album == "여행")
        #expect(h.reopen().stamps.first?.album == "여행")
    }

    @Test func moveToUnknownAlbumCreatesIt() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.move(id, to: "새앨범")
        #expect(h.store.albums.contains("새앨범"))
        #expect(h.store.stamps.first?.album == "새앨범")
    }

    // MARK: - Delete

    @Test func deleteRemovesStampAndAllSidecars() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add(.red, original: TestSupport.image(.blue))
        h.store.setCaption("x", for: id)
        #expect(h.fileExists(id + ".orig.jpg"))
        h.store.delete(id)
        #expect(h.store.stamps.isEmpty)
        #expect(!h.fileExists(id))
        #expect(!h.fileExists(id + ".txt"))
        #expect(!h.fileExists(id + ".grp"))
        #expect(!h.fileExists(id + ".json"))
        #expect(!h.fileExists(id + ".orig.jpg"))
        #expect(h.reopen().stamps.isEmpty)
    }

    // MARK: - Albums

    @Test func createAlbumActivatesIt() {
        let h = Harness(); defer { h.cleanup() }
        h.store.createAlbum("봄꽃")
        #expect(h.store.albums.contains("봄꽃"))
        #expect(h.store.activeAlbum == "봄꽃")
    }

    @Test func createAlbumRejectsBlank() {
        let h = Harness(); defer { h.cleanup() }
        #expect(h.store.createAlbum("   ") == nil)
        #expect(h.store.albums == [CollectionStore.defaultAlbum])
    }

    @Test func setActiveOnlyForExisting() {
        let h = Harness(); defer { h.cleanup() }
        h.store.setActive("없는앨범")
        #expect(h.store.activeAlbum == CollectionStore.defaultAlbum)
    }

    @Test func renameAlbumMovesStamps() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add()
        h.store.renameAlbum(CollectionStore.defaultAlbum, to: "내앨범")
        #expect(h.store.albums.contains("내앨범"))
        #expect(!h.store.albums.contains(CollectionStore.defaultAlbum))
        #expect(h.store.stamps.first(where: { $0.id == id })?.album == "내앨범")
        #expect(h.reopen().stamps.first?.album == "내앨범")
    }

    @Test func deleteAlbumRemovesItsStampsButKeepsOne() {
        let h = Harness(); defer { h.cleanup() }
        let keep = h.add()                 // in default album
        h.store.createAlbum("여행")
        let gone = h.add()                 // in 여행
        h.store.deleteAlbum("여행")
        #expect(!h.store.albums.contains("여행"))
        #expect(h.store.albums.count >= 1)
        #expect(h.store.stamps.contains(where: { $0.id == keep }))
        #expect(!h.store.stamps.contains(where: { $0.id == gone }))
    }

    @Test func deleteAlbumRefusesToRemoveLastAlbum() {
        let h = Harness(); defer { h.cleanup() }
        h.store.deleteAlbum(CollectionStore.defaultAlbum)
        #expect(h.store.albums == [CollectionStore.defaultAlbum])
    }

    @Test func stampsInAlbumFilters() {
        let h = Harness(); defer { h.cleanup() }
        h.add()                                   // default
        h.store.createAlbum("여행"); h.add()       // 여행
        #expect(h.store.count(in: CollectionStore.defaultAlbum) == 1)
        #expect(h.store.count(in: "여행") == 1)
        #expect(h.store.stamps(in: "여행").count == 1)
    }

    // MARK: - Persistence round-trip

    @Test func everythingReloadsFromDisk() {
        let h = Harness(); defer { h.cleanup() }
        h.store.createAlbum("여행")
        let id = h.add()
        h.store.setCaption("바다", for: id)
        h.store.setPlace("부산", for: id)

        let again = h.reopen()
        let s = again.stamps.first
        #expect(again.stamps.count == 1)
        #expect(s?.album == "여행")
        #expect(s?.caption == "바다")
        #expect(s?.place == "부산")
        #expect(again.albums.contains("여행"))
    }

    // MARK: - Original photo + crop metadata

    @Test func originalImageSavedAndLoadable() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add(.red, original: TestSupport.image(.green, size: CGSize(width: 40, height: 30)))
        let original = h.store.originalImage(for: id)
        #expect(original != nil)
        // re-opened store can still load it from disk
        #expect(h.reopen().originalImage(for: id) != nil)
    }

    @Test func noOriginalWhenNotProvided() {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add(.red)              // no original
        #expect(h.store.originalImage(for: id) == nil)
    }

    @Test func cropMetadataWrittenToSidecar() throws {
        let h = Harness(); defer { h.cleanup() }
        let id = h.add(.red,
                       original: TestSupport.image(.blue),
                       cropNorm: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                       mirrored: true)
        let json = h.dir.appendingPathComponent(id + ".json")
        let data = try Data(contentsOf: json)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((dict["cropX"] as? Double) == 0.1)
        #expect((dict["cropY"] as? Double) == 0.2)
        #expect((dict["cropW"] as? Double) == 0.3)
        #expect((dict["cropH"] as? Double) == 0.4)
        #expect((dict["mirrored"] as? Bool) == true)
    }

    @Test func legacyStampWithoutMetaStillLoads() throws {
        let h = Harness(); defer { h.cleanup() }
        // hand-write a bare png with no .json sidecar (a "legacy" stamp)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000)).png"
        try TestSupport.image(.gray).pngData()!.write(to: h.dir.appendingPathComponent(name))
        let store = h.reopen()
        #expect(store.stamps.contains(where: { $0.id == name }))
        #expect(store.stamps.first?.place == "")   // place defaults empty
    }
}
