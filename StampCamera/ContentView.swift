//
//  ContentView.swift
//  StampCamera
//
//  Main screen: live preview + cut-out stamp frame overlay + shutter.
//  On capture the photo is cropped to the frame's window shape and flies
//  into the in-app collection.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var collection = CollectionStore()

    @State private var previewSize: CGSize = .zero
    @State private var showCollection = false

    // fly-to-collection animation state
    @State private var flying: UIImage?
    @State private var flyStart: CGRect = .zero
    @State private var flyToBin = false
    @State private var binCenter: CGPoint = .zero
    @State private var binBounce = false
    @State private var dropped = false   // cropped piece dropped out of the frame
    @State private var pressed = false
    @State private var recoil = false    // shutter kick: frame springs + rotates out

    // newly-made stamp pending a caption on the parchment editor
    @State private var editTarget: EditTarget?

    // active-album switching from the camera screen
    @State private var showNewAlbum = false
    @State private var newAlbumName = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                cameraScreen
            } else {
                permissionScreen
            }
        }
        .task { await camera.requestAccess() }
        .onChange(of: camera.capturedImage) { _, newValue in handleCapture(newValue) }
        .alert("새 우표첩", isPresented: $showNewAlbum) {
            TextField("우표첩 이름", text: $newAlbumName)
            Button("취소", role: .cancel) { }
            Button("만들기") { collection.createAlbum(newAlbumName) }
        }
        .sheet(isPresented: $showCollection) {
            CollectionView(collection: collection)
        }
        .sheet(item: $editTarget) { target in
            NavigationStack {
                StampDetailView(collection: collection, stampID: target.id)
            }
        }
    }

    // MARK: - Camera screen

    private var cameraScreen: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()

                // background-removed stamp frame, centered over the camera.
                // Tapping it presses the puncher down and fires the shutter.
                if let frame = StampFrameLoader.frame {
                    Image(uiImage: frame.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(pressed ? 0.9 : 1)
                        .offset(y: pressed ? 8 : 0)
                        .contentShape(Rectangle())
                        .onTapGesture { pressShutter() }
                }

                // the captured stamp itself, travelling from the window into
                // the collection — it stays fully visible the whole way and
                // shrinks to the thumbnail size so it reads as one continuous
                // object that gets absorbed into the collection.
                if let flying {
                    let landing = binCenter == .zero
                        ? CGPoint(x: 58, y: geo.size.height - 78) : binCenter
                    Image(uiImage: flying)
                        .resizable()
                        .scaledToFit()
                        .frame(width: flyToBin ? 36 : flyStart.width,
                               height: flyToBin ? 46 : flyStart.height)
                        .shadow(color: .black.opacity(flyToBin ? 0.25 : 0.5),
                                radius: flyToBin ? 5 : 12, y: flyToBin ? 3 : 6)
                        // the freshly-cut piece kicks out with a springy recoil
                        // rotation, then settles back level before flying off
                        .rotationEffect(.degrees(recoil ? 14 : 0))
                        .position(flyToBin ? landing
                                           : CGPoint(x: flyStart.midX, y: flyStart.midY))
                        // the cut piece drops down a touch with a "톡" before flying off
                        .offset(y: flyToBin ? 0 : (dropped ? 22 : 0))
                        .allowsHitTesting(false)
                }

                albumBar
                bottomBar
            }
            .coordinateSpace(name: "cam")
            .onPreferenceChange(BinCenterKey.self) { binCenter = $0 }
            .onAppear { previewSize = geo.size }
            .onChange(of: geo.size) { _, s in previewSize = s }
        }
    }

    /// Top chip showing which book new stamps are being collected into,
    /// with a menu to switch books or start a new one.
    private var albumBar: some View {
        VStack {
            Menu {
                ForEach(collection.albums, id: \.self) { a in
                    Button { collection.setActive(a) } label: {
                        if a == collection.activeAlbum {
                            Label(a, systemImage: "checkmark")
                        } else {
                            Text(a)
                        }
                    }
                }
                Divider()
                Button { newAlbumName = ""; showNewAlbum = true } label: {
                    Label("새 우표첩…", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed.fill")
                    Text(collection.activeAlbum)
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    private var bottomBar: some View {
        VStack {
            Spacer()
            ZStack {
                if camera.zoomStops.count > 1 {
                    ZoomControl(camera: camera)   // centered, at the very bottom
                }
                HStack {
                    collectionButton             // bottom-left, same row
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    /// Presses the puncher down, fires the shutter at the bottom of the press,
    /// then springs it back up.
    private func pressShutter() {
        guard flying == nil else { return }   // ignore taps while a stamp flies
        withAnimation(.easeIn(duration: 0.13)) { pressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            // 찰칵 — take the photo at the bottom of the press
            camera.capturePhoto()
            // spring back up
            withAnimation(.spring(response: 0.34, dampingFraction: 0.5)) { pressed = false }
        }
    }

    private var collectionButton: some View {
        Button { showCollection = true } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let last = collection.stamps.last?.image {
                        Image(uiImage: last)
                            .resizable().scaledToFit()
                            .padding(5)
                            .frame(width: 44, height: 56)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.4), lineWidth: 1))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .frame(width: 44, height: 56)
                            .overlay(Image(systemName: "square.stack.3d.up")
                                .foregroundStyle(.white.opacity(0.7)))
                    }
                }
                if !collection.stamps.isEmpty {
                    Text("\(collection.stamps.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color(hex: 0xE8504E)))
                        .offset(x: 10, y: -8)
                }
            }
            .frame(width: 56, height: 56)
            .scaleEffect(binBounce ? 1.2 : 1)
            // report this button's center so the flying stamp knows where to land
            .background(GeometryReader { g in
                Color.clear.preference(
                    key: BinCenterKey.self,
                    value: CGPoint(x: g.frame(in: .named("cam")).midX,
                                   y: g.frame(in: .named("cam")).midY))
            })
        }
    }

    // MARK: - Capture → crop → fly into collection

    private func handleCapture(_ newValue: UIImage?) {
        guard let raw = newValue,
              StampFrameLoader.frame != nil,
              previewSize != .zero else { return }
        let win = windowScreenRect(in: previewSize)
        guard let stamp = StampCompositor.makeStamp(
            from: raw,
            previewSize: previewSize,
            windowRect: win,
            mirrored: camera.position == .front
        ) else { return }

        // The cropped piece detaches and drops with a little "톡"...
        flyStart = win
        flyToBin = false
        dropped = false
        recoil = false
        flying = stamp
        withAnimation(.spring(response: 0.26, dampingFraction: 0.5)) { dropped = true }
        // spring recoil: kick to 14° then bounce level again before it flies off
        withAnimation(.spring(response: 0.3, dampingFraction: 0.3)) { recoil = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { recoil = false }
        }

        let hold = 0.34
        let travel = 0.55
        // ...settles for a beat, then sweeps into the bin.
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: travel)) { flyToBin = true }
        }
        // The instant it lands, it becomes the collection's newest thumbnail —
        // same image, same spot — so the swap is seamless.
        DispatchQueue.main.asyncAfter(deadline: .now() + hold + travel) {
            let newID = collection.add(stamp)
            flying = nil
            flyToBin = false
            dropped = false
            withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { binBounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { binBounce = false }
                // stamp made → open the parchment so a few words can be added
                editTarget = EditTarget(id: newID)
            }
        }
    }

    /// On-screen rect of the frame's transparent window, given the
    /// scaled-to-fit layout of the frame image in `size`.
    private func windowScreenRect(in size: CGSize) -> CGRect {
        guard let frame = StampFrameLoader.frame else { return .zero }
        let img = frame.image.size
        let s = min(size.width / img.width, size.height / img.height)
        let dispW = img.width * s, dispH = img.height * s
        let ox = (size.width - dispW) / 2, oy = (size.height - dispH) / 2
        let n = frame.windowRectNorm
        return CGRect(x: ox + n.minX * dispW, y: oy + n.minY * dispH,
                      width: n.width * dispW, height: n.height * dispH)
    }

    // MARK: - Permission

    private var permissionScreen: some View {
        VStack(spacing: 18) {
            Text("📮 우표 카메라")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("카메라 권한을 허용하면 우표 펀칭 프레임으로\n사진을 찍을 수 있어요.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
            Button("카메라 켜기") { Task { await camera.requestAccess() } }
                .buttonStyle(PrimaryButton())
        }
        .padding(40)
    }

}

// MARK: - Album shelf (the collecting books)

struct CollectionView: View {
    @ObservedObject var collection: CollectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var showNewAlbum = false
    @State private var newAlbumName = ""

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 18)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(collection.albums, id: \.self) { album in
                        NavigationLink {
                            AlbumPageView(collection: collection, album: album)
                        } label: {
                            AlbumBookCover(name: album,
                                           count: collection.count(in: album),
                                           active: album == collection.activeAlbum,
                                           peek: collection.stamps(in: album).suffix(3).map(\.image))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Color(hex: 0x141210).ignoresSafeArea())
            .navigationTitle("우표첩")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { newAlbumName = ""; showNewAlbum = true } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .alert("새 우표첩", isPresented: $showNewAlbum) {
                TextField("우표첩 이름", text: $newAlbumName)
                Button("취소", role: .cancel) { }
                Button("만들기") { collection.createAlbum(newAlbumName) }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// A collecting book on the shelf: a coloured cover with a peek of the stamps
/// inside, its name and how many it holds.
struct AlbumBookCover: View {
    let name: String
    let count: Int
    let active: Bool
    let peek: [UIImage]

    private var tint: Color {
        let palette: [UInt32] = [0x6B8E5A, 0x9C5B4D, 0x4D6A9C, 0x8A6BA0, 0xB0863E, 0x4F8A8B]
        // stable hash (String.hashValue is seeded per-run, which would change
        // a book's colour between launches)
        let sum = name.utf8.reduce(0) { $0 &+ Int($1) }
        return Color(hex: palette[sum % palette.count])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.65)],
                                         startPoint: .top, endPoint: .bottom))
                // book spine
                RoundedRectangle(cornerRadius: 3)
                    .fill(.black.opacity(0.18))
                    .frame(width: 10)
                    .padding(.vertical, 8).padding(.leading, 10)
                // peek of stamps inside
                HStack(spacing: -14) {
                    ForEach(Array(peek.enumerated()), id: \.offset) { i, img in
                        Image(uiImage: img).resizable().scaledToFit()
                            .frame(height: 70)
                            .rotationEffect(.degrees(Double(i - 1) * 5))
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.leading, 18)
            }
            .frame(height: 124)
            .overlay(alignment: .topTrailing) {
                if active {
                    Text("모으는 중")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color(hex: 0xE8504E)))
                        .padding(7)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(count)장")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - Album page (stamps pressed onto the book's pages)

struct AlbumPageView: View {
    @ObservedObject var collection: CollectionStore
    let album: String
    @Environment(\.dismiss) private var dismiss

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteAlbum = false
    @State private var deleteTarget: CollectedStamp?

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 12)]

    private var stamps: [CollectedStamp] { collection.stamps(in: album) }
    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    var body: some View {
        ScrollView {
            if stamps.isEmpty {
                emptyPage
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(stamps) { stamp in
                        NavigationLink {
                            StampDetailView(collection: collection, stampID: stamp.id)
                        } label: {
                            pagePocket(stamp)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            moveMenu(for: stamp)
                            Button(role: .destructive) { deleteTarget = stamp } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(16)
                .background(albumPaper)
                .padding(14)
            }
        }
        .background(Color(hex: 0x141210).ignoresSafeArea())
        .navigationTitle(album)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if collection.activeAlbum != album {
                        Button { collection.setActive(album) } label: {
                            Label("여기에 모으기", systemImage: "tray.and.arrow.down")
                        }
                    } else {
                        Label("모으는 중", systemImage: "checkmark")
                    }
                    Button { renameText = album; showRename = true } label: {
                        Label("이름 변경", systemImage: "pencil")
                    }
                    if collection.albums.count > 1 {
                        Divider()
                        Button(role: .destructive) { showDeleteAlbum = true } label: {
                            Label("우표첩 삭제", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("이름 변경", isPresented: $showRename) {
            TextField("우표첩 이름", text: $renameText)
            Button("취소", role: .cancel) { }
            Button("저장") { collection.renameAlbum(album, to: renameText) }
        }
        .confirmationDialog("우표첩 '\(album)' 과(와) 안의 우표 \(stamps.count)장을 모두 삭제할까요?",
                            isPresented: $showDeleteAlbum, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { collection.deleteAlbum(album); dismiss() }
            Button("취소", role: .cancel) { }
        }
        .confirmationDialog("이 우표를 삭제할까요?", isPresented: deletePresented,
                            titleVisibility: .visible, presenting: deleteTarget) { stamp in
            Button("삭제", role: .destructive) { collection.delete(stamp.id) }
            Button("취소", role: .cancel) { }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func moveMenu(for stamp: CollectedStamp) -> some View {
        Menu {
            ForEach(collection.albums.filter { $0 != album }, id: \.self) { a in
                Button(a) { collection.move(stamp.id, to: a) }
            }
        } label: {
            Label("다른 우표첩으로", systemImage: "arrow.right.square")
        }
    }

    /// One stamp seated in a clear pocket on the album page.
    private func pagePocket(_ stamp: CollectedStamp) -> some View {
        Image(uiImage: stamp.image)
            .resizable().scaledToFit()
            .frame(height: 96)
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
            )
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }

    private var albumPaper: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0xF6EBBE), Color(hex: 0xEBDBA0)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(hex: 0xCBB870), lineWidth: 1))
    }

    private var emptyPage: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.35))
            Text("아직 비어 있는 우표첩이에요")
                .foregroundStyle(.white.opacity(0.7))
            if collection.activeAlbum == album {
                Text("이 우표첩에 모으는 중 — 사진을 찍어 채워보세요")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Button { collection.setActive(album) } label: {
                    Label("여기에 모으기", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: 0xE8504E))
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

// MARK: - Collection store (disk-backed)

struct CollectedStamp: Identifiable {
    let id: String
    let image: UIImage
    var caption: String
    var album: String          // which collecting book this stamp lives in
}

/// A disk-backed stamp collection organised into albums ("우표첩"). New photos
/// are filed into the *active* album, the way you'd press fresh stamps into the
/// page of a collecting book.
final class CollectionStore: ObservableObject {
    static let defaultAlbum = "내 우표첩"

    @Published private(set) var stamps: [CollectedStamp] = []
    @Published private(set) var albums: [String] = []
    @Published private(set) var activeAlbum: String = ""

    private let dir: URL
    private var metaURL: URL { dir.appendingPathComponent("albums.json") }
    private struct Meta: Codable { var albums: [String]; var active: String }

    init() {
        dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Collection", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadStamps()
        loadMeta()
        reconcile()
    }

    private func captionURL(for id: String) -> URL {
        dir.appendingPathComponent(id).appendingPathExtension("txt")
    }
    private func albumURL(for id: String) -> URL {
        dir.appendingPathComponent(id).appendingPathExtension("grp")
    }

    private func loadStamps() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        stamps = urls
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let image = UIImage(contentsOfFile: url.path) else { return nil }
                let caption = (try? String(contentsOf: url.appendingPathExtension("txt"),
                                           encoding: .utf8)) ?? ""
                let album = ((try? String(contentsOf: url.appendingPathExtension("grp"),
                                          encoding: .utf8)) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return CollectedStamp(id: url.lastPathComponent, image: image,
                                      caption: caption, album: album)
            }
    }

    private func loadMeta() {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return }
        albums = meta.albums
        activeAlbum = meta.active
    }
    private func saveMeta() {
        if let data = try? JSONEncoder().encode(Meta(albums: albums, active: activeAlbum)) {
            try? data.write(to: metaURL)
        }
    }

    /// Guarantee at least one album exists, every stamp belongs to a real
    /// album, and the active album is valid.
    private func reconcile() {
        var names = albums
        for a in stamps.map(\.album) where !a.isEmpty && !names.contains(a) { names.append(a) }
        if names.isEmpty { names = [Self.defaultAlbum] }
        albums = names
        if activeAlbum.isEmpty || !albums.contains(activeAlbum) { activeAlbum = albums[0] }
        // file any legacy stamp that has no album into the first one
        for i in stamps.indices where stamps[i].album.isEmpty {
            stamps[i].album = albums[0]
            try? albums[0].write(to: albumURL(for: stamps[i].id), atomically: true, encoding: .utf8)
        }
        saveMeta()
    }

    // MARK: - Queries

    func stamps(in album: String) -> [CollectedStamp] { stamps.filter { $0.album == album } }
    func count(in album: String) -> Int { stamps.reduce(0) { $0 + ($1.album == album ? 1 : 0) } }

    // MARK: - Stamps

    @discardableResult
    func add(_ image: UIImage) -> String {
        let name = "\(Int(Date().timeIntervalSince1970 * 1000)).png"
        let url = dir.appendingPathComponent(name)
        if let data = image.pngData() { try? data.write(to: url) }
        let album = albums.contains(activeAlbum) ? activeAlbum : (albums.first ?? Self.defaultAlbum)
        try? album.write(to: albumURL(for: name), atomically: true, encoding: .utf8)
        stamps.append(CollectedStamp(id: name, image: image, caption: "", album: album))
        return name
    }

    func setCaption(_ text: String, for id: String) {
        guard let idx = stamps.firstIndex(where: { $0.id == id }) else { return }
        stamps[idx].caption = text
        try? text.write(to: captionURL(for: id), atomically: true, encoding: .utf8)
    }

    func move(_ id: String, to album: String) {
        guard let idx = stamps.firstIndex(where: { $0.id == id }) else { return }
        stamps[idx].album = album
        try? album.write(to: albumURL(for: id), atomically: true, encoding: .utf8)
        if !albums.contains(album) { albums.append(album); saveMeta() }
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id))
        try? FileManager.default.removeItem(at: captionURL(for: id))
        try? FileManager.default.removeItem(at: albumURL(for: id))
        stamps.removeAll { $0.id == id }
    }

    // MARK: - Albums

    @discardableResult
    func createAlbum(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        if !albums.contains(n) { albums.append(n) }
        activeAlbum = n
        saveMeta()
        return n
    }

    func setActive(_ name: String) {
        guard albums.contains(name) else { return }
        activeAlbum = name
        saveMeta()
    }

    func renameAlbum(_ old: String, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != old, let idx = albums.firstIndex(of: old), !albums.contains(n) else { return }
        albums[idx] = n
        for i in stamps.indices where stamps[i].album == old {
            stamps[i].album = n
            try? n.write(to: albumURL(for: stamps[i].id), atomically: true, encoding: .utf8)
        }
        if activeAlbum == old { activeAlbum = n }
        saveMeta()
    }

    /// Deletes the album and every stamp in it. Always keeps at least one album.
    func deleteAlbum(_ name: String) {
        guard albums.count > 1, albums.contains(name) else { return }
        for s in stamps(in: name) { delete(s.id) }
        albums.removeAll { $0 == name }
        if activeAlbum == name { activeAlbum = albums[0] }
        saveMeta()
    }
}

