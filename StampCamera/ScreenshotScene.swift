//
//  ScreenshotScene.swift
//  StampCamera
//
//  DEBUG 전용 — 스토어 스크린샷을 시뮬레이터에서 재현 가능하게 찍기 위한 장치.
//  시뮬레이터엔 카메라가 없고 손으로 탭할 수도 없으니, 실행 인자로 앱이 스스로
//  사진을 담고 원하는 화면을 연다. 출시 빌드에는 들어가지 않는다.
//
//    -ScreenshotSeed <폴더>    폴더의 사진(이름순)을 기본 모양 스티커로 담는다.
//                             파일 이름 앞 "a-" / "b-" … 는 담을 수집함을 고른다(아래 albums).
//    -ScreenshotScene <장면>  camera · reveal · album · detail · arrange · settings
//
//  scripts/capture_screenshots.sh 가 이 둘로 docs/screenshots/raw/ko/ 를 다시 찍는다.
//

#if DEBUG
import SwiftUI

enum ScreenshotScene {
    static var seedDir: String? { UserDefaults.standard.string(forKey: "ScreenshotSeed") }
    static var scene: String? { UserDefaults.standard.string(forKey: "ScreenshotScene") }
    static var isActive: Bool { scene != nil }

    /// Albums the seed photos are filed into, by file-name prefix — with the
    /// paper each one wears.
    private static let albums: [(prefix: String, name: String, paper: BackgroundStyle)] = [
        ("a-", "일상 스티커", .cream),
        ("b-", "카페 기록", .kraft),
    ]
    /// A line and a place for the first few, so detail / album look lived-in.
    private static let notes: [String: (caption: String, place: String)] = [
        "a-01": ("산책 가자고 하면 이렇게 일어서요", "서울숲"),
        "a-02": ("오늘도 창가 자리 차지", "망원동"),
        "b-01": ("비 오는 날의 라테", "연남동"),
    ]

    /// The photo the camera window shows instead of the (absent) live preview.
    static var cameraBackdrop: UIImage? {
        guard isActive, let dir = seedDir else { return nil }
        return UIImage(contentsOfFile: (dir as NSString).appendingPathComponent("backdrop.jpg"))
    }

    /// The simulator can't run Vision's subject lift, so the seed folder carries
    /// cutouts made on the Mac with the same pipeline (tools/lift_subjects.swift):
    /// `cut/<file>.png`. When one is missing, the crop it should be made from is
    /// written to `crop/<file>.png` for the next pass.
    private static func hostCutout(for file: String, crop: UIImage, in dir: String) -> UIImage? {
        let name = (file as NSString).deletingPathExtension + ".png"
        let cut = ((dir as NSString).appendingPathComponent("cut") as NSString).appendingPathComponent(name)
        if let img = UIImage(contentsOfFile: cut) { return img }
        let cropDir = (dir as NSString).appendingPathComponent("crop")
        try? FileManager.default.createDirectory(atPath: cropDir, withIntermediateDirectories: true)
        try? crop.pngData()?.write(to: URL(fileURLWithPath: (cropDir as NSString).appendingPathComponent(name)))
        return nil
    }

    /// Files the seed photos, one by one, the same way 사진 가져오기 does.
    /// Returns the ids in filing order.
    @MainActor
    static func seed(_ store: CollectionStore) async -> [String] {
        guard let dir = seedDir, store.stamps.isEmpty else { return store.stamps.map(\.id) }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".jpg") && $0 != "backdrop.jpg" }
            .sorted()
        var ids: [String] = []
        for (i, album) in albums.enumerated() {
            // the first one takes over the empty default 내 수집함
            if i == 0, store.albums == [CollectionStore.defaultAlbum] {
                store.renameAlbum(CollectionStore.defaultAlbum, to: album.name)
            } else {
                store.createAlbum(album.name)
            }
            store.setBackground(album.paper, for: album.name)
            for file in files where file.hasPrefix(album.prefix) {
                guard let photo = UIImage(contentsOfFile: (dir as NSString).appendingPathComponent(file)),
                      let base = StampCompositor.centerCrop(photo, aspect: StampFrameLoader.windowAspect)
                else { continue }
                let cut = await Task.detached { SubjectLift.cutout(from: base.image) }.value
                    ?? hostCutout(for: file, crop: base.image, in: dir)
                let style: StampStyle = cut != nil ? .sticker : .stamp
                let still = cut ?? CollectionStore.stillLook(base.image, style: .stamp)
                let id = store.add(still, original: photo, cropNorm: base.cropNorm)
                store.recordStyle(style, for: id)
                let key = String(file.prefix(4))
                if let note = notes[key] {
                    store.setCaption(note.caption, for: id)
                    store.setPlace(note.place, for: id)
                }
                ids.append(id)
                try? await Task.sleep(for: .milliseconds(3))   // distinct ms ids
            }
        }
        // NEW only on the two freshest — a few badges read as "just made", all of them as clutter
        for id in ids.dropLast(2) { store.markSeen(id) }
        store.setActive(albums[0].name)
        UserDefaults.standard.set(albums[0].name, forKey: "lastVisitedAlbum")
        return ids
    }
}
#endif
