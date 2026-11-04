//
//  OpenKkukCameraIntent.swift
//  StampCamera  (shared with the KkukControls widget extension)
//
//  The App Intent behind the Control Center / Lock Screen control. Running it
//  foregrounds the app and routes straight to the live camera.
//
//  ⚠️ Target membership: add this file to BOTH the StampCamera app target and
//  the KkukControls widget-extension target (File Inspector ▸ Target Membership)
//  so the control can reference the intent and the app can run it.
//

import AppIntents
import CoreSpotlight

struct OpenKkukCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "펀칭 카메라 열기"
    static let description = IntentDescription("펀칭 카메라를 바로 엽니다.")

    // Foreground the app when the control is tapped; `perform()` then runs in
    // the app process, where the router lives.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CameraLaunchRouter.shared.requestCamera()
        return .result()
    }
}

/// Surfaces "펀칭 카메라 열기" as a system App Shortcut. This alone lets the user
/// add a camera button to Control Center and the Lock Screen via the Shortcuts
/// app today — the dedicated ControlWidget (KkukControls) is the polished
/// one-tap version on top of the same intent.
struct KkukAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenKkukCameraIntent(),
            phrases: [
                "\(.applicationName) 열기",
                "\(.applicationName)으로 사진 찍기"
            ],
            shortTitle: "카메라 열기",
            systemImageName: "camera.fill"
        )
    }
}

// MARK: - 스티커 (Siri · Spotlight)
//
// 수집함에 모은 스티커를 Siri · Spotlight 가 찾게 한다. 글귀 · 수집함 이름 · 장소로 찾고,
// 누르면 그 스티커가 열린다. 인텐트는 화면 없이도 돌기 때문에 CollectionStore 를 거치지 않고
// Documents/Collection 의 곁 파일(.txt 글귀 · .grp 수집함 · .json 때와 곳)만 바로 읽는다(그림은 읽지 않는다).
// 색인(IndexedEntity)은 iOS 18 부터라 그 부분만 나눠 둔다.

struct StampEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("스티커", comment: "Siri/Spotlight: one collected sticker")
    )
    static let defaultQuery = StampQuery()

    let id: String
    let caption: String
    let album: String
    let place: String
    let createdAt: Date
    let imageURL: URL

    var displayRepresentation: DisplayRepresentation {
        let title = caption.isEmpty ? createdAt.formatted(date: .abbreviated, time: .omitted) : caption
        let subtitle = [album, place].filter { !$0.isEmpty }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: .init(url: imageURL))
    }
}

@available(iOS 18.0, *)
extension StampEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.textContent = [caption, album, place].filter { !$0.isEmpty }.joined(separator: "\n")
        set.thumbnailURL = imageURL
        set.contentCreationDate = createdAt
        return set
    }
}

struct StampQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [StampEntity] {
        let wanted = Set(identifiers)
        return StampLibrary.all().filter { wanted.contains($0.id) }
    }

    /// 글귀 · 수집함 이름 · 장소에서 찾는다(대소문자 · 악센트 무시).
    func entities(matching string: String) async throws -> [StampEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        func matches(_ s: String) -> Bool { s.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return StampLibrary.all().filter { matches($0.caption) || matches($0.album) || matches($0.place) }
    }

    /// 가장 최근에 뜯은 스티커부터.
    func suggestedEntities() async throws -> [StampEntity] {
        Array(StampLibrary.all().reversed().prefix(20))
    }
}

/// 스티커를 연다. Spotlight · Siri 결과를 누르면 여기로 온다.
struct OpenStampIntent: OpenIntent {
    static let title = LocalizedStringResource("스티커 열기", comment: "Siri/Spotlight: open a collected sticker")
    static let description = IntentDescription(
        LocalizedStringResource("수집함에 모은 스티커 하나를 열어 봅니다.", comment: "Siri: open sticker description")
    )

    @Parameter(title: LocalizedStringResource("스티커", comment: "Siri/Spotlight: one collected sticker"),
               description: LocalizedStringResource("열어 볼 스티커", comment: "Siri: sticker parameter description"))
    var target: StampEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        CameraLaunchRouter.shared.stampRequest = target.id
        return .result()
    }
}

enum StampLibrary {
    static var directory: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Collection", isDirectory: true)
    }

    /// CollectionStore 가 쓰는 곁 파일의 때와 곳만 읽는다.
    private struct Meta: Decodable {
        var createdAt: Date
        var place: String?
    }

    /// 수집함의 스티커들, 뜯은 순서대로. 스티커 하나는 "<ms>.png" (움직이는 ".live.png" 는 곁 파일).
    static func all() -> [StampEntity] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "png" && !$0.lastPathComponent.hasSuffix(".live.png") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                func text(_ ext: String) -> String {
                    ((try? String(contentsOf: url.appendingPathExtension(ext), encoding: .utf8)) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let meta = (try? Data(contentsOf: url.appendingPathExtension("json")))
                    .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
                let ms = Double(url.deletingPathExtension().lastPathComponent) ?? 0
                return StampEntity(
                    id: url.lastPathComponent,
                    caption: text("txt"),
                    album: text("grp"),
                    place: meta?.place ?? "",
                    createdAt: meta?.createdAt ?? Date(timeIntervalSince1970: ms / 1000),
                    imageURL: url
                )
            }
    }

    /// 앱을 열 때와 뒤로 보낼 때 부른다. 지운 스티커가 남지 않게 통째로 다시 싣는다.
    static func reindex() async {
        guard #available(iOS 18.0, *) else { return }
        let index = CSSearchableIndex.default()
        try? await index.deleteAppEntities(ofType: StampEntity.self)
        try? await index.indexAppEntities(all())
    }
}