// MARK: - Fly target reporting

private struct BinCenterKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Button styles

private struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 24).padding(.vertical, 13)
            .background(Color(hex: 0xE8504E), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Zoom control (Apple-style: buttons + long-press dial)

struct ZoomControl: View {
    @ObservedObject var camera: CameraManager
    @GestureState private var dialing = false
    @State private var dialBase: CGFloat?

    var body: some View {
        let stops = camera.zoomStops
        HStack(spacing: 6) {
            ForEach(stops, id: \.self) { stop in
                let active = isActive(stop, stops: stops)
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        camera.setZoom(stop)
                    }
                } label: {
                    Text(label(for: stop, active: active))
                        .font(.system(size: active ? 15 : 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(active ? Color.yellow : .white)
                        .frame(width: active ? 44 : 34, height: active ? 44 : 34)
                        .background(Circle().fill(.black.opacity(active ? 0.55 : 0.3)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(alignment: .top) {
            if dialing {
                ZoomDialView(zoom: camera.zoom,
                             minZoom: camera.minZoom,
                             maxZoom: camera.maxZoom)
                    .offset(y: -104)
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
            }
        }
        .scaleEffect(dialing ? 1.08 : 1)
        .animation(.easeOut(duration: 0.18), value: dialing)
        // long-press 0.5s, then swipe to fine-tune the zoom
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .updating($dialing) { value, state, _ in
                    if case .second = value { state = true }
                }
                .onChanged { value in
                    guard case .second(_, let drag?) = value else { return }
                    if dialBase == nil { dialBase = camera.zoom }
                    let base = dialBase ?? camera.zoom
                    // swipe right or up = zoom in; exponential feels natural.
                    // smaller divisor = more sensitive (less travel per doubling)
                    let delta = (drag.translation.width - drag.translation.height) / 80
                    camera.setZoom(base * pow(2, delta))
                }
                .onEnded { _ in dialBase = nil }
        )
    }

    private func isActive(_ stop: CGFloat, stops: [CGFloat]) -> Bool {
        guard let nearest = stops.min(by: {
            abs($0 - camera.zoom) < abs($1 - camera.zoom)
        }) else { return false }
        return nearest == stop
    }

    private func label(for stop: CGFloat, active: Bool) -> String {
        if active {
            let z = camera.zoom
            if abs(z - z.rounded()) < 0.05 { return "\(Int(z.rounded()))×" }
            return String(format: "%.1f×", z)
        }
        return stop < 1 ? "0.5" : "\(Int(stop))"
    }
}

// MARK: - Zoom dial (iPhone-style protractor for fine zoom)

/// A half-circle protractor that pops up while long-pressing the zoom pill:
/// a tick ruler across the whole zoom range (log scale) with a needle pointing
/// at the live zoom and the value read out at the pivot.
struct ZoomDialView: View {
    let zoom: CGFloat
    let minZoom: CGFloat
    let maxZoom: CGFloat

    private let radius: CGFloat = 108

    /// 0…1 position of a zoom value along the arc (log scale, like Apple's).
    private func pos(_ z: CGFloat) -> CGFloat {
        let lo = log(Double(max(minZoom, 0.01)))
        let hi = log(Double(max(maxZoom, minZoom + 0.01)))
        guard hi > lo else { return 0 }
        let t = (log(Double(max(z, 0.01))) - lo) / (hi - lo)
        return CGFloat(min(1, max(0, t)))
    }

    /// Point on the upper semicircle for t (left→right), inset by `depth`.
    private func point(_ t: CGFloat, depth: CGFloat, center: CGPoint) -> CGPoint {
        let ang = Double.pi + Double(t) * Double.pi      // 180°…360°
        let rr = radius - depth
        return CGPoint(x: center.x + CGFloat(cos(ang)) * rr,
                       y: center.y + CGFloat(sin(ang)) * rr)
    }

    /// Labelled zoom stops that fall inside the device's range.
    private var majors: [CGFloat] {
        [0.5, 1, 2, 3, 4, 5, 6, 8].filter { $0 >= minZoom - 0.001 && $0 <= maxZoom + 0.001 }
    }

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 12)

            // rim
            var rim = Path()
            let steps = 96
            for i in 0...steps {
                let p = point(CGFloat(i) / CGFloat(steps), depth: 0, center: center)
                if i == 0 { rim.move(to: p) } else { rim.addLine(to: p) }
            }
            ctx.stroke(rim, with: .color(.white.opacity(0.22)), lineWidth: 2)

            // minor ticks
            let minor = 48
            for i in 0...minor {
                let t = CGFloat(i) / CGFloat(minor)
                var tick = Path()
                tick.move(to: point(t, depth: 0, center: center))
                tick.addLine(to: point(t, depth: 7, center: center))
                ctx.stroke(tick, with: .color(.white.opacity(0.3)), lineWidth: 1)
            }

            // major ticks + labels
            for z in majors {
                let t = pos(z)
                var tick = Path()
                tick.move(to: point(t, depth: 0, center: center))
                tick.addLine(to: point(t, depth: 14, center: center))
                ctx.stroke(tick, with: .color(.yellow.opacity(0.9)), lineWidth: 2)
                ctx.draw(Text(zLabel(z))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.9)),
                         at: point(t, depth: 27, center: center))
            }

            // needle + pivot hub
            var needle = Path()
            needle.move(to: point(pos(zoom), depth: radius - 14, center: center))   // start above hub
            needle.addLine(to: point(pos(zoom), depth: 4, center: center))
            ctx.stroke(needle, with: .color(.yellow), lineWidth: 3)
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                     with: .color(.yellow))

            // live readout near the apex, drawn last so it stays legible
            ctx.draw(Text(zLabel(zoom))
                        .font(.system(size: 23, weight: .heavy, design: .rounded))
                        .foregroundColor(.yellow),
                     at: CGPoint(x: center.x, y: center.y - radius * 0.52))
        }
        .frame(width: radius * 2 + 56, height: radius + 26)
        .background(
            Ellipse()
                .fill(Color.black.opacity(0.3))
                .frame(width: radius * 2, height: radius * 1.5)
                .offset(y: 14)
                .blur(radius: 16)
        )
    }

    private func zLabel(_ z: CGFloat) -> String {
        if abs(z - z.rounded()) < 0.05 { return "\(Int(z.rounded()))×" }
        return String(format: "%.1f×", z)
    }
}

