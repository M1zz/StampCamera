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
    // toss physics: most captures drop, bounce & slide on the floor; a rare few
    // (< 15%) fling clean off the screen.
    @State private var tossTrigger = 0
    @State private var tossOffscreen = false
    @State private var slideX: CGFloat = 0        // how far it skids along the floor
    @State private var groundY: CGFloat = 0       // downward offset to the floor
    @State private var tossSpin: Double = 0       // final tilt (drop) / spin (fling)
    @State private var offscreenVec: CGSize = .zero
    @State private var binCenter: CGPoint = .zero
    @State private var binBounce = false
    @State private var stayingStamp: UIImage?  // capture left sitting in the window
    @State private var stayVisible = false      // fades the staying imprint out
    @State private var pressed = false
    @State private var flipAngle: Double = 0    // selfie/back flip spin

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

                // ...while a cropped copy pops out and — most of the time — drops,
                // bounces and skids along the floor (툭, 톡톡), squashing as it goes;
                // a rare few fling clean off the screen.
                if let flying {
                    tossOverlay(flying)
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

    /// Top bar: the album chip centered, with the selfie flip button on the right.
    private var albumBar: some View {
        VStack {
            ZStack {
                albumChip                    // centered
                HStack {
                    Spacer()
                    flipButton               // top-right (selfie toggle)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
    }

    /// The book-picker chip: shows which book new stamps go into, with a menu
    /// to switch books or start a new one.
    private var albumChip: some View {
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
    }

    /// Flips between the back and front (selfie) camera with a little spin.
    private var flipButton: some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { flipAngle += 180 }
            Haptics.select()
            camera.flipCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .rotationEffect(.degrees(flipAngle))
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                collectionButton             // bottom-left (gallery)
                if camera.maxZoom > camera.minZoom + 0.01 {
                    ZoomSlider(camera: camera) // fills the row to the gallery's right
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

        // The capture stays imprinted in the window. A cropped copy pops out and,
        // most of the time, drops to the floor — bouncing and skidding (툭, 톡톡) —
        // while a rare few (< 15%) fling clean off the screen.
        flyStart = win
        stayingStamp = stamp
        stayVisible = true
        flying = stamp

        tossOffscreen = Double.random(in: 0 ..< 1) < 0.13       // under 15% fly away
        slideX = CGFloat.random(in: 36 ... 120) * (Bool.random() ? 1 : -1)
        groundY = max(120, (previewSize.height - 70) - win.midY) // floor near the bin
        if tossOffscreen {
            let angle = Double.random(in: 0 ..< (2 * .pi))
            let dist = hypot(previewSize.width, previewSize.height) * 1.3
            offscreenVec = CGSize(width: CGFloat(cos(angle)) * dist,
                                  height: CGFloat(sin(angle)) * dist)
            tossSpin = Double.random(in: -260 ... 260)
        } else {
            tossSpin = Double.random(in: -10 ... 10)            // a small resting tilt
        }
        tossTrigger += 1                                        // fire the toss keyframes

        let landTime = tossOffscreen ? 0.42 : 0.30
        let settleTime = tossOffscreen ? 0.5 : 0.72
        let here = location.current
        let mine = stamp   // identity guard against a faster follow-up shot

        // The lighter "톡" of the second bounce (floor drop only).
        if !tossOffscreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + landTime + 0.16) { Haptics.bounce() }
        }

        // The moment it lands (floor impact, or leaves the frame): file it into the
        // collection, thump the bin, and give a hearty haptic.
        DispatchQueue.main.asyncAfter(deadline: .now() + landTime) {
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
            Haptics.plop()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { binBounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { binBounce = false }
            }
            // clear the tossed copy once it has settled
            DispatchQueue.main.asyncAfter(deadline: .now() + (settleTime - landTime)) {
                if flying === mine { flying = nil }
            }
            // The captured photo holds in the frame window ~2s (from the shutter),
            // then fades back to the live preview and opens the parchment.
            DispatchQueue.main.asyncAfter(deadline: .now() + (2.0 - landTime)) {
                guard stayingStamp === mine else { return }   // a newer shot took over
                withAnimation(.easeOut(duration: 0.4)) { stayVisible = false }
                editTarget = EditTarget(id: newID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if stayingStamp === mine { stayingStamp = nil }
                }
            }
        }
    }

    /// The animated state of a tossed stamp tile.
    private struct TossValues {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rotation: Double = 0
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
    }

    /// The tossed copy of a fresh stamp. The toss kind is fixed per capture, so we
    /// branch the view (not the keyframe builder, which can't fork track sets).
    @ViewBuilder
    private func tossOverlay(_ flying: UIImage) -> some View {
        let tile = Image(uiImage: flying)
            .resizable().scaledToFit()
            .frame(width: flyStart.width, height: flyStart.height)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
        Group {
            if tossOffscreen {
                tile.keyframeAnimator(initialValue: TossValues(), trigger: tossTrigger) { view, v in
                    view.scaleEffect(x: v.scaleX, y: v.scaleY, anchor: .bottom)
                        .rotationEffect(.degrees(v.rotation))
                        .offset(x: v.x, y: v.y)
                } keyframes: { _ in flingKeyframes() }
            } else {
                tile.keyframeAnimator(initialValue: TossValues(), trigger: tossTrigger) { view, v in
                    view.scaleEffect(x: v.scaleX, y: v.scaleY, anchor: .bottom)
                        .rotationEffect(.degrees(v.rotation))
                        .offset(x: v.x, y: v.y)
                } keyframes: { _ in floorKeyframes() }
            }
        }
        .position(x: flyStart.midX, y: flyStart.midY)
        .allowsHitTesting(false)
    }

    /// 툭 → 톡톡 — pop, fall, bounce twice and skid along the floor while squashing.
    @KeyframesBuilder<TossValues>
    private func floorKeyframes() -> some Keyframes<TossValues> {
        KeyframeTrack(\.y) {
            CubicKeyframe(-14, duration: 0.08)
            CubicKeyframe(groundY, duration: 0.22)
            CubicKeyframe(groundY - 26, duration: 0.12)
            CubicKeyframe(groundY, duration: 0.10)
            CubicKeyframe(groundY - 8, duration: 0.08)
            CubicKeyframe(groundY, duration: 0.12)
        }
        KeyframeTrack(\.x) {
            CubicKeyframe(slideX * 0.2, duration: 0.30)
            CubicKeyframe(slideX * 0.7, duration: 0.22)
            CubicKeyframe(slideX, duration: 0.20)
        }
        KeyframeTrack(\.rotation) {
            CubicKeyframe(tossSpin * 0.4, duration: 0.30)
            CubicKeyframe(tossSpin, duration: 0.30)
        }
        KeyframeTrack(\.scaleX) {
            CubicKeyframe(0.90, duration: 0.08)
            CubicKeyframe(1.28, duration: 0.22)
            CubicKeyframe(0.96, duration: 0.12)
            CubicKeyframe(1.12, duration: 0.10)
            CubicKeyframe(1.0, duration: 0.20)
        }
        KeyframeTrack(\.scaleY) {
            CubicKeyframe(1.18, duration: 0.08)
            CubicKeyframe(0.72, duration: 0.22)
            CubicKeyframe(1.08, duration: 0.12)
            CubicKeyframe(0.92, duration: 0.10)
            CubicKeyframe(1.0, duration: 0.20)
        }
    }

    /// The rare clean fling off the screen, spinning with a burst.
    @KeyframesBuilder<TossValues>
    private func flingKeyframes() -> some Keyframes<TossValues> {
        KeyframeTrack(\.x) { SpringKeyframe(offscreenVec.width, duration: 0.5, spring: .snappy) }
        KeyframeTrack(\.y) { SpringKeyframe(offscreenVec.height, duration: 0.5, spring: .snappy) }
        KeyframeTrack(\.rotation) { LinearKeyframe(tossSpin, duration: 0.5) }
        KeyframeTrack(\.scaleX) {
            CubicKeyframe(1.25, duration: 0.12); CubicKeyframe(1.0, duration: 0.38)
        }
        KeyframeTrack(\.scaleY) {
            CubicKeyframe(1.25, duration: 0.12); CubicKeyframe(1.0, duration: 0.38)
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

/// A pushable destination inside the 모음 navigation stack.
enum CollectionRoute: Hashable {
    case album(String)
    case exhibition(String)
}

struct CollectionView: View {
    @ObservedObject var collection: CollectionStore
    @Environment(\.dismiss) private var dismiss

    /// Starts deep-linked to the album last opened from the camera button — back
    /// from there lands on the 모음 overview, where 컬렉션 is one segment away.
    @State private var path: [CollectionRoute]

    init(collection: CollectionStore) {
        _collection = ObservedObject(wrappedValue: collection)
        let last = UserDefaults.standard.string(forKey: "lastVisitedAlbum") ?? ""
        _path = State(initialValue: (!last.isEmpty && collection.albums.contains(last))
                                    ? [.album(last)] : [])
    }

    @State private var showNewAlbum = false
    @State private var newAlbumName = ""
    @State private var showNewExhibition = false
    @State private var newExhibitionName = ""

    private enum Tab: String, CaseIterable { case albums = "우표첩", exhibitions = "컬렉션" }
    @State private var tab: Tab = .albums

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 18)]

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 6)

                ScrollView {
                    switch tab {
                    case .albums: albumShelf
                    case .exhibitions: exhibitionWalls
                    }
                }
            }
            .background(Color(hex: 0x141210).ignoresSafeArea())
            .navigationTitle("모음")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: CollectionRoute.self) { route in
                switch route {
                case .album(let name):
                    AlbumPageView(collection: collection, album: name)
                case .exhibition(let name):
                    ExhibitionWallView(collection: collection, exhibition: name)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { newAlbumName = ""; showNewAlbum = true } label: {
                            Label("새 우표첩…", systemImage: "book.closed")
                        }
                        Button { newExhibitionName = ""; showNewExhibition = true } label: {
                            Label("새 컬렉션…", systemImage: "photo.artframe")
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

    private var albumShelf: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(collection.albums, id: \.self) { album in
                NavigationLink(value: CollectionRoute.album(album)) {
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
                Text("아직 컬렉션이 없어요")
                    .foregroundStyle(.white.opacity(0.7))
                Text("우표첩에서 우표를 길게 눌러 컬렉션에 걸어보세요")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 80).padding(.horizontal, 40)
        } else {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(collection.exhibitions) { ex in
                    NavigationLink(value: CollectionRoute.exhibition(ex.name)) {
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
                            .frame(height: 72)
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

/// One month's worth of stamps on an album page.
private struct StampSection: Identifiable {
    let id: String
    let title: String
    let stamps: [CollectedStamp]
}

struct AlbumPageView: View {
    @ObservedObject var collection: CollectionStore
    let album: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastVisitedAlbum") private var lastVisitedAlbum = ""

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteAlbum = false
    @State private var deleteTarget: CollectedStamp?
    @State private var showNewExhibition = false
    @State private var newExhibitionName = ""
    @State private var exhibitTarget: CollectedStamp?

    // Tapping a stamp opens its detail as a modal (not a pushed page).
    @State private var selectedStamp: CollectedStamp?

    // Long-press lifts a stamp (`armed`); only once the finger actually moves does
    // the collection tray appear and the stamp become a `dragging` ghost — so a mere
    // hold never slams the tray up.
    @State private var armed: CollectedStamp?
    @State private var dragging: CollectedStamp?
    @State private var dragPoint: CGPoint?
    @State private var hoveredExhibition: String?
    @State private var exhibitionFrames: [String: CGRect] = [:]

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

    /// The album's stamps grouped by month, newest section first.
    private var sections: [StampSection] {
        let groups = Dictionary(grouping: stamps) { periodKey($0.createdAt).sort }
        return groups.map { _, value in
            StampSection(id: "period-\(periodKey(value[0].createdAt).sort)",
                         title: periodKey(value[0].createdAt).title,
                         stamps: value.sorted { $0.createdAt > $1.createdAt })
        }
        .sorted {
            ($0.stamps.first?.createdAt ?? .distantPast) > ($1.stamps.first?.createdAt ?? .distantPast)
        }
    }

    var body: some View {
      ZStack {
        ScrollView {
            if stamps.isEmpty {
                emptyPage
            } else {
                LazyVStack(spacing: 16) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar")
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
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
        }
        .scrollDisabled(armed != nil || dragging != nil)
        .background(Color(hex: 0x141210).ignoresSafeArea())

        // The dim + card tray depends only on which stamp / card is active, so it
        // stays put while the finger moves; the ghost is a separate, lightweight
        // layer that alone re-renders per frame — keeping the material tray smooth.
        if let dragging { dragTray(dragging) }
        if let dragging, let p = dragPoint { dragGhost(dragging, at: p) }
      }
      .coordinateSpace(name: "album")
      .onPreferenceChange(ExhibitionFrameKey.self) { exhibitionFrames = $0 }
      .onAppear { lastVisitedAlbum = album }   // remember for the camera shortcut
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
        .sheet(item: $selectedStamp, onDismiss: { Haptics.deselect() }) { stamp in
            NavigationStack {
                StampDetailView(collection: collection, stampID: stamp.id)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// The 4-up grid of stamps for one section. A quick tap opens the detail as a
    /// modal; a long press lifts the stamp; *moving* the lifted stamp brings up the
    /// collection cards to drag it onto. (Scrolling stays intact — the lift only
    /// engages after the hold, and the tray only after the finger moves.)
    private func stampGrid(_ list: [CollectedStamp]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(list) { stamp in stampCell(stamp) }
        }
    }

    private func stampCell(_ stamp: CollectedStamp) -> some View {
        let isArmed = armed?.id == stamp.id
        let isDragging = dragging?.id == stamp.id
        return pagePocket(stamp)
            .opacity(isDragging ? 0.25 : 1)
            // a gentle lift while held, before any drag begins
            .scaleEffect(isArmed && !isDragging ? 1.12 : 1)
            .shadow(color: .black.opacity(isArmed && !isDragging ? 0.45 : 0),
                    radius: isArmed && !isDragging ? 9 : 0, y: 6)
            .zIndex(isArmed ? 1 : 0)
            .animation(.spring(response: 0.26, dampingFraction: 0.7), value: isArmed)
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.select()
                selectedStamp = stamp
            }
            .gesture(stampDragGesture(stamp))
    }

    /// Hold to lift, then drag to carry: the long press only *lifts* the stamp; the
    /// collection tray appears only once the finger has moved enough to mean "carry
    /// it" — so resting a finger never throws up the tray.
    private func stampDragGesture(_ stamp: CollectedStamp) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("album")))
            .onChanged { value in
                switch value {
                case .first(true):
                    armLift(stamp)
                case .second(true, let drag):
                    guard let drag else { return }
                    if dragging == nil {
                        let moved = hypot(drag.translation.width, drag.translation.height)
                        guard moved > 14 else { return }   // wait for a real drag
                        promoteToDrag()
                    }
                    updateDrag(to: drag.location)
                default:
                    break
                }
            }
            .onEnded { value in
                if case .second(_, let drag?) = value, dragging != nil {
                    endDrag(at: drag.location)
                } else {
                    cancelLift()
                }
            }
    }

    // MARK: - Long-press → drag a stamp onto an exhibition card

    /// Sentinel card key that opens the "new exhibition" sheet on drop.
    private static let newExhibitionKey = "\u{1}new-exhibition"
    /// How far above the fingertip the carried stamp rides — the drop is hit-tested
    /// at this same lifted point so the visible stamp is what lands on a card.
    private static let ghostLift: CGFloat = 38

    /// The card the carried stamp is currently over (hit-tested at the ghost, not
    /// the raw fingertip, so they always agree).
    private func dropTarget(at p: CGPoint) -> String? {
        let tip = CGPoint(x: p.x, y: p.y - Self.ghostLift)
        return exhibitionFrames.first { $0.value.contains(tip) }?.key
    }

    /// Long press recognised — lift the stamp, but don't reveal the tray yet.
    private func armLift(_ stamp: CollectedStamp) {
        guard armed == nil, dragging == nil else { return }
        armed = stamp
        Haptics.select()                       // the stamp lifts off the page
    }

    /// The finger moved while holding — now reveal the collection tray and carry.
    private func promoteToDrag() {
        guard let stamp = armed else { return }
        dragPoint = nil
        hoveredExhibition = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { dragging = stamp }
    }

    /// Held and released without moving — set the stamp back down, no tray.
    private func cancelLift() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            armed = nil
            dragging = nil
        }
        dragPoint = nil
        hoveredExhibition = nil
    }

    private func updateDrag(to p: CGPoint) {
        dragPoint = p
        let hit = dropTarget(at: p)
        if hit != hoveredExhibition {
            hoveredExhibition = hit
            if hit != nil { Haptics.bounce() }  // tick as it enters a card
        }
    }

    private func endDrag(at p: CGPoint?) {
        if let p, let stamp = dragging,
           let name = dropTarget(at: p) {
            if name == Self.newExhibitionKey {
                exhibitTarget = stamp
                newExhibitionName = ""
                showNewExhibition = true
            } else {
                collection.placeInExhibition(stamp.id, into: name)
                Haptics.placed()                // dropped into an exhibition
            }
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            dragging = nil
            armed = nil
        }
        dragPoint = nil
        hoveredExhibition = nil
    }

    /// The dim + card tray shown while a stamp is lifted. Non-interactive — the
    /// drag is hit-tested against the cards' reported frames, so it never steals
    /// the gesture. Depends only on `dragging`/`hoveredExhibition`, so it doesn't
    /// re-render as the finger moves.
    @ViewBuilder
    private func dragTray(_ stamp: CollectedStamp) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .transition(.opacity)

            VStack {
                Spacer(minLength: 0)
                VStack(spacing: 12) {
                    Text(collection.exhibitions.isEmpty ? "새 컬렉션을 만들어 옮기기" : "컬렉션으로 끌어다 옮기기")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    exhibitionCardGrid
                }
                .padding(.vertical, 18)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }

    /// The lifted stamp's ghost trailing the finger — its own thin layer so only it
    /// repaints per frame.
    private func dragGhost(_ stamp: CollectedStamp, at p: CGPoint) -> some View {
        pagePocket(stamp)
            .frame(width: 86)
            .scaleEffect(1.1)
            .rotationEffect(.degrees(-4))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 7)
            .position(x: p.x, y: p.y - Self.ghostLift)   // carried above the fingertip
            .allowsHitTesting(false)
    }

    private var exhibitionCardGrid: some View {
        let cols = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12)]
        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(collection.exhibitions) { ex in
                exhibitionDropCard(name: ex.name,
                                   peek: collection.stampsInExhibition(ex.name).prefix(3).map(\.image),
                                   isNew: false)
            }
            exhibitionDropCard(name: Self.newExhibitionKey, peek: [], isNew: true)
        }
    }

    private func exhibitionDropCard(name: String, peek: [UIImage], isNew: Bool) -> some View {
        let lit = hoveredExhibition == name
        return VStack(spacing: 8) {
            ZStack {
                if isNew {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x8C7A52))
                } else if peek.isEmpty {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 24))
                        .foregroundStyle(Color(hex: 0x8C7A52))
                } else {
                    ForEach(Array(peek.enumerated()), id: \.offset) { i, img in
                        Image(uiImage: img).resizable().scaledToFit()
                            .frame(height: 46)
                            .rotationEffect(.degrees(Double(i - 1) * 6))
                            .offset(x: CGFloat(i - 1) * 9)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                }
            }
            .frame(height: 50)
            Text(isNew ? "새 컬렉션" : name)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(hex: 0x4A3D22))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 94)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xF6EBBE), Color(hex: 0xEBDBA0)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(hex: lit ? 0xE8504E : 0xCBB870),
                              style: StrokeStyle(lineWidth: lit ? 3 : 1, dash: isNew ? [5] : []))
        )
        .scaleEffect(lit ? 1.06 : 1)
        .animation(.easeOut(duration: 0.14), value: lit)
        .background(
            GeometryReader { g in
                Color.clear.preference(key: ExhibitionFrameKey.self,
                                       value: [name: g.frame(in: .named("album"))])
            }
        )
    }


    /// One stamp pressed onto the album page — just the stamp itself, its own
    /// perforated edge showing, with a soft shadow for a little lift.
    private func pagePocket(_ stamp: CollectedStamp) -> some View {
        Image(uiImage: stamp.image)
            .resizable().scaledToFit()
            .frame(height: 78)
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
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
                    TextField("컬렉션 이름", text: $name)
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
            .navigationTitle("새 컬렉션")
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

    // Tapping a hung stamp opens its detail as a modal (not a pushed page).
    @State private var selectedStamp: CollectedStamp?

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
    @State private var folding = false                // collapse runs the stagger in reverse
    @State private var lastFanDetent = 0              // last front-card index, for scrub ticks
    private let maxFan = 3                            // peek count for the hint
    private let fanRadius: CGFloat = 196             // arc radius from the corner
    private let fanCardAngle: CGFloat = 0.27         // radians between cards (~15.5°)

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
    private let perPage = 12                           // a 3×4 spread per leaf
    private var stamps: [CollectedStamp] { collection.stampsInExhibition(exhibition) }
    /// The sparse cell layout (nil = empty cell) driving the grid.
    private var slots: [String?] { collection.slots(in: exhibition) }
    private func stampByID(_ id: String) -> CollectedStamp? {
        collection.stamps.first { $0.id == id }
    }
    /// Pages that actually hold cells (filled or deliberately-left-empty).
    private var filledPages: Int {
        max(1, Int(ceil(Double(slots.count) / Double(perPage))))
    }
    /// One blank leaf always trails the filled pages, so swiping past the last
    /// page turns onto a fresh page (1/1 → swipe → a new 2번째 장).
    private var pageCount: Int { filledPages + 1 }
    @State private var currentPage = 0

    // The "우표 걸기" button hides itself so the finished wall can be enjoyed;
    // a tap on the paper flashes it back for a few seconds.
    @State private var fanVisible = false
    @State private var hideFanWork: DispatchWorkItem?

    // Once a stamp is drawn from the deck it becomes "in hand": the fan folds
    // away and the wall waits for a tap on the cell where it should be hung.
    @State private var pendingStamp: CollectedStamp?
    @State private var heldBob = false        // gentle float on the carried stamp

    /// Whether the chosen diary paper is dark — drives whether text/title read as
    /// white or ink so nothing vanishes when the background colour changes.
    private var isDark: Bool { collection.backgroundStyle(of: exhibition).isDark }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                wallContent(viewportHeight: geo.size.height)
                    .blur(radius: fanPresented ? 2 : 0)
                    .onChange(of: slots.count) { _, _ in
                        if currentPage > pageCount - 1 { currentPage = max(0, pageCount - 1) }
                    }

                // "우표 걸기" handle in the thumb corner. While the wall is being
                // enjoyed it tucks down to a half-circle nub at the bottom edge;
                // tap/drag the nub (or tap the paper) and the full handle rises
                // back, ready to burst into the fanned deck.
                if !fanPresented && pendingStamp == nil && !collection.collectedStamps.isEmpty {
                    if fanVisible {
                        fanHint
                            .position(fanPivot(geo.size))
                            .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
                    } else {
                        fanNub
                            .position(nubCenter(geo.size))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                if fanPresented {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .allowsHitTesting(false)
                    fanTray(in: geo.size)
                        .transition(.opacity)
                }

                if let p = pendingStamp {
                    placingOverlay(p)
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
                        Label("컬렉션 삭제", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("이름 변경", isPresented: $showRename) {
            TextField("컬렉션 이름", text: $renameText)
            Button("취소", role: .cancel) { }
            Button("저장") { collection.renameExhibition(exhibition, to: renameText) }
        }
        .confirmationDialog("컬렉션 '\(exhibition)' 을(를) 삭제할까요? 걸려 있던 우표들은 원래 우표첩으로 돌아가요.",
                            isPresented: $showDelete, titleVisibility: .visible) {
            Button("컬렉션 삭제", role: .destructive) { collection.deleteExhibition(exhibition); dismiss() }
            Button("취소", role: .cancel) { }
        }
        .confirmationDialog("이 우표를 삭제할까요?", isPresented: deletePresented,
                            titleVisibility: .visible, presenting: deleteTarget) { stamp in
            Button("삭제", role: .destructive) { collection.delete(stamp.id) }
            Button("취소", role: .cancel) { }
        }
        .sheet(item: $selectedStamp, onDismiss: { Haptics.deselect() }) { stamp in
            NavigationStack {
                StampDetailView(collection: collection, stampID: stamp.id)
            }
        }
        // Title + toolbar follow the paper: white on dark papers, ink on light ones,
        // so the exhibition name never disappears into the background.
        .toolbarColorScheme(isDark ? .dark : .light, for: .navigationBar)
        .preferredColorScheme(isDark ? .dark : .light)
        .onAppear { flashFanButton() }   // greet with the button, then let it fade
    }

    /// Reveal the "우표 걸기" button and schedule it to fade away again, so the
    /// finished wall stays uncluttered between placements.
    private func flashFanButton() {
        guard !collection.collectedStamps.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) { fanVisible = true }
        hideFanWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.4)) { fanVisible = false }
        }
        hideFanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    /// The first empty cell on the page currently shown, so a stamp drawn from
    /// the deck lands on the leaf the user is looking at.
    private func firstEmptySlotOnCurrentPage() -> Int {
        let base = currentPage * perPage
        let s = slots
        for cell in 0..<perPage {
            let idx = base + cell
            if idx >= s.count || s[idx] == nil { return idx }
        }
        return base   // page full → placeInExhibition spills to the next free cell
    }

    /// Hang the in-hand stamp in the tapped cell and end placing mode. An empty
    /// cell takes it exactly; a taken cell spills it to the next free cell.
    private func placePending(at slot: Int) {
        guard let p = pendingStamp else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            collection.placeInExhibition(p.id, into: exhibition, at: slot)
        }
        if let landed = collection.slots(in: exhibition).firstIndex(where: { $0 == p.id }) {
            currentPage = landed / perPage
        }
        Haptics.placed()              // 우표를 골라 둔 자리에 걸었다
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pendingStamp = nil }
    }

    private func cancelPlacing() {
        Haptics.deselect()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pendingStamp = nil }
    }

    /// While placing: a hint bar pinned to the top and the chosen stamp floating
    /// at the bottom as if held in hand — the wall in between stays clear and
    /// tappable so you can pick the spot. The held stamp ignores touches so taps
    /// fall through to the cells beneath it.
    private func placingOverlay(_ stamp: CollectedStamp) -> some View {
        ZStack {
            HStack(spacing: 10) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("원하는 칸을 탭해 내려놓기")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer(minLength: 8)
                Button { cancelPlacing() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)

            Image(uiImage: stamp.image)
                .resizable().scaledToFit()
                .frame(width: 104)
                .rotationEffect(.degrees(-4))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
                .offset(y: heldBob ? -8 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 30)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                        heldBob = true
                    }
                }
                .onDisappear { heldBob = false }
        }
    }

    /// The wall: an empty backdrop you can tap to fan out the collection, or — once
    /// stamps are hung — a book of leaves you swipe through with a real page curl.
    @ViewBuilder
    private func wallContent(viewportHeight: CGFloat) -> some View {
        if stamps.isEmpty && pendingStamp == nil {
            ScrollView {
                ZStack(alignment: .top) {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, minHeight: viewportHeight)
                        .onTapGesture {
                            guard !collection.collectedStamps.isEmpty else { return }
                            openFan()
                        }
                    emptyWall
                }
            }
        } else {
            PageCurlView(pageCount: pageCount, currentPage: $currentPage,
                         contentKey: slots.map { $0 ?? "·" }.joined(separator: ",")
                                     + "|" + collection.backgroundStyle(of: exhibition).rawValue) { pageIndex in
                wallPage(pageIndex)
            }
            .id(exhibition)   // start a fresh book when switching exhibitions
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    /// One leaf of the book: a 3×3 grid of cells on the diary paper, footed with
    /// its page number. Each cell is either a hung stamp or an empty drop slot,
    /// so stamps can be placed in any spot and cells left blank. Opaque so the
    /// curl shows paper on both faces.
    private func wallPage(_ pageIndex: Int) -> some View {
        let pageSlots = slots
        return ZStack {
            DiaryBackground(style: collection.backgroundStyle(of: exhibition))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {                      // tap the paper → show the deck
                    if pendingStamp == nil { flashFanButton() }
                }
            VStack(spacing: 0) {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(0..<perPage, id: \.self) { cell in
                        let slot = pageIndex * perPage + cell
                        let id = slot < pageSlots.count ? pageSlots[slot] : nil
                        if let id, let stamp = stampByID(id) {
                            wallStampCell(stamp, slot: slot)
                        } else {
                            emptyCell(slot: slot)
                        }
                    }
                }
                .padding(18)
                Spacer(minLength: 8)
                pageFooter(pageIndex)
            }
        }
    }

    /// A single hung stamp: tap to open (or, while placing, to drop the in-hand
    /// stamp here), long-press to manage, drag to another cell (the two swap; an
    /// empty cell just receives it).
    private func wallStampCell(_ stamp: CollectedStamp, slot: Int) -> some View {
        Button {
            if pendingStamp != nil {
                placePending(at: slot)
            } else {
                Haptics.select()
                selectedStamp = stamp
            }
        } label: {
            framedArt(stamp)
        }
        .buttonStyle(.plain)
        .contextMenu { wallMenu(for: stamp) }
        .draggable(stamp.id) {
            framedArt(stamp).frame(width: 90)   // drag preview
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first, dragged != stamp.id else { return false }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                collection.moveStamp(dragged, in: exhibition, toSlot: slot)
            }
            Haptics.placed()
            return true
        }
    }

    /// A blank cell — a faint dotted spot you can drop a stamp onto. Kept quiet
    /// so the wall still reads as "finished", but it lights up while a stamp is
    /// in hand so the open spots are obvious.
    private func emptyCell(slot: Int) -> some View {
        let placing = pendingStamp != nil
        let ink = (isDark ? Color.white : Color(hex: 0x6B5836)).opacity(placing ? 0.5 : 0.16)
        return RoundedRectangle(cornerRadius: 8)
            .strokeBorder(ink, style: StrokeStyle(lineWidth: placing ? 2 : 1.5, dash: [5, 5]))
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(placing ? 0.12 : 0)))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                if pendingStamp != nil { placePending(at: slot) }
                else { flashFanButton() }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let dragged = items.first else { return false }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    collection.moveStamp(dragged, in: exhibition, toSlot: slot)
                }
                Haptics.placed()
                return true
            }
    }

    /// The little page number printed at the foot of each leaf.
    private func pageFooter(_ pageIndex: Int) -> some View {
        let dark = collection.backgroundStyle(of: exhibition).isDark
        let ink = dark ? Color.white.opacity(0.7) : Color(hex: 0x6B5836)
        return Text("— \(pageIndex + 1) / \(pageCount) —")
            .font(.system(size: 13, weight: .semibold, design: .serif))
            .foregroundStyle(ink)
            .padding(.bottom, 14)
    }

    /// The corner the deck springs from — also exactly where the "우표 걸기" button
    /// sits, so opening bursts out of the button and folding tucks back under it.
    private func fanPivot(_ size: CGSize) -> CGPoint {
        let inset: CGFloat = 46
        return rightHanded ? CGPoint(x: size.width - inset, y: size.height - inset)
                           : CGPoint(x: inset, y: size.height - inset)
    }

    /// The half-circle nub left peeking from the thumb corner once the full
    /// handle has faded — a quiet reminder that the deck is a tap away.
    private var fanNub: some View {
        ZStack(alignment: .top) {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                .frame(width: 64, height: 64)
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 7)
        }
        .frame(width: 64, height: 34, alignment: .top)   // crop to the top dome (~half)
        .clipped()
        .shadow(color: .black.opacity(0.3), radius: 3, y: -1)
        .contentShape(Rectangle())
        .onTapGesture { flashFanButton() }
        .gesture(DragGesture(minimumDistance: 6).onEnded { _ in flashFanButton() })
    }

    /// Centre for the peeking nub: the 34pt dome rests flush on the bottom edge,
    /// hugging the thumb side (right for right-handers, left for lefties).
    private func nubCenter(_ size: CGSize) -> CGPoint {
        let x = rightHanded ? size.width - 44 : 44
        return CGPoint(x: x, y: size.height - 17)
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
                        // 촤라라락 — cards unfurl one after another on the way out,
                        // and retract in reverse order (last-out → first-in) on fold.
                        .animation(.spring(response: 0.42, dampingFraction: 0.72)
                            .delay(Double(folding ? (2 * r - (ai - baseAI)) : (ai - baseAI)) * 0.05),
                            value: fanSpread)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(fanGesture(pivot: pivot, count: count, all: all))
            .onTapGesture {
                guard fanDragMode != .draw else { return }   // not while a card is out
                foldFan()
            }
            .onAppear { folding = false; fanSpread = 1 }   // trigger the staggered fan-out
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
                    lastFanDetent = Int(fanScroll.rounded())
                    if fanDragMode == .draw { Haptics.select() }   // a card lifts out
                }
                if fanDragMode == .scrub {
                    let delta = angleDiff(curAngle, scrubStartAngle)
                    let dir: CGFloat = -1     // same on-screen arc advances the deck for either hand
                    fanScroll = fanScrubAnchor + dir * delta / fanCardAngle
                    // a ratchet tick each time a new card clicks to the front
                    let detent = Int(fanScroll.rounded())
                    if detent != lastFanDetent { lastFanDetent = detent; Haptics.bounce() }
                } else {
                    drawCardPos = v.location          // the card follows the finger
                }
            }
            .onEnded { v in
                let moved = hypot(v.location.x - drawStartLoc.x, v.location.y - drawStartLoc.y)
                if fanDragMode == .draw && moved > 60 {
                    let idx = ((Int(fanScroll.rounded()) % count) + count) % count
                    // Take the card "in hand". Close the deck at once (no lingering
                    // dim) so the whole wall is clear to deliberate over, then wait
                    // for a tap on the cell where it should be hung.
                    fanDragMode = .none
                    folding = false
                    fanSpread = 0
                    withAnimation(.easeOut(duration: 0.22)) { fanPresented = false }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        pendingStamp = all[idx]
                    }
                    Haptics.select()
                    return
                } else if fanDragMode == .scrub {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        fanScroll = fanScroll.rounded()
                    }
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { fanDragMode = .none }
            }
    }

    private func fanCard(_ stamp: CollectedStamp) -> some View {
        // Just the stamp itself — no card mat or border — so its own perforated
        // edge shows, matching the wall and the carried stamp.
        Image(uiImage: stamp.image).resizable().scaledToFit()
            .frame(width: 70)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 3)
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
        .frame(width: 110, height: 110)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 6).onEnded { _ in openFan() })
        .onTapGesture { openFan() }
    }

    private func openFan() {
        let count = collection.collectedStamps.count
        fanScroll = CGFloat(max(0, count - 1))   // start on the newest card
        fanDragMode = .none
        folding = false
        fanSpread = 0                            // collapsed → onAppear fans it out
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { fanPresented = true }
    }

    /// Fold the deck back into the thumb corner — the unfurl run in reverse — then
    /// dismiss once the last card has tucked away.
    private func foldFan() {
        let count = min(7, collection.collectedStamps.count)   // visible cards
        folding = true
        fanSpread = 0                            // staggered retract (reversed order)
        let collapse = Double(count) * 0.05 + 0.42
        DispatchQueue.main.asyncAfter(deadline: .now() + collapse) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { fanPresented = false }
            folding = false
        }
    }

    @ViewBuilder
    private func wallMenu(for stamp: CollectedStamp) -> some View {
        Button { collection.returnToCollection(stamp.id) } label: {
            Label("우표첩으로 되돌리기", systemImage: "arrow.uturn.backward")
        }
        if collection.exhibitions.count > 1 {
            Menu {
                ForEach(collection.exhibitions.filter { $0.name != exhibition }) { ex in
                    Button(ex.name) { collection.moveExhibitedStamp(stamp.id, to: ex.name) }
                }
            } label: {
                Label("다른 컬렉션으로", systemImage: "arrow.right.square")
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
            Text("이 컬렉션은 비어 있어요")
                .foregroundStyle(ink.opacity(0.8))
            Text(collection.collectedStamps.isEmpty
                 ? "먼저 카메라로 우표를 모아보세요"
                 : "화면을 탭해 ‘우표 걸기’에서 우표를 꺼내 걸어보세요")
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
/// off. Stamps live in a sparse `slots` layout — index = page*perPage + cell,
/// `nil` = an empty (droppable) cell — so a stamp can be hung in any spot and
/// cells may be left blank. Trailing empties are trimmed so the page count
/// stays tight.
struct Exhibition: Identifiable {
    var id: String { name }
    let name: String
    let slots: [String?]
    var background: String = BackgroundStyle.cream.rawValue   // diary-paper style id

    init(name: String, slots: [String?], background: String = BackgroundStyle.cream.rawValue) {
        self.name = name
        self.slots = Exhibition.trimmingTrailingGaps(slots)
        self.background = background
    }
    /// Build from a plain ordered id list (legacy load, append flows): no gaps.
    init(name: String, stampIDs: [String], background: String = BackgroundStyle.cream.rawValue) {
        self.init(name: name, slots: stampIDs.map { Optional($0) }, background: background)
    }

    var backgroundStyle: BackgroundStyle { BackgroundStyle(rawValue: background) ?? .cream }
    /// The hung stamp ids in display order, gaps removed — for counts, peeks,
    /// and the exhibited-id cache.
    var stampIDs: [String] { slots.compactMap { $0 } }

    /// A copy with a new sparse layout, keeping name + background.
    func with(slots newSlots: [String?]) -> Exhibition {
        Exhibition(name: name, slots: newSlots, background: background)
    }
    /// A copy from a plain ordered id list (collapses gaps).
    func with(stampIDs ids: [String]) -> Exhibition {
        Exhibition(name: name, stampIDs: ids, background: background)
    }

    static func trimmingTrailingGaps(_ s: [String?]) -> [String?] {
        var s = s
        while s.last == .some(nil) { s.removeLast() }
        return s
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
    private struct ExhibitionRecord: Codable {
        var name: String
        var stampIDs: [String]? = nil   // legacy (pre-slots) — read only
        var slots: [String?]? = nil     // sparse layout (nil = empty cell)
        var background: String?
    }
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
        exhibitions = file.exhibitions.map { rec in
            let slots: [String?] = rec.slots ?? (rec.stampIDs ?? []).map { Optional($0) }
            return Exhibition(name: rec.name, slots: slots,
                              background: rec.background ?? BackgroundStyle.cream.rawValue)
        }
    }
    private func saveExhibitions() {
        let file = ExhibitionsFile(exhibitions: exhibitions.map {
            ExhibitionRecord(name: $0.name, stampIDs: nil, slots: $0.slots, background: $0.background)
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
            // Null out dead/duplicate ids in place — keeps each stamp's chosen cell.
            let slots: [String?] = ex.slots.map { slot in
                guard let id = slot else { return nil }
                guard live.contains(id), !seen.contains(id) else { changed = true; return nil }
                seen.insert(id); return id
            }
            return ex.with(slots: slots)
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
        // also pull it off any exhibition wall, leaving its cell empty so the
        // surrounding layout doesn't shift
        if exhibitedIDCache.contains(id) {
            exhibitions = exhibitions.map { ex in
                ex.slots.contains(where: { $0 == id })
                    ? ex.with(slots: ex.slots.map { $0 == id ? nil : $0 })
                    : ex
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
    /// Pull an id off whatever wall currently holds it (single-membership),
    /// leaving an empty cell behind so the rest of the layout doesn't shift.
    private func removeFromAnyExhibition(_ id: String) {
        guard exhibitedIDCache.contains(id) else { return }
        exhibitions = exhibitions.map { ex in
            ex.slots.contains(where: { $0 == id })
                ? ex.with(slots: ex.slots.map { $0 == id ? nil : $0 })
                : ex
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
        exhibitions[i] = Exhibition(name: name, slots: exhibitions[i].slots,
                                    background: style.rawValue)
        saveExhibitions()
    }
    func backgroundStyle(of name: String) -> BackgroundStyle {
        exhibitions.first(where: { $0.name == name })?.backgroundStyle ?? .cream
    }

    /// Hang a collected stamp on an exhibition wall — it leaves the collection.
    /// Pass `at:` to land it in a specific cell; if that cell is taken it falls
    /// to the next empty one (or a new cell at the end). With no target it fills
    /// the first empty cell, else appends.
    func placeInExhibition(_ id: String, into name: String, at targetSlot: Int? = nil) {
        guard stamps.contains(where: { $0.id == id }) else { return }
        if exhibitionIndex(name) == nil { exhibitions.append(Exhibition(name: name, slots: [])) }
        removeFromAnyExhibition(id)
        guard let i = exhibitionIndex(name) else { return }
        var slots = exhibitions[i].slots
        if let t = targetSlot {
            if t >= slots.count {
                slots.append(contentsOf: Array(repeating: nil, count: t - slots.count + 1))
            }
            if slots[t] == nil {
                slots[t] = id
            } else if let empty = (t..<slots.count).first(where: { slots[$0] == nil }) {
                slots[empty] = id
            } else {
                slots.append(id)
            }
        } else if let empty = slots.firstIndex(where: { $0 == nil }) {
            slots[empty] = id
        } else {
            slots.append(id)
        }
        exhibitions[i] = exhibitions[i].with(slots: slots)
        saveExhibitions()
    }

    /// Drag a hung stamp into a specific cell. Within the same wall the two
    /// stamps swap (an empty target just receives it); a stamp dragged in from
    /// elsewhere is hung at the target cell.
    func moveStamp(_ id: String, in name: String, toSlot target: Int) {
        guard let i = exhibitionIndex(name) else { return }
        var slots = exhibitions[i].slots
        guard let from = slots.firstIndex(where: { $0 == id }) else {
            placeInExhibition(id, into: name, at: target)
            return
        }
        if target >= slots.count {
            slots.append(contentsOf: Array(repeating: nil, count: target - slots.count + 1))
        }
        slots[from] = slots[target]   // occupant (maybe nil) takes the vacated cell
        slots[target] = id
        exhibitions[i] = exhibitions[i].with(slots: slots)
        saveExhibitions()
    }

    /// The sparse cell layout of an exhibition (nil = empty cell).
    func slots(in name: String) -> [String?] {
        exhibitions.first(where: { $0.name == name })?.slots ?? []
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

    // Cell-level arranging now goes through `moveStamp(_:in:toSlot:)` so stamps
    // can sit in any spot with gaps between them — see above.

    func renameExhibition(_ old: String, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != old, let i = exhibitionIndex(old),
              !exhibitions.contains(where: { $0.name == n }) else { return }
        exhibitions[i] = Exhibition(name: n, slots: exhibitions[i].slots,
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


// MARK: - Zoom slider

/// A clean horizontal zoom slider: a frosted track with snap-stop dots and a
/// draggable knob that reads out the live zoom (e.g. "1.5×"). Sits to the right
/// of the gallery button; haptics tick as it crosses each stop.
struct ZoomSlider: View {
    @ObservedObject var camera: CameraManager
    @GestureState private var dragging = false
    @State private var lastTick: CGFloat = .nan   // last snap stop we buzzed at

    private let height: CGFloat = 52
    private let knob: CGFloat = 40
    private let trackH: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - knob, 1)
            let knobX = pos(camera.zoom) * usable

            ZStack(alignment: .leading) {
                // track
                Capsule()
                    .fill(.ultraThinMaterial)
                    .frame(height: trackH)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))

                // filled portion up to the knob
                Capsule()
                    .fill(Color(hex: 0x4FC3F7))   // sky blue
                    .frame(width: knobX + knob / 2, height: trackH)

                // snap-stop dots (0.5 / 1 / 2 …)
                ForEach(camera.zoomStops, id: \.self) { stop in
                    Circle()
                        .fill(.white.opacity(0.65))
                        .frame(width: 4, height: 4)
                        .offset(x: knob / 2 + pos(stop) * usable - 2)
                }

                // knob with the live zoom readout
                ZStack {
                    Circle().fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    Text(currentLabel)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black)
                }
                .frame(width: knob, height: knob)
                .scaleEffect(dragging ? 1.18 : 1)
                .offset(x: knobX)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, s, _ in s = true }
                    .onChanged { v in
                        let x = min(max(v.location.x - knob / 2, 0), usable)
                        let z = zoom(for: x / usable)
                        camera.setZoom(z)
                        // tick the haptics each time we pass a snap stop
                        if let near = camera.zoomStops.first(where: {
                            abs(pos($0) - pos(z)) < 0.04
                        }) {
                            if near != lastTick { Haptics.tick(); lastTick = near }
                        } else {
                            lastTick = .nan
                        }
                    }
                    .onEnded { v in
                        let x = min(max(v.location.x - knob / 2, 0), usable)
                        let z = zoom(for: x / usable)
                        // snap to a nearby stop for a satisfying little click
                        if let near = camera.zoomStops.first(where: {
                            abs(pos($0) - pos(z)) < 0.06
                        }) {
                            Haptics.bounce()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                camera.setZoom(near)
                            }
                        }
                        lastTick = .nan
                    }
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: dragging)
        }
        .frame(height: height)
    }

    private var currentLabel: String {
        let z = camera.zoom
        if abs(z - z.rounded()) < 0.05 { return "\(Int(z.rounded()))×" }
        return String(format: "%.1f×", z)
    }

    /// 0…1 position of a zoom value along the track (log scale, like Apple's).
    private func pos(_ z: CGFloat) -> CGFloat {
        let lo = log(Double(max(camera.minZoom, 0.01)))
        let hi = log(Double(max(camera.maxZoom, camera.minZoom + 0.01)))
        guard hi > lo else { return 0 }
        let p = (log(Double(max(z, 0.01))) - lo) / (hi - lo)
        return CGFloat(min(1, max(0, p)))
    }

    /// Zoom value for a 0…1 track position (inverse of `pos`).
    private func zoom(for t: CGFloat) -> CGFloat {
        let lo = log(Double(max(camera.minZoom, 0.01)))
        let hi = log(Double(max(camera.maxZoom, camera.minZoom + 0.01)))
        return CGFloat(exp(lo + Double(min(1, max(0, t))) * (hi - lo)))
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
                        Label("새 컬렉션…", systemImage: "plus")
                    }
                } label: {
                    Label("컬렉션에 걸기", systemImage: "photo.artframe")
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

/// Collects each exhibition drop-card's frame (in the album's coordinate space)
/// so a lifted stamp can be hit-tested against the cards while dragging.
struct ExhibitionFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Tiny tactile feedback for picking up / putting down a stamp. `select` is a
/// crisp tap when a stamp opens; `deselect` is a softer one when it closes.
enum Haptics {
    static func select() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    static func deselect() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
    }
    /// A confirming buzz when a stamp lands somewhere (exhibition / another book).
    static func placed() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    /// The dry little tick of a page being turned.
    static func pageTurn() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.6)
    }
    /// The heavy "툭" of a freshly-stamped tile hitting the floor.
    static func plop() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
    /// The lighter "톡" of a secondary bounce.
    static func bounce() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
    }
    /// A crisp little tick as the zoom slider passes a stop.
    static func tick() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// A horizontally-paged container that turns pages with UIKit's real page-curl
/// transition — the leaf lifts and curls over like a book. Pages are built lazily
/// from `page(index)`, so the deck grows/shrinks with the data behind it.
struct PageCurlView<Page: View>: UIViewControllerRepresentable {
    let pageCount: Int
    @Binding var currentPage: Int
    /// Changes whenever the paged content changes, so the visible leaf is only
    /// rebuilt on real data edits — not on every unrelated state tick.
    var contentKey: String = ""
    let page: (Int) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .pageCurl,
                                      navigationOrientation: .horizontal)
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        pvc.isDoubleSided = false
        if pageCount > 0 {
            let start = min(max(0, currentPage), pageCount - 1)
            pvc.setViewControllers([context.coordinator.controller(for: start)],
                                   direction: .forward, animated: false)
            context.coordinator.displayedIndex = start
            context.coordinator.cachedPageCount = pageCount
        }
        context.coordinator.lastContentKey = contentKey
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        guard pageCount > 0 else { return }
        let target = min(max(0, currentPage), pageCount - 1)
        // Rebuild the visible leaf when the data shape changed (a stamp added /
        // removed remakes pages) or the bound page jumped from elsewhere.
        if coord.cachedPageCount != pageCount || coord.displayedIndex != target {
            let dir: UIPageViewController.NavigationDirection =
                target >= coord.displayedIndex ? .forward : .reverse
            coord.cachedPageCount = pageCount
            coord.displayedIndex = target
            coord.lastContentKey = contentKey
            pvc.setViewControllers([coord.controller(for: target)],
                                   direction: dir, animated: false)
            if currentPage != target {
                DispatchQueue.main.async { self.currentPage = target }
            }
        } else if coord.lastContentKey != contentKey,
                  let host = pvc.viewControllers?.first as? IndexedHostingController {
            // Same page, but the stamps behind it changed (e.g. one was just hung).
            // Hosting controllers snapshot their content, so refresh the visible
            // leaf's rootView in place — otherwise the new stamp wouldn't appear
            // until a page turn forced a rebuild.
            coord.lastContentKey = contentKey
            host.rootView = AnyView(page(host.pageIndex))
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlView
        var displayedIndex = 0
        var cachedPageCount = -1
        var lastContentKey = ""

        init(_ parent: PageCurlView) { self.parent = parent }

        func controller(for index: Int) -> UIViewController {
            let host = IndexedHostingController(rootView: AnyView(parent.page(index)))
            host.pageIndex = index
            host.view.backgroundColor = .clear
            return host
        }

        private func index(of vc: UIViewController) -> Int? {
            (vc as? IndexedHostingController)?.pageIndex
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let i = index(of: vc), i > 0 else { return nil }
            return controller(for: i - 1)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let i = index(of: vc), i < parent.pageCount - 1 else { return nil }
            return controller(for: i + 1)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed, let vc = pvc.viewControllers?.first, let i = index(of: vc) else { return }
            displayedIndex = i
            Haptics.pageTurn()
            if parent.currentPage != i {
                DispatchQueue.main.async { self.parent.currentPage = i }
            }
        }
    }
}

final class IndexedHostingController: UIHostingController<AnyView> {
    var pageIndex = 0
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
