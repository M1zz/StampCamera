//
//  ContentView.swift
//  StampCamera
//
//  Main screen: live preview + cut-out stamp frame overlay + shutter.
//  On capture the photo is cropped to the frame's window shape and flies
//  into the in-app collection.
//

import SwiftUI
import AVFoundation
import CoreLocation

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var collection = CollectionStore()
    @StateObject private var location = LocationManager()

    @State private var previewSize: CGSize = .zero
    @State private var showCollection = false

    // fly-to-collection animation state
    @State private var flying: UIImage?
    @State private var flyStart: CGRect = .zero
    @State private var fell = false             // crop has been flung off-screen
    @State private var landSpot: CGPoint = .zero // off-screen target it flies to
    @State private var landAngle: Double = 0     // random spin as it shoots out
    @State private var binCenter: CGPoint = .zero
    @State private var binBounce = false
    @State private var stayingStamp: UIImage?  // capture left sitting in the window
    @State private var stayVisible = false      // fades the staying imprint out
    @State private var pressed = false

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
            } else if camera.permissionDenied {
                // access refused → black screen explaining the camera is needed
                permissionScreen
            }
            // while access is still being determined: just the black background,
            // so the guidance never flashes for users who already granted it.
        }
        .task { await camera.requestAccess() }
        .onAppear { location.start() }
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

                // full-screen frosted blur with the frame's outer silhouette
                // punched out, so the busy live scene OUTSIDE the frame recedes
                // (edge to edge, past the safe area) while the frame and window
                // stay crisp. The punch is computed in geo-local coords — the
                // same space the mask is laid out in — so it lines up exactly
                // with the frame image (which is also centered in `geo`).
                if let frame = StampFrameLoader.frame {
                    let img = frame.image.size
                    let s = min(geo.size.width / img.width, geo.size.height / img.height)
                    let dispW = img.width * s, dispH = img.height * s
                    let ox = (geo.size.width - dispW) / 2
                    let oy = (geo.size.height - dispH) / 2
                    BlurView()
                        .ignoresSafeArea()
                        .mask {
                            ZStack(alignment: .topLeading) {
                                Color.white.ignoresSafeArea()
                                Image(uiImage: frame.interiorMask)
                                    .resizable()
                                    .frame(width: dispW, height: dispH)
                                    // shrink + drop the punched hole exactly like
                                    // the frame image when the puncher is pressed
                                    .scaleEffect(pressed ? 0.9 : 1)
                                    .offset(x: ox, y: oy + (pressed ? 8 : 0))
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        }
                        .allowsHitTesting(false)
                }

                // background-removed stamp frame, centered over the camera.
                // Holding it presses the puncher down (it shrinks); releasing
                // springs it back up and fires the shutter.
                if let frame = StampFrameLoader.frame {
                    Image(uiImage: frame.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(pressed ? 0.9 : 1)
                        .offset(y: pressed ? 8 : 0)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in pressDown() }
                                .onEnded { _ in releaseShutter() }
                        )
                }

                // the capture stays imprinted in the window...
                if let stayingStamp {
                    Image(uiImage: stayingStamp)
                        .resizable()
                        .scaledToFit()
                        .frame(width: flyStart.width, height: flyStart.height)
                        .position(x: flyStart.midX, y: flyStart.midY)
                        .opacity(stayVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }

                // ...while a cropped copy is flung off the screen (팡) in a random
                // direction, spinning as it shoots out of frame.
                if let flying {
                    let pos: CGPoint = fell ? landSpot
                                            : CGPoint(x: flyStart.midX, y: flyStart.midY)
                    Image(uiImage: flying)
                        .resizable()
                        .scaledToFit()
                        .frame(width: flyStart.width, height: flyStart.height)
                        .scaleEffect(fell ? 1.25 : 1)   // little burst as it launches
                        .rotationEffect(.degrees(fell ? landAngle : 0))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
                        .position(pos)
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

    /// Finger down: press the puncher down so the frame shrinks a little.
    private func pressDown() {
        guard flying == nil, !pressed else { return }   // ignore while a stamp flies
        withAnimation(.easeIn(duration: 0.12)) { pressed = true }
    }

    /// Finger up: spring the frame back up and fire the shutter on release.
    private func releaseShutter() {
        guard pressed else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.5)) { pressed = false }
        guard flying == nil else { return }   // a stamp is already in flight
        PunchSound.play()                     // 펀칭! — ~1s punch sound
        camera.capturePhoto()
    }

    private var collectionButton: some View {
        Button { showCollection = true } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let last = collection.collectedStamps.last?.image {
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
                if !collection.collectedStamps.isEmpty {
                    Text("\(collection.collectedStamps.count)")
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
        let mirrored = camera.position == .front
        guard let result = StampCompositor.makeStamp(
            from: raw,
            previewSize: previewSize,
            windowRect: win,
            mirrored: mirrored
        ) else { return }
        let stamp = result.image
        let cropNorm = result.cropNorm

        // The capture stays imprinted in the window. A cropped copy is flung off
        // the screen (팡) in a random direction, spinning as it shoots out.
        flyStart = win
        fell = false
        stayingStamp = stamp
        stayVisible = true
        flying = stamp

        // a fresh random off-screen direction + spin for this crop
        let angle = Double.random(in: 0 ..< (2 * .pi))
        let dist = hypot(previewSize.width, previewSize.height) * 1.3
        landSpot = CGPoint(x: win.midX + CGFloat(cos(angle)) * dist,
                           y: win.midY + CGFloat(sin(angle)) * dist)
        landAngle = Double.random(in: -260 ... 260)

        // 팡 — burst out fast and shoot off the screen
        let travel = 0.4
        withAnimation(.easeOut(duration: travel)) { fell = true }

        // Once it's off-screen, file it into the collection.
        let here = location.current
        let mine = stamp   // identity guard against a faster follow-up shot
        DispatchQueue.main.asyncAfter(deadline: .now() + travel) {
            let newID = collection.add(stamp, location: here,
                                       original: raw, cropNorm: cropNorm, mirrored: mirrored)
            // fill in the place name once reverse-geocoding returns
            if let here {
                Task {
                    if let place = await location.placeName(for: here) {
                        collection.setPlace(place, for: newID)
                    }
                }
            }
            flying = nil
            fell = false
            withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { binBounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { binBounce = false }
            }
            // The captured photo holds in the frame window for ~2s (from the
            // shutter), then fades back to the live preview and the parchment
            // opens for a caption.
            DispatchQueue.main.asyncAfter(deadline: .now() + (2.0 - travel)) {
                guard stayingStamp === mine else { return }   // a newer shot took over
                withAnimation(.easeOut(duration: 0.4)) { stayVisible = false }
                editTarget = EditTarget(id: newID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if stayingStamp === mine { stayingStamp = nil }
                }
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

    /// Shown only when camera access has been refused — a black screen telling
    /// the user the camera is needed, with a shortcut into Settings. Once access
    /// is granted this never appears again.
    private var permissionScreen: some View {
        VStack(spacing: 18) {
            Text("📮 우표 카메라")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("우표를 펀칭하려면 카메라 권한이 필요해요.\n설정에서 카메라를 켜주세요.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
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
    @State private var showNewExhibition = false
    @State private var newExhibitionName = ""

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 18)]

    var body: some View {
        NavigationStack {
            ScrollView {
                sectionHeader("우표첩")
                albumShelf
                sectionHeader("전시")
                exhibitionWalls
            }
            .background(Color(hex: 0x141210).ignoresSafeArea())
            .navigationTitle("모음")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { newAlbumName = ""; showNewAlbum = true } label: {
                            Label("새 우표첩…", systemImage: "book.closed")
                        }
                        Button { newExhibitionName = ""; showNewExhibition = true } label: {
                            Label("새 전시…", systemImage: "photo.artframe")
                        }
                    } label: {
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
            .sheet(isPresented: $showNewExhibition) {
                NewExhibitionSheet(collection: collection)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    private var albumShelf: some View {
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

    @ViewBuilder
    private var exhibitionWalls: some View {
        if collection.exhibitions.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "photo.artframe")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.3))
                Text("아직 전시가 없어요")
                    .foregroundStyle(.white.opacity(0.7))
                Text("우표첩에서 우표를 길게 눌러 전시에 걸어보세요")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 80).padding(.horizontal, 40)
        } else {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(collection.exhibitions) { ex in
                    NavigationLink {
                        ExhibitionWallView(collection: collection, exhibition: ex.name)
                    } label: {
                        ExhibitionWallCover(name: ex.name,
                                            count: ex.stampIDs.count,
                                            peek: collection.stampsInExhibition(ex.name).prefix(3).map(\.image),
                                            background: ex.backgroundStyle)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
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

/// An exhibition on the wall list: a gold-framed card peeking at the stamps
/// hung inside, with its name and how many pieces it holds.
struct ExhibitionWallCover: View {
    let name: String
    let count: Int
    let peek: [UIImage]
    var background: BackgroundStyle = .cream

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                DiaryBackground(style: background)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: -10) {
                    ForEach(Array(peek.enumerated()), id: \.offset) { _, img in
                        Image(uiImage: img).resizable().scaledToFit()
                            .frame(height: 66)
                            .padding(3)
                            .background(Color(hex: 0xF6EBBE))
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Color(hex: 0xCBB870), lineWidth: 2))
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 124)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(hex: 0xCBB870), lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(count)점")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - Album page (stamps pressed onto the book's pages)

/// How the stamps on an album page are grouped into sections.
private enum GroupMode: String, CaseIterable, Hashable {
    case place = "장소별"
    case period = "기간별"
}

/// One grouped section of stamps (a place, or a month).
private struct StampSection: Identifiable {
    let id: String
    let title: String
    let stamps: [CollectedStamp]
}

struct AlbumPageView: View {
    @ObservedObject var collection: CollectionStore
    let album: String
    @Environment(\.dismiss) private var dismiss

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteAlbum = false
    @State private var deleteTarget: CollectedStamp?
    @State private var groupMode: GroupMode = .place
    @State private var showNewExhibition = false
    @State private var newExhibitionName = ""
    @State private var exhibitTarget: CollectedStamp?

    // Flow B: drag a stamp onto a chip in the bottom exhibition bar.
    @State private var hoveredDrop: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    private var stamps: [CollectedStamp] { collection.stamps(in: album) }
    /// Everything homed in this album, including stamps currently exhibited —
    /// what "delete album" would actually remove.
    private var homeCount: Int { collection.stamps.lazy.filter { $0.album == album }.count }
    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    /// year*12+month sort key and a "2026년 6월" title for a date.
    private func periodKey(_ date: Date) -> (sort: Int, title: String) {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        let y = c.year ?? 0, m = c.month ?? 0
        return (y * 12 + m, "\(y)년 \(m)월")
    }

    /// The album's stamps grouped by place or by month, newest section first.
    private var sections: [StampSection] {
        let grouped: [StampSection]
        switch groupMode {
        case .place:
            let groups = Dictionary(grouping: stamps) {
                $0.place.isEmpty ? "위치 미상" : $0.place
            }
            grouped = groups.map { key, value in
                StampSection(id: "place-\(key)", title: key,
                             stamps: value.sorted { $0.createdAt > $1.createdAt })
            }
        case .period:
            let groups = Dictionary(grouping: stamps) { periodKey($0.createdAt).sort }
            grouped = groups.map { key, value in
                StampSection(id: "period-\(key)", title: periodKey(value[0].createdAt).title,
                             stamps: value.sorted { $0.createdAt > $1.createdAt })
            }
        }
        return grouped.sorted {
            ($0.stamps.first?.createdAt ?? .distantPast) > ($1.stamps.first?.createdAt ?? .distantPast)
        }
    }

    var body: some View {
        ScrollView {
            if stamps.isEmpty {
                emptyPage
            } else {
                LazyVStack(spacing: 16) {
                    Picker("정렬", selection: $groupMode) {
                        ForEach(GroupMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)

                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Image(systemName: groupMode == .place
                                      ? "mappin.and.ellipse" : "calendar")
                                Text(section.title).lineLimit(1)
                                Spacer()
                                Text("\(section.stamps.count)")
                            }
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: 0x6B5836))

                            stampGrid(section.stamps)
                        }
                        .padding(16)
                        .background(albumPaper)
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .background(Color(hex: 0x141210).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if !stamps.isEmpty { exhibitionDropBar }
        }
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
        .confirmationDialog("우표첩 '\(album)' 과(와) 안의 우표 \(homeCount)장을 모두 삭제할까요?",
                            isPresented: $showDeleteAlbum, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { collection.deleteAlbum(album); dismiss() }
            Button("취소", role: .cancel) { }
        }
        .confirmationDialog("이 우표를 삭제할까요?", isPresented: deletePresented,
                            titleVisibility: .visible, presenting: deleteTarget) { stamp in
            Button("삭제", role: .destructive) { collection.delete(stamp.id) }
            Button("취소", role: .cancel) { }
        }
        .sheet(isPresented: $showNewExhibition) {
            NewExhibitionSheet(collection: collection) { name in
                if let t = exhibitTarget { collection.placeInExhibition(t.id, into: name) }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// The 4-up grid of stamps for one section. A quick tap opens the detail;
    /// long-press lifts the stamp so it can be dragged down to the exhibition
    /// bar (Flow B) — scrolling and tapping stay intact (native drag).
    private func stampGrid(_ list: [CollectedStamp]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(list) { stamp in
                NavigationLink {
                    StampDetailView(collection: collection, stampID: stamp.id)
                } label: {
                    pagePocket(stamp)
                }
                .buttonStyle(.plain)
                .draggable(stamp.id) {
                    pagePocket(stamp).frame(width: 90)   // lift preview
                }
            }
        }
    }

    /// A bar pinned at the bottom: drag a stamp onto an exhibition to hang it.
    private var exhibitionDropBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Label("전시에 걸기", systemImage: "hand.draw")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                ForEach(collection.exhibitions) { ex in
                    dropChip(title: ex.name, systemImage: "photo.artframe") { id in
                        collection.placeInExhibition(id, into: ex.name)
                    }
                }
                dropChip(title: "새 전시", systemImage: "plus", dashed: true) { id in
                    exhibitTarget = collection.stamps.first { $0.id == id }
                    newExhibitionName = ""
                    showNewExhibition = true
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    private func dropChip(title: String, systemImage: String, dashed: Bool = false,
                          onDrop: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title).lineLimit(1)
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Capsule().fill(Color.white.opacity(hoveredDrop == title ? 0.3 : 0.12)))
        .overlay(Capsule().strokeBorder(Color(hex: 0xCBB870),
                                        style: StrokeStyle(lineWidth: hoveredDrop == title ? 2.5 : 1,
                                                           dash: dashed ? [5] : [])))
        .scaleEffect(hoveredDrop == title ? 1.06 : 1)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { onDrop(id) }
            return true
        } isTargeted: { t in
            withAnimation(.easeOut(duration: 0.12)) { hoveredDrop = t ? title : (hoveredDrop == title ? nil : hoveredDrop) }
        }
    }


    /// One stamp seated in a clear pocket on the album page — just the stamp;
    /// the date/place show as the section headers, not on each stamp.
    private func pagePocket(_ stamp: CollectedStamp) -> some View {
        Image(uiImage: stamp.image)
            .resizable().scaledToFit()
            .frame(height: 74)
            .padding(4)
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

// MARK: - Diary-insert backgrounds

/// Diary / planner insert paper styles a user can pick for an exhibition wall.
enum BackgroundStyle: String, CaseIterable, Identifiable {
    case cream, grid, ruled, dot, kraft, parchment, cornell, graph, mint, slate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cream:     return "무지 크림"
        case .grid:      return "모눈"
        case .ruled:     return "줄노트"
        case .dot:       return "도트"
        case .kraft:     return "크라프트"
        case .parchment: return "양피지"
        case .cornell:   return "코넬"
        case .graph:     return "그래프"
        case .mint:      return "민트"
        case .slate:     return "다크 그리드"
        }
    }

    /// True for the few dark papers, so foreground text can flip to light.
    var isDark: Bool { self == .slate }

    var paper: Color {
        switch self {
        case .cream:     return Color(hex: 0xF6EFD9)
        case .grid:      return Color(hex: 0xF7F1DC)
        case .ruled:     return Color(hex: 0xFBFAF4)
        case .dot:       return Color(hex: 0xF7F2E2)
        case .kraft:     return Color(hex: 0xC9A983)
        case .parchment: return Color(hex: 0xEDDCB0)
        case .cornell:   return Color(hex: 0xFBF6EA)
        case .graph:     return Color(hex: 0xFAFCFE)
        case .mint:      return Color(hex: 0xDCEFE4)
        case .slate:     return Color(hex: 0x23272E)
        }
    }
}

/// Renders a `BackgroundStyle` as procedurally-drawn diary paper at any size.
struct DiaryBackground: View {
    let style: BackgroundStyle

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            // base paper
            if style == .parchment {
                ctx.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [Color(hex: 0xF3E6C4), Color(hex: 0xE6D2A0)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            } else {
                ctx.fill(Path(rect), with: .color(style.paper))
            }

            // pattern overlay
            switch style {
            case .grid, .graph, .slate:
                let step: CGFloat = style == .graph ? 18 : 24
                var p = Path()
                stride(from: step, to: size.width, by: step).forEach {
                    p.move(to: CGPoint(x: $0, y: 0)); p.addLine(to: CGPoint(x: $0, y: size.height))
                }
                stride(from: step, to: size.height, by: step).forEach {
                    p.move(to: CGPoint(x: 0, y: $0)); p.addLine(to: CGPoint(x: size.width, y: $0))
                }
                ctx.stroke(p, with: .colour(style), lineWidth: 0.6)
            case .ruled, .cornell:
                let step: CGFloat = 28
                var p = Path()
                stride(from: step, to: size.height, by: step).forEach {
                    p.move(to: CGPoint(x: 0, y: $0)); p.addLine(to: CGPoint(x: size.width, y: $0))
                }
                ctx.stroke(p, with: .colour(style), lineWidth: 0.7)
                if style == .cornell {
                    let mx = max(54, size.width * 0.18)
                    var m = Path()
                    m.move(to: CGPoint(x: mx, y: 0)); m.addLine(to: CGPoint(x: mx, y: size.height))
                    ctx.stroke(m, with: .color(Color(hex: 0xD98C8C).opacity(0.6)), lineWidth: 1)
                }
            case .dot:
                let step: CGFloat = 22, r: CGFloat = 1.1
                for x in stride(from: step, to: size.width, by: step) {
                    for y in stride(from: step, to: size.height, by: step) {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                                 with: .colour(style))
                    }
                }
            case .cream, .kraft, .parchment, .mint:
                break   // plain / gradient paper
            }
        }
    }
}

private extension GraphicsContext.Shading {
    /// The line/dot ink colour for a paper style.
    static func colour(_ style: BackgroundStyle) -> GraphicsContext.Shading {
        switch style {
        case .grid:    return .color(Color(hex: 0xD7CBA6))
        case .graph:   return .color(Color(hex: 0x8FB7D6).opacity(0.55))
        case .slate:   return .color(.white.opacity(0.08))
        case .ruled:   return .color(Color(hex: 0xB9C7D6))
        case .cornell: return .color(Color(hex: 0xCBB9A0))
        case .dot:     return .color(Color(hex: 0xCEC1A0))
        default:       return .color(.clear)
        }
    }
}

/// Sheet for creating an exhibition: a name and one of the diary-paper styles.
struct NewExhibitionSheet: View {
    @ObservedObject var collection: CollectionStore
    var onCreate: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var style: BackgroundStyle = .cream
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("전시 이름", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 16).padding(.top, 14)
                    Text("배경 고르기")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .padding(.horizontal, 16)
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(BackgroundStyle.allCases) { s in
                            Button { style = s } label: { swatch(s) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("새 전시")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("만들기") {
                        if let n = collection.createExhibition(name, background: style) { onCreate(n) }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func swatch(_ s: BackgroundStyle) -> some View {
        VStack(spacing: 6) {
            DiaryBackground(style: s)
                .frame(height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style == s ? Color(hex: 0xE8504E) : Color.black.opacity(0.12),
                                  lineWidth: style == s ? 3 : 1))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            Text(s.title)
                .font(.system(size: 11, weight: style == s ? .bold : .medium, design: .rounded))
                .foregroundStyle(style == s ? Color(hex: 0xE8504E) : .secondary)
        }
    }
}

// MARK: - Exhibition wall (curated stamps hung up to show off)

struct ExhibitionWallView: View {
    @ObservedObject var collection: CollectionStore
    let exhibition: String
    @Environment(\.dismiss) private var dismiss

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDelete = false
    @State private var deleteTarget: CollectedStamp?

    // Flow A: a hwatu deck fanned from the user's thumb corner. Swipe in an arc
    // around the corner to scroll the deck (wrapping); pull a card outward (away
    // from the corner) to draw it; tap elsewhere to fold it back.
    private enum FanDragMode { case none, scrub, draw }
    @AppStorage("stampFanRightHanded") private var rightHanded = true
    @State private var fanPresented = false
    @State private var fanScroll: CGFloat = 0        // fractional index of the front card
    @State private var fanScrubAnchor: CGFloat = 0
    @State private var scrubStartAngle: CGFloat = 0  // finger angle (rad) when an arc-scrub began
    @State private var drawStartRadius: CGFloat = 0  // finger distance from pivot when a draw began
    @State private var drawCardPos: CGPoint = .zero  // the drawn card follows the finger here
    @State private var drawStartLoc: CGPoint = .zero
    @State private var fanDragMode: FanDragMode = .none
    @State private var fanSpread: CGFloat = 0         // 0 = stacked at corner, 1 = fully fanned
    private let maxFan = 3                            // peek count for the hint
    private let fanRadius: CGFloat = 196             // arc radius from the corner
    private let fanCardAngle: CGFloat = 0.27         // radians between cards (~15.5°)

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
    private var stamps: [CollectedStamp] { collection.stampsInExhibition(exhibition) }
    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                wallScroll(viewportHeight: geo.size.height)
                    .blur(radius: fanPresented ? 2 : 0)

                // hint tucked into the thumb corner — swipe out an arc to fan
                if !fanPresented && !collection.collectedStamps.isEmpty {
                    fanHint
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: rightHanded ? .bottomTrailing : .bottomLeading)
                        .padding(rightHanded ? .trailing : .leading, 8)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }

                if fanPresented {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .allowsHitTesting(false)
                    fanTray(in: geo.size)
                        .transition(.opacity)
                }
            }
        }
        .background(DiaryBackground(style: collection.backgroundStyle(of: exhibition)).ignoresSafeArea())
        .navigationTitle(exhibition)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { rightHanded.toggle() } label: {
                        Label(rightHanded ? "왼손잡이 모드로" : "오른손잡이 모드로",
                              systemImage: rightHanded ? "hand.point.left" : "hand.point.right")
                    }
                    Menu {
                        ForEach(BackgroundStyle.allCases) { s in
                            Button { collection.setExhibitionBackground(exhibition, to: s) } label: {
                                Label(s.title, systemImage: collection.backgroundStyle(of: exhibition) == s
                                      ? "checkmark" : "square.dashed")
                            }
                        }
                    } label: {
                        Label("배경 바꾸기", systemImage: "photo.on.rectangle")
                    }
                    Button { renameText = exhibition; showRename = true } label: {
                        Label("이름 변경", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) { showDelete = true } label: {
                        Label("전시 삭제", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("이름 변경", isPresented: $showRename) {
            TextField("전시 이름", text: $renameText)
            Button("취소", role: .cancel) { }
            Button("저장") { collection.renameExhibition(exhibition, to: renameText) }
        }
        .confirmationDialog("전시 '\(exhibition)' 을(를) 삭제할까요? 걸려 있던 우표들은 원래 우표첩으로 돌아가요.",
                            isPresented: $showDelete, titleVisibility: .visible) {
            Button("전시 삭제", role: .destructive) { collection.deleteExhibition(exhibition); dismiss() }
            Button("취소", role: .cancel) { }
        }
        .confirmationDialog("이 우표를 삭제할까요?", isPresented: deletePresented,
                            titleVisibility: .visible, presenting: deleteTarget) { stamp in
            Button("삭제", role: .destructive) { collection.delete(stamp.id) }
            Button("취소", role: .cancel) { }
        }
        .preferredColorScheme(.dark)
    }

    /// The wall grid, with a tappable empty backdrop that fans out the collection.
    private func wallScroll(viewportHeight: CGFloat) -> some View {
        ScrollView {
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, minHeight: viewportHeight)
                    .onTapGesture {
                        guard !collection.collectedStamps.isEmpty else { return }
                        openFan()
                    }

                if stamps.isEmpty {
                    emptyWall
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(stamps) { stamp in
                            NavigationLink {
                                StampDetailView(collection: collection, stampID: stamp.id)
                            } label: {
                                framedArt(stamp)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { wallMenu(for: stamp) }
                            .draggable(stamp.id) {
                                framedArt(stamp).frame(width: 90)   // drag preview
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let dragged = items.first,
                                      let toIndex = stamps.firstIndex(where: { $0.id == stamp.id })
                                else { return false }
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    collection.reorderExhibition(exhibition, moving: dragged, to: toIndex)
                                }
                                return true
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private func fanPivot(_ size: CGSize) -> CGPoint {
        rightHanded ? CGPoint(x: size.width - 30, y: size.height - 18)
                    : CGPoint(x: 30, y: size.height - 18)
    }
    /// Direction (radians) the front card points: up-left for a right thumb,
    /// up-right for a left thumb.
    private var fanBaseAngle: CGFloat { rightHanded ? -2.356 : -0.785 }
    private func angleDiff(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = a - b
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    /// A hwatu deck fanned in an arc out of the thumb corner. Swipe around the
    /// corner to scroll the deck (wrapping); pull a card outward to draw it;
    /// tap anywhere else to fold it back.
    @ViewBuilder
    private func fanTray(in size: CGSize) -> some View {
        let all = collection.collectedStamps          // oldest → newest
        let count = all.count
        if count > 0 {
            let pivot = fanPivot(size)
            let centerIdx = Int(fanScroll.rounded())
            let r = min(3, max(0, count / 2))
            let baseAI = centerIdx - r
            ZStack {
                ForEach((centerIdx - r)...(centerIdx + r), id: \.self) { ai in
                    let s = CGFloat(ai) - fanScroll
                    let idx = ((ai % count) + count) % count
                    let isFront = ai == centerIdx
                    let drawing = isFront && fanDragMode == .draw
                    // spread out from the corner: angle and radius scale with fanSpread
                    let angle = fanBaseAngle + s * fanCardAngle * fanSpread
                    let radius = fanRadius * (0.3 + 0.7 * fanSpread)
                    let radial = CGPoint(x: pivot.x + radius * cos(angle),
                                         y: pivot.y + radius * sin(angle))
                    fanCard(all[idx])
                        .scaleEffect(drawing ? 1.3 : (isFront ? 1.12 : 1))
                        .opacity(drawing ? 1 : Double(0.4 + 0.6 * fanSpread))
                        // straighten up as it's grabbed out of the fan
                        .rotationEffect(.radians(drawing ? 0 : Double(angle) + .pi / 2))
                        .shadow(color: .black.opacity(drawing ? 0.5 : 0), radius: drawing ? 12 : 0, y: 8)
                        // drawn card follows the finger; others sit on the arc
                        .position(drawing ? drawCardPos : radial)
                        .zIndex(drawing ? 200 : (isFront ? 100 : Double(r) - abs(Double(s))))
                        // 촤라라락 — each card unfurls a beat after the previous
                        .animation(.spring(response: 0.42, dampingFraction: 0.72)
                            .delay(Double(ai - baseAI) * 0.05), value: fanSpread)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(fanGesture(pivot: pivot, count: count, all: all))
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { fanPresented = false }
            }
            .onAppear { fanSpread = 1 }       // trigger the staggered fan-out
            .onDisappear { fanSpread = 0 }
        }
    }

    private func fanGesture(pivot: CGPoint, count: Int, all: [CollectedStamp]) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                let curAngle = atan2(v.location.y - pivot.y, v.location.x - pivot.x)
                let curRadius = hypot(v.location.x - pivot.x, v.location.y - pivot.y)
                if fanDragMode == .none {
                    let startAngle = atan2(v.startLocation.y - pivot.y, v.startLocation.x - pivot.x)
                    let startRadius = hypot(v.startLocation.x - pivot.x, v.startLocation.y - pivot.y)
                    let tangential = abs(angleDiff(curAngle, startAngle)) * curRadius
                    let radial = abs(curRadius - startRadius)
                    fanDragMode = radial > tangential ? .draw : .scrub
                    scrubStartAngle = startAngle
                    fanScrubAnchor = fanScroll
                    drawStartRadius = startRadius
                    drawStartLoc = v.startLocation
                    drawCardPos = v.startLocation
                }
                if fanDragMode == .scrub {
                    let delta = angleDiff(curAngle, scrubStartAngle)
                    let dir: CGFloat = rightHanded ? -1 : 1     // clockwise = forward for a right thumb
                    fanScroll = fanScrubAnchor + dir * delta / fanCardAngle
                } else {
                    drawCardPos = v.location          // the card follows the finger
                }
            }
            .onEnded { v in
                let moved = hypot(v.location.x - drawStartLoc.x, v.location.y - drawStartLoc.y)
                if fanDragMode == .draw && moved > 60 {
                    let idx = ((Int(fanScroll.rounded()) % count) + count) % count
                    let card = all[idx]
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        collection.placeInExhibition(card.id, into: exhibition)
                    }
                    fanPresented = false
                } else if fanDragMode == .scrub {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        fanScroll = fanScroll.rounded()
                    }
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { fanDragMode = .none }
            }
    }

    private func fanCard(_ stamp: CollectedStamp) -> some View {
        Image(uiImage: stamp.image).resizable().scaledToFit()
            .frame(width: 60)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(hex: 0xF6EBBE), Color(hex: 0xEBDBA0)],
                                     startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(hex: 0xCBB870), lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 4, y: 3)
    }

    /// A round handle tucked into the thumb corner, with a few stamps peeking
    /// out in an arc — swipe it open (or tap) to fan the whole deck out.
    private var fanHint: some View {
        let peek = Array(collection.collectedStamps.suffix(maxFan))
        let n = peek.count
        let baseDeg = rightHanded ? -128.0 : -52.0    // up-left / up-right
        return ZStack {
            ForEach(Array(peek.enumerated()), id: \.element.id) { pair in
                let i = pair.offset
                let mid = Double(n - 1) / 2
                let a = baseDeg + (Double(i) - mid) * 15
                fanCard(pair.element)
                    .scaleEffect(0.6)
                    .rotationEffect(.degrees(a + 90))
                    .offset(x: CGFloat(cos(a * .pi / 180)) * 52,
                            y: CGFloat(sin(a * .pi / 180)) * 52)
            }
            VStack(spacing: 2) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 17, weight: .bold))
                    .symbolEffect(.bounce, options: .repeating)
                Text("우표 걸기")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(width: 62, height: 62)
            .background(Circle().fill(.ultraThinMaterial))
            .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
        }
        .frame(width: 150, height: 150)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 6).onEnded { _ in openFan() })
        .onTapGesture { openFan() }
    }

    private func openFan() {
        let count = collection.collectedStamps.count
        fanScroll = CGFloat(max(0, count - 1))   // start on the newest card
        fanDragMode = .none
        fanSpread = 0                            // collapsed → onAppear fans it out
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { fanPresented = true }
    }

    @ViewBuilder
    private func wallMenu(for stamp: CollectedStamp) -> some View {
        Button { collection.returnToCollection(stamp.id) } label: {
            Label("컬렉션으로 되돌리기", systemImage: "arrow.uturn.backward")
        }
        if collection.exhibitions.count > 1 {
            Menu {
                ForEach(collection.exhibitions.filter { $0.name != exhibition }) { ex in
                    Button(ex.name) { collection.moveExhibitedStamp(stamp.id, to: ex.name) }
                }
            } label: {
                Label("다른 전시로", systemImage: "arrow.right.square")
            }
        }
        Divider()
        Button(role: .destructive) { deleteTarget = stamp } label: {
            Label("삭제", systemImage: "trash")
        }
    }

    /// A stamp hung on the wall — just the stamp itself, no frame or mat, so its
    /// own (soon customizable) border is what shows.
    private func framedArt(_ stamp: CollectedStamp) -> some View {
        Image(uiImage: stamp.image)
            .resizable().scaledToFit()
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.4), radius: 5, y: 4)
    }

    private var emptyWall: some View {
        let dark = collection.backgroundStyle(of: exhibition).isDark
        let ink = dark ? Color.white : Color(hex: 0x6B5836)
        return VStack(spacing: 12) {
            Image(systemName: "photo.artframe")
                .font(.system(size: 44))
                .foregroundStyle(ink.opacity(0.4))
            Text("이 전시는 비어 있어요")
                .foregroundStyle(ink.opacity(0.8))
            Text(collection.collectedStamps.isEmpty
                 ? "먼저 카메라로 우표를 모아보세요"
                 : "아래 ‘우표 걸기’에서 우표를 꺼내 걸어보세요")
                .font(.system(size: 13))
                .foregroundStyle(ink.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120).padding(.horizontal, 40)
    }
}

// MARK: - Collection store (disk-backed)

struct CollectedStamp: Identifiable {
    let id: String
    let image: UIImage
    var caption: String
    var album: String          // which collecting book this stamp lives in
    let createdAt: Date        // when this stamp was made
    var place: String          // where it was made (human-readable; may be empty)
}

/// A curated wall of stamps pulled out of the collection and hung up to show
/// off. The stamp ids are kept in display order (drag-to-reorder writes this).
struct Exhibition: Identifiable {
    var id: String { name }
    let name: String
    let stampIDs: [String]     // ordered
    var background: String = BackgroundStyle.cream.rawValue   // diary-paper style id

    var backgroundStyle: BackgroundStyle { BackgroundStyle(rawValue: background) ?? .cream }
    /// A copy with a new ordered id list, keeping name + background.
    func with(stampIDs ids: [String]) -> Exhibition {
        Exhibition(name: name, stampIDs: ids, background: background)
    }
}

/// A disk-backed stamp collection organised into albums ("우표첩"). New photos
/// are filed into the *active* album, the way you'd press fresh stamps into the
/// page of a collecting book.
final class CollectionStore: ObservableObject {
    static let defaultAlbum = "내 우표첩"

    @Published private(set) var stamps: [CollectedStamp] = []
    @Published private(set) var albums: [String] = []
    @Published private(set) var activeAlbum: String = ""
    @Published private(set) var exhibitions: [Exhibition] = [] {
        didSet { exhibitedIDCache = Set(exhibitions.flatMap(\.stampIDs)) }
    }
    private var exhibitedIDCache: Set<String> = []

    private let dir: URL
    private var metaURL: URL { dir.appendingPathComponent("albums.json") }
    private var exhibitionsURL: URL { dir.appendingPathComponent("exhibitions.json") }
    private struct Meta: Codable { var albums: [String]; var active: String }
    private struct ExhibitionRecord: Codable { var name: String; var stampIDs: [String]; var background: String? }
    private struct ExhibitionsFile: Codable { var exhibitions: [ExhibitionRecord] }

    /// Per-stamp sidecar: when/where it was made, plus the crop region in the
    /// saved original photo (0...1) so it can later be re-cropped with a custom
    /// border.
    private struct StampMeta: Codable {
        var createdAt: Date
        var latitude: Double?
        var longitude: Double?
        var place: String?
        var cropX: Double? = nil
        var cropY: Double? = nil
        var cropW: Double? = nil
        var cropH: Double? = nil
        var mirrored: Bool? = nil
    }
    private func stampMetaURL(for id: String) -> URL {
        dir.appendingPathComponent(id).appendingPathExtension("json")
    }
    /// The full pre-crop photo, kept so the stamp can be re-made with a different
    /// border later.
    private func originalURL(for id: String) -> URL {
        dir.appendingPathComponent("\(id).orig.jpg")
    }
    /// Loads the original pre-crop photo for a stamp, if saved.
    func originalImage(for id: String) -> UIImage? {
        UIImage(contentsOfFile: originalURL(for: id).path)
    }
    private func writeStampMeta(_ meta: StampMeta, for id: String) {
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: stampMetaURL(for: id))
        }
    }

    /// `directory` lets tests point the store at an isolated temp folder; in the
    /// app it defaults to Documents/Collection.
    init(directory: URL? = nil) {
        dir = directory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Collection", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadStamps()
        loadMeta()
        loadExhibitions()
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

                // when/where, from the sidecar — falling back to the id's epoch
                // timestamp for stamps made before this was tracked.
                let createdAt: Date
                let place: String
                if let data = try? Data(contentsOf: url.appendingPathExtension("json")),
                   let meta = try? JSONDecoder().decode(StampMeta.self, from: data) {
                    createdAt = meta.createdAt
                    place = meta.place ?? ""
                } else {
                    let ms = Double(url.deletingPathExtension().lastPathComponent) ?? 0
                    createdAt = ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : Date()
                    place = ""
                }
                return CollectedStamp(id: url.lastPathComponent, image: image,
                                      caption: caption, album: album,
                                      createdAt: createdAt, place: place)
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

    private func loadExhibitions() {
        guard let data = try? Data(contentsOf: exhibitionsURL),
              let file = try? JSONDecoder().decode(ExhibitionsFile.self, from: data) else { return }
        exhibitions = file.exhibitions.map {
            Exhibition(name: $0.name, stampIDs: $0.stampIDs,
                       background: $0.background ?? BackgroundStyle.cream.rawValue)
        }
    }
    private func saveExhibitions() {
        let file = ExhibitionsFile(exhibitions: exhibitions.map {
            ExhibitionRecord(name: $0.name, stampIDs: $0.stampIDs, background: $0.background)
        })
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: exhibitionsURL, options: .atomic)
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
        reconcileExhibitions()
    }

    /// Drop exhibition ids whose stamp is gone, and enforce single-membership
    /// (an id in two exhibitions keeps only the first). Persist if anything changed.
    private func reconcileExhibitions() {
        guard !exhibitions.isEmpty else { return }
        let live = Set(stamps.map(\.id))
        var seen = Set<String>()
        var changed = false
        let cleaned: [Exhibition] = exhibitions.map { ex in
            let ids = ex.stampIDs.filter { id in
                guard live.contains(id), !seen.contains(id) else { changed = true; return false }
                seen.insert(id); return true
            }
            return ex.with(stampIDs: ids)
        }
        if changed { exhibitions = cleaned; saveExhibitions() }
    }

    // MARK: - Queries

    /// Stamps still in the collection (not hung in any exhibition).
    var collectedStamps: [CollectedStamp] { stamps.filter { !exhibitedIDCache.contains($0.id) } }

    func isExhibited(_ id: String) -> Bool { exhibitedIDCache.contains(id) }

    /// Stamps in a collecting album — excludes any currently hung in an exhibition.
    func stamps(in album: String) -> [CollectedStamp] {
        stamps.filter { $0.album == album && !exhibitedIDCache.contains($0.id) }
    }
    func count(in album: String) -> Int {
        stamps.reduce(0) { $0 + ($1.album == album && !exhibitedIDCache.contains($1.id) ? 1 : 0) }
    }

    /// Stamps hung in an exhibition, in their stored display order.
    func stampsInExhibition(_ name: String) -> [CollectedStamp] {
        guard let ex = exhibitions.first(where: { $0.name == name }) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: stamps.map { ($0.id, $0) })
        return ex.stampIDs.compactMap { byID[$0] }
    }
    func exhibitionCount(_ name: String) -> Int {
        exhibitions.first(where: { $0.name == name })?.stampIDs.count ?? 0
    }

    // MARK: - Stamps

    @discardableResult
    func add(_ image: UIImage, location: CLLocation? = nil,
             original: UIImage? = nil, cropNorm: CGRect? = nil, mirrored: Bool = false) -> String {
        let now = Date()
        let name = "\(Int(now.timeIntervalSince1970 * 1000)).png"
        let url = dir.appendingPathComponent(name)
        if let data = image.pngData() { try? data.write(to: url) }
        // keep the full pre-crop photo so the border can be customised later
        if let original, let data = original.jpegData(compressionQuality: 0.9) {
            try? data.write(to: originalURL(for: name))
        }
        let album = albums.contains(activeAlbum) ? activeAlbum : (albums.first ?? Self.defaultAlbum)
        try? album.write(to: albumURL(for: name), atomically: true, encoding: .utf8)
        writeStampMeta(StampMeta(createdAt: now,
                                 latitude: location?.coordinate.latitude,
                                 longitude: location?.coordinate.longitude,
                                 place: nil,
                                 cropX: cropNorm.map { Double($0.minX) },
                                 cropY: cropNorm.map { Double($0.minY) },
                                 cropW: cropNorm.map { Double($0.width) },
                                 cropH: cropNorm.map { Double($0.height) },
                                 mirrored: original != nil ? mirrored : nil), for: name)
        stamps.append(CollectedStamp(id: name, image: image, caption: "", album: album,
                                     createdAt: now, place: ""))
        return name
    }

    /// Fills in the human-readable place once reverse-geocoding finishes,
    /// preserving the stored coordinates/time.
    func setPlace(_ place: String, for id: String) {
        guard let idx = stamps.firstIndex(where: { $0.id == id }) else { return }
        stamps[idx].place = place
        var meta = StampMeta(createdAt: stamps[idx].createdAt,
                             latitude: nil, longitude: nil, place: place)
        if let data = try? Data(contentsOf: stampMetaURL(for: id)),
           let existing = try? JSONDecoder().decode(StampMeta.self, from: data) {
            meta = existing
            meta.place = place
        }
        writeStampMeta(meta, for: id)
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
        try? FileManager.default.removeItem(at: stampMetaURL(for: id))
        try? FileManager.default.removeItem(at: originalURL(for: id))
        stamps.removeAll { $0.id == id }
        // also pull it off any exhibition wall
        if exhibitedIDCache.contains(id) {
            exhibitions = exhibitions.map {
                $0.with(stampIDs: $0.stampIDs.filter { $0 != id })
            }
            saveExhibitions()
        }
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

    /// Deletes the album and every stamp whose home is it — including stamps
    /// currently hung in an exhibition (delete() pulls them off the wall too).
    /// Always keeps at least one album.
    func deleteAlbum(_ name: String) {
        guard albums.count > 1, albums.contains(name) else { return }
        for s in stamps.filter({ $0.album == name }) { delete(s.id) }
        albums.removeAll { $0 == name }
        if activeAlbum == name { activeAlbum = albums[0] }
        saveMeta()
    }

    // MARK: - Exhibitions

    private func exhibitionIndex(_ name: String) -> Int? {
        exhibitions.firstIndex(where: { $0.name == name })
    }
    /// Pull an id off whatever wall currently holds it (single-membership).
    private func removeFromAnyExhibition(_ id: String) {
        guard exhibitedIDCache.contains(id) else { return }
        exhibitions = exhibitions.map {
            Exhibition(name: $0.name, stampIDs: $0.stampIDs.filter { $0 != id })
        }
    }

    @discardableResult
    func createExhibition(_ name: String, background: BackgroundStyle = .cream) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !exhibitions.contains(where: { $0.name == n }) else {
            return exhibitions.contains(where: { $0.name == n }) ? n : nil
        }
        exhibitions.append(Exhibition(name: n, stampIDs: [], background: background.rawValue))
        saveExhibitions()
        return n
    }

    func setExhibitionBackground(_ name: String, to style: BackgroundStyle) {
        guard let i = exhibitionIndex(name) else { return }
        exhibitions[i] = Exhibition(name: name, stampIDs: exhibitions[i].stampIDs,
                                    background: style.rawValue)
        saveExhibitions()
    }
    func backgroundStyle(of name: String) -> BackgroundStyle {
        exhibitions.first(where: { $0.name == name })?.backgroundStyle ?? .cream
    }

    /// Hang a collected stamp on an exhibition wall — it leaves the collection.
    func placeInExhibition(_ id: String, into name: String) {
        guard stamps.contains(where: { $0.id == id }) else { return }
        if exhibitionIndex(name) == nil { exhibitions.append(Exhibition(name: name, stampIDs: [])) }
        removeFromAnyExhibition(id)
        guard let i = exhibitionIndex(name) else { return }
        var ids = exhibitions[i].stampIDs
        ids.append(id)
        exhibitions[i] = exhibitions[i].with(stampIDs: ids)
        saveExhibitions()
    }

    /// Take a stamp off the wall — it returns to its home album.
    func returnToCollection(_ id: String) {
        guard exhibitedIDCache.contains(id) else { return }
        removeFromAnyExhibition(id)
        saveExhibitions()
    }

    func moveExhibitedStamp(_ id: String, to name: String) {
        placeInExhibition(id, into: name)
    }

    /// Drag-to-reorder: move `id` to `index` within its exhibition.
    func reorderExhibition(_ name: String, moving id: String, to index: Int) {
        guard let i = exhibitionIndex(name) else { return }
        var ids = exhibitions[i].stampIDs
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        let dest = max(0, min(index, ids.count))
        ids.insert(id, at: dest)
        exhibitions[i] = exhibitions[i].with(stampIDs: ids)
        saveExhibitions()
    }

    /// List/onMove reorder fallback.
    func reorderExhibition(_ name: String, from offsets: IndexSet, to dest: Int) {
        guard let i = exhibitionIndex(name) else { return }
        var ids = exhibitions[i].stampIDs
        ids.move(fromOffsets: offsets, toOffset: dest)
        exhibitions[i] = exhibitions[i].with(stampIDs: ids)
        saveExhibitions()
    }

    func renameExhibition(_ old: String, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != old, let i = exhibitionIndex(old),
              !exhibitions.contains(where: { $0.name == n }) else { return }
        exhibitions[i] = Exhibition(name: n, stampIDs: exhibitions[i].stampIDs,
                                    background: exhibitions[i].background)
        saveExhibitions()
    }

    /// Removes the wall; its stamps return to their home albums (not deleted).
    func deleteExhibition(_ name: String) {
        exhibitions.removeAll { $0.name == name }
        saveExhibitions()
    }
}