// MARK: - Parchment + caption

/// A warm parchment sheet used as the backing for collected stamps.
struct Parchment: View {
    var cornerRadius: CGFloat = 16
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0xF3EAD0), Color(hex: 0xE4D4AC)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(RadialGradient(colors: [.clear, Color(hex: 0x8B7B4E).opacity(0.30)],
                                         center: .center, startRadius: 8, endRadius: 320))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(hex: 0xCBB585), lineWidth: 1)
            )
    }
}

/// Grid item: a stamp affixed to a parchment card with its caption.
struct ParchmentCard: View {
    let stamp: CollectedStamp
    var body: some View {
        VStack(spacing: 8) {
            Image(uiImage: stamp.image)
                .resizable().scaledToFit()
                .frame(height: 110)
                .shadow(color: .black.opacity(0.28), radius: 4, y: 3)
            Text(stamp.caption.isEmpty ? "—" : stamp.caption)
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundStyle(Color(hex: stamp.caption.isEmpty ? 0xB0A074 : 0x4A3A22))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Parchment())
    }
}

/// Detail / editor: the stamp on a full parchment page with an editable note.
struct StampDetailView: View {
    @ObservedObject var collection: CollectionStore
    let stampID: String
    @Environment(\.dismiss) private var dismiss
    @State private var caption = ""
    @State private var newAlbumName = ""
    @State private var showNewAlbum = false
    @State private var showDelete = false
    @FocusState private var focused: Bool

