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

    // Static-frame overlay placement (tune to your asset): width as a fraction of
    // the stamp frame's displayed width, and a center offset as fractions of it.
    private let staticFrameScale: CGFloat = 0.6
    private let staticFrameOffset = CGSize(width: 0, height: 0)

    // fly-to-collection animation state
    @State private var flying: UIImage?
    @State private var flyStart: CGRect = .zero
    // toss: the fresh cut-out pops out of the window like it's spring-ejected and
    // lands at a random spot on the stamp frame, then fades.
    @State private var tossTrigger = 0
    @State private var landVec: CGSize = .zero    // window centre → landing spot on the frame
    @State private var landSpin: Double = 0       // small resting tilt where it lands
    @State private var binCenter: CGPoint = .zero
    @State private var binBounce = false
    @State private var collectPulse = 0        // fires the "+1"/ring reward at the bin
    @State private var cavityVisible = false    // the black punch-hole revealed as the stamp ejects
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

                // a fixed mount on top of the stamp frame — it stays put while
                // only the inner frame presses, so the punch reads more naturally.
                // Centered over the stamp frame's displayed box; tune size/offset
                // here (the asset has a different aspect, so it can't auto-register).
                if let staticImg = StampFrameLoader.staticImage {
                    let r = stampFrameDisplayRect(in: geo.size)
                    Image(uiImage: staticImg)
                        .resizable()
                        .scaledToFit()
                        .frame(width: r.width * staticFrameScale)
                        .position(x: r.midX + r.width * staticFrameOffset.width,
                                  y: r.midY + r.height * staticFrameOffset.height)
                        .allowsHitTesting(false)
                }

                // the black punch-hole left behind in the window as the stamp is
                // ejected — same stamp shape, revealed beneath the rising piece.
                if cavityVisible {
                    StampShape()
                        .fill(Color.black.opacity(0.82))
                        .frame(width: flyStart.width, height: flyStart.height)
                        .position(x: flyStart.midX, y: flyStart.midY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // the freshly cut stamp pops up out of the slot, then tosses onto
                // the frame and fades.
                if let flying {
                    tossOverlay(flying)
                }

                // "줍줍" — a ring pulse + a "+1" floating up out of the bin each
                // time a stamp is filed, so collecting reads as a little reward.
                if collectPulse > 0 {
                    CollectFX(at: binCenter)
                        .id(collectPulse)
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
        Haptics.ratchet()                     // 드르륵 — the punch biting through
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
                        .scaleEffect(binBounce ? 1.35 : 1)
                        .offset(x: 10, y: -8)
                }
            }
            .frame(width: 56, height: 56)
            .scaleEffect(binBounce ? 1.28 : 1)
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

        // The cut stamp ejects up out of the slot, revealing a black punch-hole
        // beneath, then tosses onto the frame and fades.
        flyStart = win
        flying = stamp
        withAnimation(.easeOut(duration: 0.12)) { cavityVisible = true }

        // pick a landing spot somewhere on the stamp frame (inset so it stays on
        // the body), then aim the toss from the window centre at it.
        let frameRect = stampFrameDisplayRect(in: previewSize)
        let land = frameRect.insetBy(dx: frameRect.width * 0.16, dy: frameRect.height * 0.12)
        let landX = CGFloat.random(in: land.minX...land.maxX)
        let landY = CGFloat.random(in: land.minY...land.maxY)
        landVec = CGSize(width: landX - win.midX, height: landY - win.midY)
        landSpin = Double.random(in: -16 ... 16)
        tossTrigger += 1                                        // fire the toss keyframes

        let landTime = 0.80        // when the ejected piece settles on the frame
        let here = location.current
        let mine = stamp   // identity guard against a faster follow-up shot

        // The moment it lands on the frame: file it into the collection, thump the
        // bin, and give a hearty haptic.
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
            collectPulse += 1                                   // fire the "+1"/ring reward
            withAnimation(.spring(response: 0.22, dampingFraction: 0.42)) { binBounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { binBounce = false }
            }
            // open the parchment editor a beat after it has landed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.74) {
                guard flying === mine else { return }   // a newer shot took over
                editTarget = EditTarget(id: newID)
            }
        }

        // the black hole closes back to the live preview shortly after the eject
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            guard flying === mine else { return }
            withAnimation(.easeOut(duration: 0.35)) { cavityVisible = false }
        }
        // clear the tossed piece once it has rested and faded
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if flying === mine { flying = nil }
        }
    }

    /// The animated state of a tossed stamp tile.
    private struct TossValues {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rotation: Double = 0
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var opacity: Double = 1
    }

    /// The cut-out copy of a fresh stamp: it pops out of the window (a quick scale
    /// overshoot), arcs up, then springs down to land at `landVec` on the frame
    /// with a small tilt — and finally fades after resting there.
    @ViewBuilder
    private func tossOverlay(_ flying: UIImage) -> some View {
        Image(uiImage: flying)
            .resizable().scaledToFit()
            .frame(width: flyStart.width, height: flyStart.height)
            .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
            .keyframeAnimator(initialValue: TossValues(), trigger: tossTrigger) { view, v in
                view.scaleEffect(x: v.scaleX, y: v.scaleY)
                    .rotationEffect(.degrees(v.rotation))
                    .offset(x: v.x, y: v.y)
                    .opacity(v.opacity)
            } keyframes: { _ in popKeyframes() }
            .position(x: flyStart.midX, y: flyStart.midY)
            .allowsHitTesting(false)
    }

    /// Eject up out of the slot (revealing the black hole) → hold → chewy spring
    /// toss onto the frame with a squash-on-impact → rest → fade.
    @KeyframesBuilder<TossValues>
    private func popKeyframes() -> some Keyframes<TossValues> {
        KeyframeTrack(\.y) {
            CubicKeyframe(-flyStart.height * 0.95, duration: 0.22)   // eject up out of the slot
            CubicKeyframe(-flyStart.height * 0.95, duration: 0.10)   // hold — the hole shows
            SpringKeyframe(landVec.height, duration: 0.48, spring: .bouncy(duration: 0.48, extraBounce: 0.3))
        }
        KeyframeTrack(\.x) {
            CubicKeyframe(0, duration: 0.22)
            CubicKeyframe(0, duration: 0.10)
            SpringKeyframe(landVec.width, duration: 0.48, spring: .bouncy(duration: 0.48, extraBounce: 0.3))
        }
        KeyframeTrack(\.scaleX) {
            CubicKeyframe(0.88, duration: 0.05)
            CubicKeyframe(1.16, duration: 0.11)   // pop as it clears the slot
            CubicKeyframe(1.0, duration: 0.16)
            CubicKeyframe(1.0, duration: 0.36)    // travel
            CubicKeyframe(1.18, duration: 0.08)   // squash wide on impact (쫀득)
            CubicKeyframe(0.96, duration: 0.08)
            CubicKeyframe(1.0, duration: 0.12)
        }
        KeyframeTrack(\.scaleY) {
            CubicKeyframe(0.88, duration: 0.05)
            CubicKeyframe(1.16, duration: 0.11)
            CubicKeyframe(1.0, duration: 0.16)
            CubicKeyframe(1.0, duration: 0.36)
            CubicKeyframe(0.84, duration: 0.08)   // squash narrow on impact
            CubicKeyframe(1.04, duration: 0.08)
            CubicKeyframe(1.0, duration: 0.12)
        }
        KeyframeTrack(\.rotation) {
            CubicKeyframe(0, duration: 0.32)
            CubicKeyframe(landSpin, duration: 0.48)
        }
        KeyframeTrack(\.opacity) {
            LinearKeyframe(1, duration: 1.25)                   // rest on the frame
            LinearKeyframe(0, duration: 0.35)                   // then fade away
        }
    }

    /// The on-screen rect the stamp frame image occupies (scaled-to-fit, centred).
    private func stampFrameDisplayRect(in size: CGSize) -> CGRect {
        guard let frame = StampFrameLoader.frame else {
            return CGRect(origin: .zero, size: size)
        }
        let img = frame.image.size
        let s = min(size.width / img.width, size.height / img.height)
        let dispW = img.width * s, dispH = img.height * s
        return CGRect(x: (size.width - dispW) / 2, y: (size.height - dispH) / 2,
                      width: dispW, height: dispH)
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
        .fullScreenCover(item: $selectedStamp, onDismiss: { Haptics.deselect() }) { stamp in
            StampRevealView(collection: collection, stampID: stamp.id)
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
                .fill(LinearGradient(colors: [Color(hex: 0xFBFAF7), Color(hex: 0xECE8DF)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(hex: lit ? 0xE8504E : 0xD6D0C2),
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
            .fill(LinearGradient(colors: [Color(hex: 0xFBFAF7), Color(hex: 0xECE8DF)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(hex: 0xD6D0C2), lineWidth: 1))
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
    @State private var sharePayload: SharePayload?
    @State private var exporting = false

    // Tapping a hung stamp opens its detail as a modal (not a pushed page).
    @State private var selectedStamp: CollectedStamp?

    // Flow A: a hwatu deck fanned from the user's thumb corner. Swipe in an arc
    // around the corner to scroll the deck (wrapping); drag a card onto a cell to
    // hang it (system drag-and-drop); tap elsewhere to fold it back.
    private enum FanDragMode { case none, scrub }
    @AppStorage("stampFanRightHanded") private var rightHanded = true
    @State private var fanPresented = false
    @State private var fanScroll: CGFloat = 0        // fractional index of the front card
    @State private var fanScrubAnchor: CGFloat = 0
    @State private var scrubStartAngle: CGFloat = 0  // finger angle (rad) when an arc-scrub began
    @State private var fanDragMode: FanDragMode = .none
    @State private var fanSpread: CGFloat = 0         // 0 = stacked at corner, 1 = fully fanned
    @State private var folding = false                // collapse runs the stagger in reverse
    @State private var lastFanDetent = 0              // last front-card index, for scrub ticks
    private let maxFan = 3                            // peek count for the hint
    private let fanRadius: CGFloat = 196             // arc radius from the corner
    private let fanCardAngle: CGFloat = 0.27         // radians between cards (~15.5°)

    private var stamps: [CollectedStamp] { collection.stampsInExhibition(exhibition) }
    /// Free (page, x, y) placements driving the wall.
    private var placements: [Placement] { collection.placements(in: exhibition) }
    private func stampByID(_ id: String) -> CollectedStamp? {
        collection.stamps.first { $0.id == id }
    }
    /// Tidy auto-grid vs. free (x, y) placement, per collection.
    private var gridMode: Bool { collection.isGrid(exhibition) }
    private let gridCols = 3
    private let perPageGrid = 12          // 3×4 tidy spread per leaf

    /// Pages that hold at least one stamp (≥1).
    private var filledPages: Int { (placements.map(\.page).max() ?? 0) + 1 }
    /// One blank leaf always trails, so swiping past the last page turns onto a
    /// fresh page to place on.
    private var pageCount: Int {
        gridMode ? max(1, Int(ceil(Double(placements.count) / Double(perPageGrid)))) + 1
                 : filledPages + 1
    }
    @State private var currentPage = 0

    /// While a hung stamp is being dragged: its id and live normalized position.
    @State private var dragging: String?
    @State private var dragPos: CGPoint = .zero

    /// A stamp picked from the deck, waiting to be tapped onto the wall.
    @State private var pendingStamp: CollectedStamp?

    /// A stamp being dragged out of the deck — it follows the finger (in "wall"
    /// space) and lands wherever it's released.
    @State private var carrying: CollectedStamp?
    @State private var carryPos: CGPoint = .zero

    // The "우표 걸기" button hides itself so the finished wall can be enjoyed;
    // a tap on the paper flashes it back for a few seconds.
    @State private var fanVisible = false
    @State private var hideFanWork: DispatchWorkItem?


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
                    .blur(radius: (fanPresented && carrying == nil) ? 2 : 0)
                    .onChange(of: placements.count) { _, _ in
                        if currentPage > pageCount - 1 { currentPage = max(0, pageCount - 1) }
                    }

                // "우표 걸기" handle in the thumb corner. While the wall is being
                // enjoyed it tucks down to a half-circle nub at the bottom edge;
                // tap/drag the nub (or tap the paper) and the full handle rises
                // back, ready to burst into the fanned deck.
                if !fanPresented && pendingStamp == nil && carrying == nil && !collection.collectedStamps.isEmpty {
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
                    // dim hides while a card is being carried, so the wall shows
                    // through and you can see where you're dropping it.
                    Color.black.opacity(carrying == nil ? 0.5 : 0).ignoresSafeArea()
                        .allowsHitTesting(false)
                    fanTray(in: geo.size)
                        .transition(.opacity)
                }

                if let pending = pendingStamp {
                    pickedHud(pending)
                        .transition(.opacity)
                }

                // a stamp dragged out of the deck, riding the finger until released
                if let carrying {
                    Image(uiImage: carrying.image)
                        .resizable().scaledToFit()
                        .frame(width: geo.size.width * 0.26)
                        .rotationEffect(.degrees(-4))
                        .shadow(color: .black.opacity(0.5), radius: 14, y: 10)
                        .position(carryPos)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }

                // moving a hung stamp: the original vanishes and this lifted copy
                // rides the finger, showing exactly where it'll land.
                if let movingID = dragging, let s = stampByID(movingID) {
                    let w = gridMode ? (geo.size.width - 68) / 3 : geo.size.width * 0.26
                    framedArt(s)
                        .frame(width: w)
                        .scaleEffect(1.08)
                        .shadow(color: .black.opacity(0.5), radius: 14, y: 10)
                        .position(dragPos)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "wall")
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
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            collection.setGrid(exhibition, !gridMode)
                        }
                    } label: {
                        Label(gridMode ? "자유 배치로" : "그리드로 정렬",
                              systemImage: gridMode ? "hand.draw" : "square.grid.2x2")
                    }
                    Divider()
                    Button { exportCard() } label: {
                        Label("이미지로 공유", systemImage: "square.and.arrow.up")
                    }
                    .disabled(stamps.isEmpty)
                    Button { exportStickers() } label: {
                        Label("스티커로 만들기", systemImage: "square.on.square")
                    }
                    .disabled(stamps.isEmpty)
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
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
        .fullScreenCover(item: $selectedStamp, onDismiss: { Haptics.deselect() }) { stamp in
            StampRevealView(collection: collection, stampID: stamp.id)
        }
        .overlay {
            if exporting {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView("스티커 시트 만드는 중…")
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
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

    /// Build a print-ready sticker-sheet PDF of this collection (300-DPI
    /// re-composite, white base, bleed, kiss-cut guides) and offer to share/save.
    private func exportStickers() {
        let ids = collection.stampsInExhibition(exhibition).map(\.id)
        guard !ids.isEmpty else { return }
        exporting = true
        DispatchQueue.main.async {
            let url = StickerSheet.makePDF(stampIDs: ids, store: collection, title: exhibition)
            exporting = false
            if let url { sharePayload = SharePayload(items: [url]) }
        }
    }

    /// Render a square SNS card of this collection (background, title, a grid of
    /// stamps, brand) and offer to share it as an image.
    private func exportCard() {
        let imgs = collection.stampsInExhibition(exhibition).map(\.image)
        guard !imgs.isEmpty else { return }
        let card = CollectionCardView(title: exhibition,
                                      count: imgs.count,
                                      style: collection.backgroundStyle(of: exhibition),
                                      stamps: Array(imgs.prefix(12)))
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1   // the card view is already laid out at 1080pt
        guard let image = renderer.uiImage else { return }
        let caption = "내 우표 컬렉션 ‘\(exhibition)’ 📮 #StampCamera"
        sharePayload = SharePayload(items: [image, caption])
    }

    /// The wall: an empty backdrop you can tap to fan out the collection (or drag
    /// a card onto), or — once stamps are hung — a book of leaves you swipe
    /// through with a real page curl.
    @ViewBuilder
    private func wallContent(viewportHeight: CGFloat) -> some View {
        // While a stamp is in hand we always show the leaf (even if empty) so
        // there's a surface to tap it onto.
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
                         contentKey: placements.map { "\($0.id)@\($0.page):\(Int($0.x*100)),\(Int($0.y*100))" }
                                        .joined(separator: ",")
                                     + "|" + collection.backgroundStyle(of: exhibition).rawValue
                                     + "|drag:\(dragging ?? "-")"
                                     + (gridMode ? "|grid" : "")) { pageIndex in
                wallPage(pageIndex)
            }
            .id(exhibition)   // start a fresh book when switching exhibitions
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    /// One leaf of the book: the diary paper with stamps placed freely at their
    /// own (x, y). When a stamp is "in hand", tap anywhere to drop it there; drag
    /// a hung stamp to move it. Opaque so the curl shows paper on both faces.
    private func wallPage(_ pageIndex: Int) -> some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let stampW = W * 0.26
            ZStack {
                DiaryBackground(style: collection.backgroundStyle(of: exhibition))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { if pendingStamp == nil { flashFanButton() } }

                if gridMode {
                    gridLeaf(pageIndex, pageW: W, pageH: H)
                } else {
                    ForEach(placements.filter { $0.page == pageIndex }, id: \.id) { pl in
                        if let stamp = stampByID(pl.id) {
                            freeStamp(stamp, placement: pl, pageW: W, pageH: H, stampW: stampW)
                        }
                    }
                }

                // while a stamp is in hand, a tap anywhere on the leaf drops it (in
                // grid mode the spot is ignored — it just slots in at the end).
                if let pending = pendingStamp {
                    Color.white.opacity(0.001)
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture(coordinateSpace: .named("leaf"))
                                .onEnded { v in
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                        collection.place(pending.id, into: exhibition, page: pageIndex,
                                                         x: v.location.x / W, y: v.location.y / H)
                                        pendingStamp = nil
                                    }
                                    Haptics.placed()
                                }
                        )
                }

                VStack { Spacer(); pageFooter(pageIndex) }
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "leaf")
        }
    }

    /// Tidy auto-grid leaf: the stamps for this page in order, in uniform square
    /// cells. Drag a stamp to reorder it (snaps to the nearest cell on release).
    @ViewBuilder
    private func gridLeaf(_ pageIndex: Int, pageW: CGFloat, pageH: CGFloat) -> some View {
        let pad: CGFloat = 18, spacing: CGFloat = 16
        let cellW = (pageW - 2 * pad - CGFloat(gridCols - 1) * spacing) / CGFloat(gridCols)
        let start = pageIndex * perPageGrid
        let slice = Array(placements.dropFirst(start).prefix(perPageGrid))
        let columns = Array(repeating: GridItem(.fixed(cellW), spacing: spacing), count: gridCols)
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(Array(slice.enumerated()), id: \.element.id) { pair in
                    if let stamp = stampByID(pair.element.id) {
                        gridCell(stamp, globalIndex: start + pair.offset,
                                 cellW: cellW, pad: pad, spacing: spacing, pageW: pageW)
                    }
                }
            }
            .padding(pad)
            Spacer(minLength: 0)
        }
    }

    private func gridCell(_ stamp: CollectedStamp, globalIndex: Int, cellW: CGFloat,
                          pad: CGFloat, spacing: CGFloat, pageW: CGFloat) -> some View {
        let cellInPage = globalIndex % perPageGrid
        let homeCenter = CGPoint(
            x: pad + CGFloat(cellInPage % gridCols) * (cellW + spacing) + cellW / 2,
            y: pad + CGFloat(cellInPage / gridCols) * (cellW + spacing) + cellW / 2)
        return framedArt(stamp)
            .frame(width: cellW, height: cellW)
            .opacity(dragging == stamp.id ? 0 : 1)   // hidden while its preview rides the finger
            .onTapGesture { Haptics.select(); selectedStamp = stamp }
            .gesture(moveGesture(id: stamp.id, home: homeCenter) { p in
                let page = globalIndex / perPageGrid
                let target = page * perPageGrid
                    + nearestGridCell(p, cellW: cellW, pad: pad, spacing: spacing, pageW: pageW)
                collection.reorder(exhibition, moving: stamp.id, to: target)
            })
    }

    /// Index (0…perPageGrid-1) of the grid cell nearest a point on the leaf.
    private func nearestGridCell(_ p: CGPoint, cellW: CGFloat, pad: CGFloat,
                                 spacing: CGFloat, pageW: CGFloat) -> Int {
        let rows = perPageGrid / gridCols
        let step = cellW + spacing
        let c = min(max(Int((((p.x - pad - cellW / 2) / step)).rounded()), 0), gridCols - 1)
        let r = min(max(Int((((p.y - pad - cellW / 2) / step)).rounded()), 0), rows - 1)
        return r * gridCols + c
    }

    /// A freely-placed stamp: tap to open, **press & hold then drag** to move it.
    /// During the drag the original is hidden and a preview (body level) follows
    /// the finger smoothly, showing where it'll land.
    private func freeStamp(_ stamp: CollectedStamp, placement pl: Placement,
                           pageW: CGFloat, pageH: CGFloat, stampW: CGFloat) -> some View {
        let home = CGPoint(x: pl.x * pageW, y: pl.y * pageH)
        return framedArt(stamp)
            .frame(width: stampW)
            .opacity(dragging == pl.id ? 0 : 1)   // hidden once lifted (leaf rebuilds once)
            .position(home)
            .onTapGesture { Haptics.select(); selectedStamp = stamp }
            .gesture(moveGesture(id: stamp.id, home: home) { p in
                collection.place(stamp.id, into: exhibition, page: pl.page,
                                 x: p.x / pageW, y: p.y / pageH)
            })
    }

    /// Press & hold a hung stamp to lift it, then drag to move; release commits
    /// via `place`. `home` is where the lift preview first appears. Shared by free
    /// and grid layouts (each supplies its own `place` for the release point).
    private func moveGesture(id: String, home: CGPoint,
                             place: @escaping (CGPoint) -> Void) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("leaf")))
            .onChanged { value in
                switch value {
                case .first(true):
                    if dragging != id { dragging = id; dragPos = home; Haptics.select() }
                case .second(true, let drag):
                    if dragging != id { dragging = id; dragPos = home; Haptics.select() }
                    if let drag { dragPos = drag.location }
                default:
                    break
                }
            }
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                        place(drag.location)
                    }
                    Haptics.placed()
                }
                dragging = nil
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
                    let stamp = all[idx]
                    // spread out from the corner: angle and radius scale with fanSpread
                    let angle = fanBaseAngle + s * fanCardAngle * fanSpread
                    let radius = fanRadius * (0.3 + 0.7 * fanSpread)
                    let radial = CGPoint(x: pivot.x + radius * cos(angle),
                                         y: pivot.y + radius * sin(angle))
                    fanCard(stamp)
                        .scaleEffect(isFront ? 1.12 : 1)
                        .opacity(carrying != nil ? 0 : Double(0.4 + 0.6 * fanSpread))
                        .rotationEffect(.radians(Double(angle) + .pi / 2))
                        .position(radial)
                        .zIndex(isFront ? 100 : Double(r) - abs(Double(s)))
                        // drag a card out to carry it; release on the wall to drop
                        // it there. (a plain tap also picks it up — see onTapGesture)
                        .gesture(cardDrag(stamp, in: size))
                        .onTapGesture { selectFromFan(stamp) }
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
            .onTapGesture { foldFan() }
            .onAppear { folding = false; fanSpread = 1 }   // trigger the staggered fan-out
            .onDisappear { fanSpread = 0 }
        }
    }

    /// Swipe around the corner to scroll the deck; picking a card is a separate
    /// drag-and-drop (see `.onDrag` on each card) so this gesture only scrubs.
    private func fanGesture(pivot: CGPoint, count: Int, all: [CollectedStamp]) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                let curAngle = atan2(v.location.y - pivot.y, v.location.x - pivot.x)
                if fanDragMode != .scrub {
                    fanDragMode = .scrub
                    scrubStartAngle = atan2(v.startLocation.y - pivot.y, v.startLocation.x - pivot.x)
                    fanScrubAnchor = fanScroll
                    lastFanDetent = Int(fanScroll.rounded())
                }
                let delta = angleDiff(curAngle, scrubStartAngle)
                let dir: CGFloat = -1     // same on-screen arc advances the deck for either hand
                fanScroll = fanScrubAnchor + dir * delta / fanCardAngle
                // a ratchet tick each time a new card clicks to the front
                let detent = Int(fanScroll.rounded())
                if detent != lastFanDetent { lastFanDetent = detent; Haptics.bounce() }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                    fanScroll = fanScroll.rounded()
                }
                fanDragMode = .none
            }
    }

    /// Pick a card out of the deck: it becomes the "in hand" stamp (stays on
    /// screen) and the fan folds away, leaving the wall clear to tap a spot.
    private func selectFromFan(_ stamp: CollectedStamp) {
        Haptics.select()
        fanDragMode = .none
        folding = false
        fanSpread = 0
        withAnimation(.easeOut(duration: 0.22)) {
            fanPresented = false
            pendingStamp = stamp
        }
    }

    /// Drag a card out of the deck and carry it to a spot on the wall. The deck
    /// stays mounted (just hidden) so the gesture isn't cancelled mid-drag; the
    /// carried stamp follows the finger and lands where it's released.
    private func cardDrag(_ stamp: CollectedStamp, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named("wall"))
            .onChanged { v in
                if carrying == nil {
                    Haptics.select()
                    fanDragMode = .none
                    withAnimation(.easeOut(duration: 0.15)) { carrying = stamp }
                }
                carryPos = v.location
            }
            .onEnded { v in
                let p = v.location
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    collection.place(stamp.id, into: exhibition, page: currentPage,
                                     x: p.x / size.width, y: p.y / size.height)
                    carrying = nil
                    fanPresented = false
                    fanSpread = 0
                }
                Haptics.placed()
            }
    }

    /// The "in hand" HUD while a picked stamp waits to be placed: a top hint with
    /// a cancel ✕, and the chosen stamp floating at the bottom. The stamp ignores
    /// touches so a tap falls through to the wall's placement catcher.
    private func pickedHud(_ stamp: CollectedStamp) -> some View {
        ZStack {
            HStack(spacing: 10) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("원하는 자리를 탭해 붙이기")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer(minLength: 8)
                Button {
                    Haptics.deselect()
                    withAnimation(.easeOut(duration: 0.2)) { pendingStamp = nil }
                } label: {
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
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)

            Image(uiImage: stamp.image)
                .resizable().scaledToFit()
                .frame(width: 104)
                .rotationEffect(.degrees(-4))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 30)
                .allowsHitTesting(false)
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

/// Where a hung stamp sits: a page in the book and a free (x, y) position,
/// normalized 0…1 within that page. Later placements draw on top.
struct Placement: Codable, Hashable {
    var id: String      // stamp id
    var page: Int
    var x: Double
    var y: Double
}

/// A curated wall of stamps pulled out of the collection and hung up to show
/// off. Stamps are placed *freely* — each has a page and an (x, y) position, so
/// you can drop a stamp anywhere on a leaf rather than into a grid.
struct Exhibition: Identifiable {
    var id: String { name }
    let name: String
    let placements: [Placement]
    var background: String = BackgroundStyle.cream.rawValue   // diary-paper style id
    /// `true` lays the stamps out in a tidy auto-grid (in order) instead of the
    /// free (x, y) positions — for people who like things neat.
    var grid: Bool = false

    init(name: String, placements: [Placement],
         background: String = BackgroundStyle.cream.rawValue, grid: Bool = false) {
        self.name = name
        self.placements = placements
        self.background = background
        self.grid = grid
    }

    var backgroundStyle: BackgroundStyle { BackgroundStyle(rawValue: background) ?? .cream }
    /// Hung stamp ids in placement (draw) order — for counts, peeks, the cache.
    var stampIDs: [String] { placements.map(\.id) }
    /// Highest page that holds a stamp (0 when empty).
    var maxPage: Int { placements.map(\.page).max() ?? 0 }

    func with(placements p: [Placement]) -> Exhibition {
        Exhibition(name: name, placements: p, background: background, grid: grid)
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
        var stampIDs: [String]? = nil    // legacy (pre-slots) — read only
        var slots: [String?]? = nil      // legacy grid layout — read only, migrated
        var placements: [Placement]? = nil   // free (page, x, y) layout
        var background: String?
        var grid: Bool? = nil
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

    /// The saved crop (0…1 rect in the orientation-normalized original) and the
    /// mirror flag — enough to re-render a stamp at any resolution.
    func cropInfo(for id: String) -> (rect: CGRect, mirrored: Bool)? {
        guard let data = try? Data(contentsOf: stampMetaURL(for: id)),
              let meta = try? JSONDecoder().decode(StampMeta.self, from: data),
              let x = meta.cropX, let y = meta.cropY, let w = meta.cropW, let h = meta.cropH
        else { return nil }
        return (CGRect(x: x, y: y, width: w, height: h), meta.mirrored ?? false)
    }

    /// A print-resolution copy of a stamp, re-cropped from the full original
    /// photo and clipped to the perforation shape (`longSidePx` on the long
    /// edge). Falls back to the stored screen-size PNG when no original was kept.
    func printStamp(for id: String, longSidePx: CGFloat) -> UIImage? {
        guard let original = originalImage(for: id),
              let info = cropInfo(for: id),
              let cg = original.normalizedUp().cgImage else {
            return stamps.first { $0.id == id }?.image
        }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let src = CGRect(x: info.rect.minX * iw, y: info.rect.minY * ih,
                         width: info.rect.width * iw, height: info.rect.height * ih).integral
        guard src.width > 1, src.height > 1, let cropped = cg.cropping(to: src) else {
            return stamps.first { $0.id == id }?.image
        }
        let aspect = src.width / src.height
        let outSize = aspect >= 1
            ? CGSize(width: longSidePx, height: (longSidePx / aspect).rounded())
            : CGSize(width: (longSidePx * aspect).rounded(), height: longSidePx)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: outSize, format: fmt).image { ctx in
            let c = ctx.cgContext
            let r = CGRect(origin: .zero, size: outSize)
            c.addPath(stampBezierPath(in: r).cgPath)
            c.clip()
            if info.mirrored {
                c.translateBy(x: outSize.width, y: 0)
                c.scaleBy(x: -1, y: 1)
            }
            UIImage(cgImage: cropped).draw(in: r)
        }
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
            let placements: [Placement]
            if let p = rec.placements {
                placements = p
            } else {
                // migrate legacy grid (slots) / ordered ids → free positions
                let slots = rec.slots ?? (rec.stampIDs ?? []).map { Optional($0) }
                placements = Self.placementsFromSlots(slots)
            }
            return Exhibition(name: rec.name, placements: placements,
                              background: rec.background ?? BackgroundStyle.cream.rawValue,
                              grid: rec.grid ?? false)
        }
    }
    private func saveExhibitions() {
        let file = ExhibitionsFile(exhibitions: exhibitions.map {
            ExhibitionRecord(name: $0.name, stampIDs: nil, slots: nil,
                             placements: $0.placements, background: $0.background, grid: $0.grid)
        })
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: exhibitionsURL, options: .atomic)
        }
    }

    /// Convert a legacy 3×4 grid (slot index = page*12 + cell) to free positions
    /// at the cell centres, so existing collections keep their arrangement.
    private static func placementsFromSlots(_ slots: [String?]) -> [Placement] {
        let cols = 3, per = 12, rows = 4
        var out: [Placement] = []
        for (i, s) in slots.enumerated() {
            guard let id = s else { continue }
            let cell = i % per
            out.append(Placement(id: id, page: i / per,
                                 x: (Double(cell % cols) + 0.5) / Double(cols),
                                 y: (Double(cell / cols) + 0.5) / Double(rows)))
        }
        return out
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
            // Drop placements whose stamp is gone or already shown elsewhere.
            let pls = ex.placements.filter { pl in
                guard live.contains(pl.id), !seen.contains(pl.id) else { changed = true; return false }
                seen.insert(pl.id); return true
            }
            return ex.with(placements: pls)
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
            exhibitions = exhibitions.map { ex in
                ex.placements.contains(where: { $0.id == id })
                    ? ex.with(placements: ex.placements.filter { $0.id != id })
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
    /// Pull an id off whatever wall currently holds it (single-membership).
    private func removeFromAnyExhibition(_ id: String) {
        guard exhibitedIDCache.contains(id) else { return }
        exhibitions = exhibitions.map { ex in
            ex.placements.contains(where: { $0.id == id })
                ? ex.with(placements: ex.placements.filter { $0.id != id })
                : ex
        }
    }

    @discardableResult
    func createExhibition(_ name: String, background: BackgroundStyle = .cream) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !exhibitions.contains(where: { $0.name == n }) else {
            return exhibitions.contains(where: { $0.name == n }) ? n : nil
        }
        exhibitions.append(Exhibition(name: n, placements: [], background: background.rawValue))
        saveExhibitions()
        return n
    }

    func setExhibitionBackground(_ name: String, to style: BackgroundStyle) {
        guard let i = exhibitionIndex(name) else { return }
        exhibitions[i] = Exhibition(name: name, placements: exhibitions[i].placements,
                                    background: style.rawValue, grid: exhibitions[i].grid)
        saveExhibitions()
    }

    /// Whether a wall is in tidy grid mode.
    func isGrid(_ name: String) -> Bool {
        exhibitions.first(where: { $0.name == name })?.grid ?? false
    }
    /// Flip a wall between free placement and tidy auto-grid.
    func setGrid(_ name: String, _ on: Bool) {
        guard let i = exhibitionIndex(name) else { return }
        exhibitions[i] = Exhibition(name: name, placements: exhibitions[i].placements,
                                    background: exhibitions[i].background, grid: on)
        saveExhibitions()
    }
    /// Reorder a stamp within its wall (grid mode) to a target index.
    func reorder(_ name: String, moving id: String, to index: Int) {
        guard let i = exhibitionIndex(name) else { return }
        var pls = exhibitions[i].placements
        guard let from = pls.firstIndex(where: { $0.id == id }) else { return }
        let item = pls.remove(at: from)
        let dest = max(0, min(index, pls.count))
        pls.insert(item, at: dest)
        exhibitions[i] = exhibitions[i].with(placements: pls)
        saveExhibitions()
    }
    func backgroundStyle(of name: String) -> BackgroundStyle {
        exhibitions.first(where: { $0.name == name })?.backgroundStyle ?? .cream
    }

    /// Hang a stamp on a wall at a free position (page + normalized x/y). If the
    /// id is already on this wall it just moves — and comes to the front, since
    /// later placements draw on top.
    func place(_ id: String, into name: String, page: Int, x: Double, y: Double) {
        guard stamps.contains(where: { $0.id == id }) else { return }
        if exhibitionIndex(name) == nil { exhibitions.append(Exhibition(name: name, placements: [])) }
        removeFromAnyExhibition(id)
        guard let i = exhibitionIndex(name) else { return }
        var pls = exhibitions[i].placements
        pls.append(Placement(id: id, page: max(0, page),
                             x: min(max(x, 0.06), 0.94),
                             y: min(max(y, 0.06), 0.94)))
        exhibitions[i] = exhibitions[i].with(placements: pls)
        saveExhibitions()
    }

    /// Hang a stamp without a chosen spot (menu / detail / album drop): drop it on
    /// page 0 at a gently cascading position so they don't all stack exactly.
    func placeInExhibition(_ id: String, into name: String) {
        let n = exhibitions.first { $0.name == name }?.placements.count ?? 0
        let step = Double(n % 6)
        place(id, into: name, page: 0, x: 0.30 + step * 0.07, y: 0.28 + step * 0.07)
    }

    /// The free placements of an exhibition, in draw order.
    func placements(in name: String) -> [Placement] {
        exhibitions.first(where: { $0.name == name })?.placements ?? []
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

    func renameExhibition(_ old: String, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != old, let i = exhibitionIndex(old),
              !exhibitions.contains(where: { $0.name == n }) else { return }
        exhibitions[i] = Exhibition(name: n, placements: exhibitions[i].placements,
                                    background: exhibitions[i].background, grid: exhibitions[i].grid)
        saveExhibitions()
    }

    /// Removes the wall; its stamps return to their home albums (not deleted).
    func deleteExhibition(_ name: String) {
        exhibitions.removeAll { $0.name == name }
        saveExhibitions()
    }
}

// MARK: - Sticker sheet export (print-ready PDF)

/// Wraps share items (a PDF URL, an image + caption, …) to drive `.sheet(item:)`.
struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// Renders a collection's stamps into a print-ready sticker sheet PDF that
/// answers the real production hurdles:
///  • Resolution — each stamp is re-composited at 300 DPI from its saved
///    original photo (not the small screen PNG).
///  • Transparency — the perforated stamp sits on an opaque white rounded
///    sticker base, so the clear holes print clean (a built-in white underbase)
///    instead of printing onto bare vinyl.
///  • Die-cut — the fine perforation teeth are printed as art; the actual cut is
///    a simple rounded-rect kiss-cut, drawn as a magenta `CutContour`-style guide
///    a cutter/vendor can follow.
///  • Bleed — the white base extends past the cut line so trim misregistration
///    never shows a white sliver.
///  • Layout — a uniform grid (size-normalised) on US-Letter with even gutters
///    and corner registration/crop marks; paginates if there are more than fit.
///  • Color — embedded sRGB; consumer sticker printers convert to CMYK on their
///    side (true CMYK separation is a vendor/profile step).
enum StickerSheet {
    struct Config {
        var dpi: CGFloat = 300
        var pageInches = CGSize(width: 8.5, height: 11)   // US Letter
        var marginInches: CGFloat = 0.5
        var stickerInches: CGFloat = 2.0                  // kiss-cut square
        var bleedInches: CGFloat = 0.06                   // ~1.5 mm
        var artInsetInches: CGFloat = 0.14                // stamp inset from the cut
        var columns = 3
        var rows = 4
    }

    static func makePDF(stampIDs: [String], store: CollectionStore,
                        title: String, config: Config = .init()) -> URL? {
        let ids = stampIDs.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return nil }

        func pt(_ inches: CGFloat) -> CGFloat { inches * 72 }   // PDF user space = 72/in
        let page = CGRect(x: 0, y: 0, width: pt(config.pageInches.width), height: pt(config.pageInches.height))
        let margin = pt(config.marginInches)
        let sticker = pt(config.stickerInches)
        let bleed = pt(config.bleedInches)
        let inset = pt(config.artInsetInches)
        let radius = sticker * 0.16
        let cols = max(1, config.columns), rows = max(1, config.rows)
        let perPage = cols * rows

        let gridW = page.width - 2 * margin
        let gridH = page.height - 2 * margin
        let gutX = cols > 1 ? (gridW - CGFloat(cols) * sticker) / CGFloat(cols - 1) : 0
        let gutY = rows > 1 ? (gridH - CGFloat(rows) * sticker) / CGFloat(rows - 1) : 0
        let artPx = config.stickerInches * config.dpi      // target px for re-composite

        // Pre-render every stamp at print resolution (off-screen rasters).
        let arts: [UIImage?] = ids.map { store.printStamp(for: $0, longSidePx: artPx) }

        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StampStickers-\(safeTitle).pdf")
        let pages = (ids.count + perPage - 1) / perPage
        let renderer = UIGraphicsPDFRenderer(bounds: page)

        do {
            try renderer.writePDF(to: url) { ctx in
                for p in 0..<pages {
                    ctx.beginPage()
                    let cg = ctx.cgContext
                    drawCropMarks(cg, page: page, margin: margin)
                    for j in 0..<perPage {
                        let index = p * perPage + j
                        guard index < ids.count else { break }
                        let col = j % cols, row = j / cols
                        let cell = CGRect(x: margin + CGFloat(col) * (sticker + gutX),
                                          y: margin + CGFloat(row) * (sticker + gutY),
                                          width: sticker, height: sticker)
                        drawSticker(cg, cell: cell, radius: radius, bleed: bleed,
                                    inset: inset, art: arts[index])
                    }
                }
            }
        } catch { return nil }
        return url
    }

    /// One sticker: white bleed base → stamp art (aspect-fit) → kiss-cut guide.
    private static func drawSticker(_ cg: CGContext, cell: CGRect, radius: CGFloat,
                                    bleed: CGFloat, inset: CGFloat, art: UIImage?) {
        // White base, extended by the bleed and rounded to the cut shape.
        let base = cell.insetBy(dx: -bleed, dy: -bleed)
        cg.setFillColor(UIColor.white.cgColor)
        UIBezierPath(roundedRect: base, cornerRadius: radius + bleed).fill()

        // The stamp art, fit inside the cut with a small inset.
        if let art {
            let box = cell.insetBy(dx: inset, dy: inset)
            let s = min(box.width / art.size.width, box.height / art.size.height)
            let w = art.size.width * s, h = art.size.height * s
            art.draw(in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
        }

        // Kiss-cut guide (magenta dashed = CutContour convention).
        cg.saveGState()
        cg.setStrokeColor(UIColor.magenta.cgColor)
        cg.setLineWidth(0.75)
        cg.setLineDash(phase: 0, lengths: [4, 3])
        cg.addPath(UIBezierPath(roundedRect: cell, cornerRadius: radius).cgPath)
        cg.strokePath()
        cg.restoreGState()
    }

    /// Corner registration/crop marks at the trim box.
    private static func drawCropMarks(_ cg: CGContext, page: CGRect, margin: CGFloat) {
        cg.saveGState()
        cg.setStrokeColor(UIColor.black.cgColor)
        cg.setLineWidth(0.5)
        let len: CGFloat = 14, gap: CGFloat = 6
        let xs = [margin, page.width - margin]
        let ys = [margin, page.height - margin]
        for x in xs {
            for y in ys {
                let sx: CGFloat = x == margin ? -1 : 1
                let sy: CGFloat = y == margin ? -1 : 1
                cg.move(to: CGPoint(x: x + sx * gap, y: y));   cg.addLine(to: CGPoint(x: x + sx * (gap + len), y: y))
                cg.move(to: CGPoint(x: x, y: y + sy * gap));   cg.addLine(to: CGPoint(x: x, y: y + sy * (gap + len)))
            }
        }
        cg.strokePath()
        cg.restoreGState()
    }
}

/// A square SNS share card: the collection's diary paper, its title and count,
/// a 3×4 grid of stamps, and the app mark. Rasterised with `ImageRenderer`.
struct CollectionCardView: View {
    let title: String
    let count: Int
    let style: BackgroundStyle
    let stamps: [UIImage]

    private var dark: Bool { style.isDark }
    private var ink: Color { dark ? .white : Color(hex: 0x4A3D28) }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 22), count: 3)

    var body: some View {
        ZStack {
            DiaryBackground(style: style)
            VStack(spacing: 26) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 60, weight: .heavy, design: .rounded))
                        .foregroundStyle(ink)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Spacer(minLength: 16)
                    Text("\(count)장")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(ink.opacity(0.8))
                }

                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(0..<12, id: \.self) { i in
                        ZStack {
                            if i < stamps.count {
                                Image(uiImage: stamps[i])
                                    .resizable().scaledToFit()
                                    .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
                            } else {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(ink.opacity(0.14),
                                                  style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Image(systemName: "mail.stack.fill")
                        .font(.system(size: 30))
                    Text("StampCamera")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(ink.opacity(0.65))
            }
            .padding(60)
        }
        .frame(width: 1080, height: 1080)
    }
}

