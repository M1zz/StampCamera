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
//  scripts/capture_screenshots.sh 가 이 둘로 docs/screenshots/raw/<언어>/ 를 다시 찍는다.
//  수집함 이름 · 한 줄 기록 · 장소는 앱 언어를 따른다(SeedText).
//

#if DEBUG
import SwiftUI

enum ScreenshotScene {
    static var seedDir: String? { UserDefaults.standard.string(forKey: "ScreenshotSeed") }
    static var scene: String? { UserDefaults.standard.string(forKey: "ScreenshotScene") }
    static var isActive: Bool { scene != nil }

    /// Albums the seed photos are filed into, by file-name prefix — with the
    /// paper each one wears. Names and notes follow the app's language, so each
    /// store locale's screenshots read as that country's own album.
    private static var albums: [(prefix: String, name: String, paper: BackgroundStyle)] {
        let t = SeedText.current
        return [("a-", t.albumA, .cream), ("b-", t.albumB, .kraft)]
    }
    /// A line and a place for the first few, so detail / album look lived-in.
    private static var notes: [String: (caption: String, place: String)] {
        let t = SeedText.current
        return ["a-01": t.walk, "a-02": t.window, "b-01": t.latte]
    }

    private struct SeedText {
        let albumA: String, albumB: String
        let walk: (String, String), window: (String, String), latte: (String, String)

        static var current: SeedText {
            let lang = Locale.preferredLanguages.first ?? "ko"
            let keys = [lang, String(lang.prefix(7)), String(lang.prefix(2))]
            for k in keys { if let t = table[k] { return t } }
            // zh-Hant-TW → zh-Hant, en-GB-… → en-GB, pt-BR → pt-BR
            for (k, t) in table where lang.hasPrefix(k) { return t }
            return table["ko"]!
        }