    private var stamp: CollectedStamp? { collection.stamps.first { $0.id == stampID } }
    private var albumLabel: String { stamp?.album ?? CollectionStore.defaultAlbum }

    var body: some View {
        ZStack {
            Color(hex: 0x241F18).ignoresSafeArea()
            // Everything fits on one screen at a glance — no scrolling needed.
            VStack(spacing: 16) {
                if let stamp {
                    Image(uiImage: stamp.image)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 190)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
                }
                ZStack(alignment: .top) {
                    // custom placeholder so it stays a readable warm brown
                    // (the field inherits the sheet's dark scheme otherwise,
                    // which painted the prompt white = invisible on parchment)
                    if caption.isEmpty {
                        Text("몇 마디 적어보세요…")
                            .foregroundStyle(Color(hex: 0x9A875E))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $caption, axis: .vertical)
                        .foregroundStyle(Color(hex: 0x42331E))
                        .tint(Color(hex: 0x42331E))
                        .focused($focused)
                }
                .font(.system(size: 17, weight: .medium, design: .serif))
                .multilineTextAlignment(.center)
                .lineLimit(2...4)
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .top)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.4))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color(hex: 0xCBB585), lineWidth: 1))
                )
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
                .environment(\.colorScheme, .light)

                albumPicker
            }
            .padding(24)
            .background(Parchment(cornerRadius: 20))
            .padding(.horizontal, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .destructive) { showDelete = true } label: {
                    Image(systemName: "trash")
                }
                .tint(.red)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("완료") { save(); dismiss() }
            }
        }
        .alert("새 우표첩", isPresented: $showNewAlbum) {
            TextField("우표첩 이름", text: $newAlbumName)
            Button("취소", role: .cancel) { }
            Button("만들기") {
                if let name = collection.createAlbum(newAlbumName) {
                    collection.move(stampID, to: name)
                }
            }
        }
        .confirmationDialog("이 우표를 삭제할까요?", isPresented: $showDelete,
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) { collection.delete(stampID); dismiss() }
            Button("취소", role: .cancel) { }
        }
        .onAppear { caption = stamp?.caption ?? "" }
        .onDisappear(perform: save)
        .preferredColorScheme(.dark)
    }

    /// Which collecting book this stamp sits in — switch it or start a new one.
    private var albumPicker: some View {
        Menu {
            ForEach(collection.albums.filter { $0 != (stamp?.album ?? "") }, id: \.self) { a in
                Button(a) { collection.move(stampID, to: a) }
            }
            Divider()
            Button("새 우표첩…") { newAlbumName = ""; showNewAlbum = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "book.closed")
                Text(albumLabel)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(hex: 0x6B5836))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(0.45)))
            .overlay(Capsule().strokeBorder(Color(hex: 0xCBB585), lineWidth: 1))
        }
    }

    private func save() { collection.setCaption(caption, for: stampID) }
}