// MARK: - Location

/// Tracks the current location so each new stamp can record where it was made,
/// and reverse-geocodes it into a short human-readable place name.
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    @Published var current: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Ask for permission; updates begin once access is granted.
    func start() {
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.current = loc }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {}

    /// A short place name like "서울특별시 종로구" for the given location.
    func placeName(for location: CLLocation) async -> String? {
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(location),
              let m = placemarks.first else { return nil }
        let candidates = [m.administrativeArea,
                          m.locality ?? m.subAdministrativeArea,
                          m.subLocality]
        var seen = Set<String>(), parts: [String] = []
        for case let s? in candidates where !s.isEmpty && !seen.contains(s) {
            seen.insert(s); parts.append(s)
        }
        if parts.isEmpty { return m.name ?? m.country }
        return parts.joined(separator: " ")
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

/// Plays the "punching.mp3" punch sound when the shutter is pressed. The clip
/// is a few seconds long, so we only play the first ~1s and fade it out.
enum PunchSound {
    private static let player: AVAudioPlayer? = {
        guard let url = Bundle.main.url(forResource: "punching", withExtension: "mp3"),
              let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        p.prepareToPlay()
        return p
    }()

    static func play() {
        // audible even alongside other audio
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let p = player else { return }
        p.stop()
        p.currentTime = 0
        p.volume = 1
        p.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            player?.setVolume(0, fadeDuration: 0.15)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            player?.stop()
            player?.volume = 1
        }
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
    @State private var showNewExhibition = false
    @State private var newExhibitionName = ""
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

                    // when & where this stamp was made
                    VStack(spacing: 3) {
                        Text(stamp.createdAt.formatted(date: .long, time: .shortened))
                        if !stamp.place.isEmpty {
                            Label(stamp.place, systemImage: "mappin.and.ellipse")
                        }
                    }
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(hex: 0x8C7A52))
                }
                ZStack(alignment: .top) {
                    // custom placeholder so it stays a readable warm brown
                    // (the field inherits the sheet's dark scheme otherwise,
                    // which painted the prompt white = invisible on parchment)
                    if caption.isEmpty {
                        Text("이건 무슨 순간이에요?")
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
            ToolbarItem(placement: .principal) {
                Menu {
                    ForEach(collection.exhibitions) { ex in
                        Button(ex.name) { collection.placeInExhibition(stampID, into: ex.name) }
                    }
                    Divider()
                    Button { newExhibitionName = ""; showNewExhibition = true } label: {
                        Label("새 전시…", systemImage: "plus")
                    }
                } label: {
                    Label("전시에 걸기", systemImage: "photo.artframe")
                        .font(.system(size: 14, weight: .semibold))
                }
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
        .sheet(isPresented: $showNewExhibition) {
            NewExhibitionSheet(collection: collection) { name in
                collection.placeInExhibition(stampID, into: name)
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
    let interiorMask: UIImage   // white = frame body + window, clear = outside the frame
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

        // Build a mask of the frame's interior (the outer silhouette: frame body
        // + window) so it can be punched out of a full-screen blur — leaving the
        // busy live scene OUTSIDE the frame softened while the frame and its
        // window stay crisp. White = frame + window, clear = exterior.
        let maskBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { maskBuf.deallocate() }
        for i in 0..<(w * h) {
            let v: UInt8 = exterior[i] ? 0 : 255
            maskBuf[i * 4 + 0] = v
            maskBuf[i * 4 + 1] = v
            maskBuf[i * 4 + 2] = v
            maskBuf[i * 4 + 3] = v
        }
        guard let maskCtx = CGContext(
            data: maskBuf, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let maskCG = maskCtx.makeImage() else { return nil }
        let interiorMask = UIImage(cgImage: maskCG, scale: source.scale,
                                   orientation: source.imageOrientation)

        // The asset is already cut out, so use it as-is.
        return StampFrame(image: source, windowRectNorm: rectNorm,
                          interiorMask: interiorMask)
    }
}

#Preview {
    ContentView()
}