/// Bridges a `UIActivityViewController` so a generated file can be shared/saved.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
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

/// A one-shot "collected!" flourish over the bin: a ring that expands and fades
/// while a "+1" floats up. Re-created (via `.id`) on every catch so it replays.
private struct CollectFX: View {
    let at: CGPoint
    @State private var go = false
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: 42, height: 42)
                .scaleEffect(go ? 2.3 : 0.3)
                .opacity(go ? 0 : 0.9)
            Text("+1")
                .font(.system(size: 19, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .scaleEffect(go ? 1.15 : 0.5)
                .opacity(go ? 0 : 1)
                .offset(y: go ? -52 : -4)
        }
        .position(at)
        .onAppear { withAnimation(.easeOut(duration: 0.7)) { go = true } }
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
            .fill(LinearGradient(colors: [Color(hex: 0xFBFAF7), Color(hex: 0xECE8DF)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(RadialGradient(colors: [.clear, Color(hex: 0x9A9484).opacity(0.10)],
                                         center: .center, startRadius: 8, endRadius: 320))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(hex: 0xD6D0C2), lineWidth: 1)
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

/// Tapping a stamp opens this: the full photo it was cut from, with the stamp
/// piece flying back into its exact spot — the puzzle clicking into place.
/// Falls back to just showing the stamp if no original photo was kept.
struct StampRevealView: View {
    @ObservedObject var collection: CollectionStore
    let stampID: String
    @Environment(\.dismiss) private var dismiss

    @State private var showPhoto = false
    @State private var settled = false
    @State private var showControls = false
    @State private var editing = false

    private var stamp: CollectedStamp? { collection.stamps.first { $0.id == stampID } }

    var body: some View {
        GeometryReader { geo in
            let original = collection.originalImage(for: stampID)?.normalizedUp()
            let info = collection.cropInfo(for: stampID)
            ZStack {
                Color.black.ignoresSafeArea()

                if let stamp {
                    if let original, let info {
                        puzzle(stamp: stamp, original: original, info: info, geo: geo.size)
                    } else {
                        // no original kept → just present the stamp, centered
                        Image(uiImage: stamp.image)
                            .resizable().scaledToFit()
                            .frame(width: min(geo.size.width, geo.size.height) * 0.7)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }

                if showControls { controls }
            }
            .contentShape(Rectangle())
            .onTapGesture { if settled { dismiss() } }
            .onAppear { start(hasPuzzle: original != nil && info != nil) }
            .sheet(isPresented: $editing) {
                NavigationStack { StampDetailView(collection: collection, stampID: stampID) }
            }
        }
    }

    @ViewBuilder
    private func puzzle(stamp: CollectedStamp, original: UIImage,
                        info: (rect: CGRect, mirrored: Bool), geo: CGSize) -> some View {
        let imgW = original.size.width, imgH = original.size.height
        let fit = min(geo.width / imgW, geo.height / imgH)
        let dispW = imgW * fit, dispH = imgH * fit
        let dispX = (geo.width - dispW) / 2, dispY = (geo.height - dispH) / 2
        // when the stamp was mirrored (front camera) the piece is flipped, so
        // mirror the whole photo to match and flip the slot's x.
        let cropX = info.mirrored ? (1 - info.rect.maxX) : info.rect.minX
        let hole = CGRect(x: dispX + cropX * dispW,
                          y: dispY + info.rect.minY * dispH,
                          width: info.rect.width * dispW,
                          height: info.rect.height * dispH)
        let bigW = min(geo.width, geo.height) * 0.62
        let bigH = bigW * (stamp.image.size.height / max(1, stamp.image.size.width))

        // the full scene
        Image(uiImage: original)
            .resizable().scaledToFit()
            .scaleEffect(x: info.mirrored ? -1 : 1)
            .frame(width: dispW, height: dispH)
            .position(x: geo.width / 2, y: geo.height / 2)
            .opacity(showPhoto ? 1 : 0)

        // the empty slot, darkened until the piece lands
        Rectangle()
            .fill(Color.black.opacity(showPhoto && !settled ? 0.5 : 0))
            .frame(width: hole.width, height: hole.height)
            .position(x: hole.midX, y: hole.midY)
            .allowsHitTesting(false)

        // the stamp piece flying into its slot
        Image(uiImage: stamp.image)
            .resizable().scaledToFit()
            .frame(width: settled ? hole.width : bigW,
                   height: settled ? hole.height : bigH)
            .rotationEffect(.degrees(settled ? 0 : -7))
            .shadow(color: .black.opacity(settled ? 0 : 0.6), radius: settled ? 0 : 18, y: 10)
            .position(settled ? CGPoint(x: hole.midX, y: hole.midY)
                              : CGPoint(x: geo.width / 2, y: geo.height / 2))
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Button { editing = true } label: {
                    Label("편집", systemImage: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            Spacer()
        }
        .transition(.opacity)
    }

    private func start(hasPuzzle: Bool) {
        guard hasPuzzle else {
            settled = true
            withAnimation(.easeIn(duration: 0.3)) { showControls = true }
            return
        }
        withAnimation(.easeOut(duration: 0.35)) { showPhoto = true }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.72).delay(0.35)) { settled = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { Haptics.placed() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeIn(duration: 0.3)) { showControls = true }
        }
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
    @State private var showFullImage = false
    @FocusState private var focused: Bool

    private var stamp: CollectedStamp? { collection.stamps.first { $0.id == stampID } }
    private var albumLabel: String { stamp?.album ?? CollectionStore.defaultAlbum }

    var body: some View {
        ZStack {
            Color(hex: 0x241F18).ignoresSafeArea()
            // Scrolls when the keyboard is up or the note grows past the screen.
            ScrollView {
              VStack(spacing: 16) {
                if let stamp {
                    Image(uiImage: stamp.image)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 190)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
                        // press & hold to see the whole photo this stamp was cut from
                        .onLongPressGesture(minimumDuration: 0.3) {
                            guard collection.originalImage(for: stampID) != nil else { return }
                            Haptics.select()
                            showFullImage = true
                        }
                    if collection.originalImage(for: stampID) != nil {
                        Text("꾹 눌러 전체 사진 보기")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(hex: 0x8C7A52))
                    }

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
              .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
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
                    if collection.isExhibited(stampID) {
                        Button { collection.returnToCollection(stampID) } label: {
                            Label("컬렉션에서 내리기", systemImage: "arrow.uturn.backward")
                        }
                        Divider()
                    }
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
        .fullScreenCover(isPresented: $showFullImage) {
            if let original = collection.originalImage(for: stampID) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: original)
                        .resizable().scaledToFit()
                        .ignoresSafeArea()
                    VStack {
                        HStack {
                            Button { showFullImage = false } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 18).padding(.top, 8)
                        Spacer()
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showFullImage = false }
            }
        }
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
    /// A "드르륵" ratchet — a quick burst of rigid taps, for the punch press.
    static func ratchet() {
        let gen = UIImpactFeedbackGenerator(style: .rigid)
        gen.prepare()
        let steps = 10
        for i in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.026) {
                gen.impactOccurred(intensity: 0.55 + 0.05 * Double(i % 3))
            }
        }
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
    /// A fixed mount drawn on top of the (pressable) stamp frame — it never
    /// scales or moves, so only the inner frame presses. Optional asset.
    static let staticImage: UIImage? = UIImage(named: "staticFrame")

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