struct EditTarget: Identifiable {
    let id: String
}

// MARK: - Stamp frame cut-out (background removal + window mask)

/// The processed `stampFrame` asset: the frame with its background and inner
/// window removed, plus the window's position so the photo can be cropped to
/// the stamp shape that sits inside it.
struct StampFrame {
    let image: UIImage          // cut-out frame (transparent bg + window)
    let windowRectNorm: CGRect  // window bounding box in 0...1 image coords
}

enum StampFrameLoader {
    static let frame: StampFrame? = make()

    private static func make() -> StampFrame? {
        guard let source = UIImage(named: "stampFrame"),
              let cg = source.cgImage else { return nil }

        let w = cg.width, h = cg.height
        let count = w * h * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: count)

        guard let ctx = CGContext(
            data: buffer, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // The asset is already a clean cut-out PNG: transparent around the
        // frame AND transparent through the stamp window. We only need to find
        // that inner window — the transparent region that is NOT connected to
        // the image border (the outer transparent background is).
        let alphaThreshold: UInt8 = 20
        func isClear(_ p: Int) -> Bool { buffer[p * 4 + 3] < alphaThreshold }

        // flood the exterior transparent background inward from every border pixel
        var exterior = [Bool](repeating: false, count: w * h)
        var stack = [Int]()
        func seed(_ p: Int) { if isClear(p) && !exterior[p] { exterior[p] = true; stack.append(p) } }
        for x in 0..<w { seed(x); seed((h - 1) * w + x) }
        for y in 0..<h { seed(y * w); seed(y * w + w - 1) }
        while let p = stack.popLast() {
            let x = p % w, y = p / w
            if x > 0 { seed(p - 1) }
            if x < w - 1 { seed(p + 1) }
            if y > 0 { seed(p - w) }
            if y < h - 1 { seed(p + w) }
        }

        // interior transparent pixels = the stamp window; take its bounding box
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                if isClear(p) && !exterior[p] {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let bw = maxX - minX + 1, bh = maxY - minY + 1

        let rectNorm = CGRect(
            x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
            width: CGFloat(bw) / CGFloat(w), height: CGFloat(bh) / CGFloat(h))

        // The asset is already cut out, so use it as-is.
        return StampFrame(image: source, windowRectNorm: rectNorm)
    }
}

#Preview {
    ContentView()
}