        static let table: [String: SeedText] = [
            "ko": .init(albumA: "일상 스티커", albumB: "카페 기록",
                        walk: ("산책 가자고 하면 이렇게 일어서요", "서울숲"),
                        window: ("오늘도 창가 자리 차지", "망원동"),
                        latte: ("비 오는 날의 라테", "연남동")),
            "en": .init(albumA: "Everyday", albumB: "Café Diary",
                        walk: ("This is what “walk?” does to him", "Prospect Park"),
                        window: ("Window seat, claimed again", "Brooklyn"),
                        latte: ("Rainy-day latte", "Williamsburg")),
            "en-GB": .init(albumA: "Everyday", albumB: "Café Diary",
                        walk: ("This is what “walkies?” does to him", "Hampstead Heath"),
                        window: ("Window seat, bagged again", "Islington"),
                        latte: ("Rainy-day flat white", "Shoreditch")),
            "ja": .init(albumA: "日常ステッカー", albumB: "カフェ日記",
                        walk: ("「散歩行く？」でこの立ち上がり", "代々木公園"),
                        window: ("今日も窓際は私の席", "吉祥寺"),
                        latte: ("雨の日のラテ", "中目黒")),
            "zh-Hans": .init(albumA: "日常贴纸", albumB: "咖啡日记",
                        walk: ("一说“出去玩”就站起来了", "世纪公园"),
                        window: ("今天也霸占了窗边", "武康路"),
                        latte: ("下雨天的拿铁", "安福路")),
            "zh-Hant": .init(albumA: "日常貼圖", albumB: "咖啡日記",
                        walk: ("一說要散步就站起來了", "大安森林公園"),
                        window: ("今天也霸佔窗邊位", "赤峰街"),
                        latte: ("下雨天的拿鐵", "富錦街")),
            "ru": .init(albumA: "Каждый день", albumB: "Кофейный дневник",
                        walk: ("Вот что делает слово «гулять»", "Парк Горького"),
                        window: ("Место у окна снова занято", "Патриаршие"),
                        latte: ("Латте в дождливый день", "Чистые пруды")),
            "es": .init(albumA: "Día a día", albumB: "Diario de cafés",
                        walk: ("Así se pone cuando oye «paseo»", "El Retiro"),
                        window: ("Otra vez el sitio junto a la ventana", "Malasaña"),
                        latte: ("Latte de día lluvioso", "Lavapiés")),
            "de": .init(albumA: "Alltag", albumB: "Café-Tagebuch",
                        walk: ("So reagiert er auf „Gassi?“", "Tempelhofer Feld"),
                        window: ("Fensterplatz – schon wieder meiner", "Prenzlauer Berg"),
                        latte: ("Latte an einem Regentag", "Kreuzberg")),
            "fr": .init(albumA: "Au quotidien", albumB: "Journal de cafés",
                        walk: ("Voilà l’effet du mot « balade »", "Buttes-Chaumont"),
                        window: ("La place près de la fenêtre, encore", "Le Marais"),
                        latte: ("Un latte un jour de pluie", "Canal Saint-Martin")),
            "it": .init(albumA: "Ogni giorno", albumB: "Diario dei caffè",
                        walk: ("Ecco cosa succede se dico «passeggiata»", "Parco Sempione"),
                        window: ("Anche oggi il posto alla finestra", "Brera"),
                        latte: ("Latte macchiato in un giorno di pioggia", "Navigli")),
            "pt-BR": .init(albumA: "Dia a dia", albumB: "Diário de cafés",
                        walk: ("É só falar “passear” que ele levanta", "Ibirapuera"),
                        window: ("Lugar na janela, de novo", "Vila Madalena"),
                        latte: ("Latte de dia chuvoso", "Pinheiros")),
            "th": .init(albumA: "สติกเกอร์ทุกวัน", albumB: "บันทึกคาเฟ่",
                        walk: ("แค่พูดว่าไปเดินเล่นก็ลุกทันที", "สวนลุมพินี"),
                        window: ("วันนี้ก็ได้ที่ริมหน้าต่างอีกแล้ว", "อารีย์"),
                        latte: ("ลาเต้วันฝนตก", "ทองหล่อ")),
            "vi": .init(albumA: "Thường ngày", albumB: "Nhật ký cà phê",
                        walk: ("Cứ nghe “đi dạo” là đứng dậy ngay", "Hồ Tây"),
                        window: ("Hôm nay lại chiếm chỗ cạnh cửa sổ", "Phố cổ"),
                        latte: ("Ly latte ngày mưa", "Quận 1")),
            "cs": .init(albumA: "Všední dny", albumB: "Kavárenský deník",
                        walk: ("Takhle reaguje na slovo „procházka“", "Stromovka"),
                        window: ("Místo u okna je zase moje", "Vinohrady"),
                        latte: ("Latte v deštivém dni", "Karlín")),
            "da": .init(albumA: "Hverdag", albumB: "Café-dagbog",
                        walk: ("Sådan reagerer han på ordet “gåtur”", "Fælledparken"),
                        window: ("Vinduespladsen er min igen", "Nørrebro"),
                        latte: ("Latte på en regnvejrsdag", "Vesterbro")),
            "el": .init(albumA: "Καθημερινά", albumB: "Ημερολόγιο καφέ",
                        walk: ("Έτσι κάνει όταν ακούει «βόλτα»", "Πεδίον του Άρεως"),
                        window: ("Πάλι η θέση δίπλα στο παράθυρο", "Κουκάκι"),
                        latte: ("Λάτε σε βροχερή μέρα", "Ψυρρή")),
            "fi": .init(albumA: "Arki", albumB: "Kahvilapäiväkirja",
                        walk: ("Tältä näyttää, kun sanon ”lenkille”", "Kaivopuisto"),
                        window: ("Ikkunapaikka taas varattu", "Kallio"),
                        latte: ("Sadepäivän latte", "Punavuori")),
            "id": .init(albumA: "Sehari-hari", albumB: "Catatan Kafe",
                        walk: ("Begini kalau dengar kata “jalan-jalan”", "GBK"),
                        window: ("Kursi dekat jendela, lagi-lagi punyaku", "Kemang"),
                        latte: ("Latte di hari hujan", "Senopati")),
            "nb": .init(albumA: "Hverdag", albumB: "Kafédagbok",
                        walk: ("Sånn reagerer han på ordet «tur»", "Frognerparken"),
                        window: ("Vindusplassen er min igjen", "Grünerløkka"),
                        latte: ("Latte på en regnværsdag", "Majorstuen")),
            "nl": .init(albumA: "Alledaags", albumB: "Koffiedagboek",
                        walk: ("Zo reageert hij op ‘wandelen?’", "Vondelpark"),
                        window: ("Weer het plekje bij het raam", "De Pijp"),
                        latte: ("Latte op een regenachtige dag", "Jordaan")),
            "pl": .init(albumA: "Na co dzień", albumB: "Kawowy dziennik",
                        walk: ("Tak reaguje na słowo „spacer”", "Łazienki"),
                        window: ("Znowu miejsce przy oknie", "Kazimierz"),
                        latte: ("Latte w deszczowy dzień", "Powiśle")),
            "sv": .init(albumA: "Vardag", albumB: "Kafédagbok",
                        walk: ("Så här blir det när han hör ”promenad”", "Djurgården"),
                        window: ("Fönsterplatsen är min igen", "Södermalm"),
                        latte: ("Latte en regnig dag", "Vasastan")),
            "tr": .init(albumA: "Her gün", albumB: "Kahve günlüğü",
                        walk: ("“Yürüyüş” deyince hemen kalkıyor", "Maçka Parkı"),
                        window: ("Cam kenarı yine benim", "Moda"),
                        latte: ("Yağmurlu günün lattesi", "Cihangir")),
        ]
    }

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
