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
import CoreImage
import CoreLocation
import ImageIO
import PhotosUI
import LeeoKit
import Vision

// MARK: - 다이내믹 타입

/// 글자 크기 설정을 따르는 고정 크기 글꼴. 디자인 크기(`size`)에서 시작해
/// 사용자가 키운 만큼 커지되, 카메라 위 칩·카드가 깨지지 않게 두 배에서 멈춘다.
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    private let size: CGFloat
    private let weight: Font.Weight?
    private let design: Font.Design?

    init(size: CGFloat, weight: Font.Weight?, design: Font.Design?) {
        self.size = size
        self.weight = weight
        self.design = design
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: min(scaled, size * 2), weight: weight, design: design))
    }
}

extension View {
    func scaledFont(_ size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var collection = CollectionStore()
    @StateObject private var location = LocationManager()
    @EnvironmentObject private var router: CameraLaunchRouter
    @ObservedObject private var plans = PunchingPlans.shared
    /// 잠긴 것을 누른 자리 — 그 기능의 페이월이 뜬다.
    @State private var paywallFeature: PlanFeature?
    /// 구독 중인 사람에게 6개월째 · 갱신 7일 전에 한 번 (→ LeeoGraduation).
    @State private var showGraduation = false

    @State private var previewSize: CGSize = .zero
    @State private var showCollection = false
    @State private var showSupport = false

    @State private var binCenter: CGPoint = .zero
    @State private var binBounce = false
    @State private var collectPulse = 0        // fires the "+1"/ring reward at the bin
    @State private var pressed = false
    // pinch-to-zoom: a second finger cancels the shutter press and scrubs the
    // zoom continuously; a small ×HUD shows while pinching
    @State private var pinching = false
    @State private var pinchStartZoom: CGFloat?
    @State private var flipAngle: Double = 0    // selfie/back flip spin
    // 새로 뜯는 스티커의 모양 (설정 ▸ 뜯기) — 뜯은 뒤에도 상세에서 변경 가능.
    // 기본은 오려낸 + 움직임; 한 번도 바꾸지 않은 사람은 저장값이 없어 이 기본을 따른다
    @AppStorage("captureStyle") private var captureStyleRaw = StampStyle.liveSticker.rawValue
    private var captureStyle: StampStyle { StampStyle(rawValue: captureStyleRaw) ?? .liveSticker }
    @State private var liveCaptureStyle: StampStyle = .liveSticker   // snapshot at shutter
    // 모아둔 라이브 우표를 화면 곳곳에서 움직이게 재생할지 (LiveArt가 읽는 값)
    @AppStorage("liveAutoPlay") private var liveAutoPlay = true

    // newly-made stamp pending a caption on the parchment editor
    @State private var editTarget: EditTarget?
    @State private var stampAfterCollection: String?
    @State private var receivedPack: StickerImportResult?
    @State private var receiveError: String?

    // 방금 찍은 사진 — 여기서 스티커로 만들 것을 고른다
    @State private var shot: PhotoShot?
    // 함께 찍힌 움직임, 손떨림을 잡은 것
    @State private var steadyMotion: [UIImage]?
    // freshly-cut stamp celebrated in the full-screen holo reveal
    @State private var revealID: String?

    // Exactly one stamp/sticker per shutter:
    //  • captureInFlight — locks the shutter from press until the stamp is filed
    //    (covers the window where the full-res photo is still developing).
    //  • awaitingImage — gates handleCapture to the FIRST capturedImage per
    //    shutter, so a duplicate publish (error-fallback race) can't double-file.
    //  • captureToken — lets the watchdog timeout clear a stuck lock without
    //    clobbering a newer capture.
    @State private var captureInFlight = false
    @State private var awaitingImage = false
    @State private var captureToken = 0
    // Raised when a "moving" look came out with no playable clip.
    @State private var captureIssue: CaptureIssue?
    // A passing one-liner over the camera (e.g. the sticker fell back to the
    // stamp shape) — informs without stopping the next shot.
    @State private var captureNote: String?
    @State private var captureNoteToken = 0

    /// A mismatch between the requested style and what could actually be made.
    private struct CaptureIssue: Identifiable {
        enum Kind { case motion }
        let id: String      // the stamp's id
        let kind: Kind
        var title: String {
            switch kind {
            case .motion: return String(localized: "움직임을 담지 못했어요")
            }
        }
        var message: String {
            switch kind {
            case .motion: return String(localized: "움직이는 장면을 충분히 담지 못했어요. 다시 찍어볼까요?")
            }
        }
    }

    // active-album switching from the camera screen
    @State private var showNewAlbum = false
    @State private var newAlbumName = ""

    // tap-to-focus reticle: where the last tap landed (preview coords) + an id
    // that re-fires the snap/pulse animation on each new tap
    @State private var focusPoint: CGPoint?
    @State private var focusTapID = 0

    var body: some View {
        // 아이폰 듀오를 펴면 아래(가로면 왼쪽)에 카메라, 위(오른쪽)에 지금 담기는 수집함이 선다.
        // 뜯은 스티커가 접힌 선 너머 수집함에 바로 꽂힌다. 접혀 있으면 카메라만, 지금 화면 그대로.
        FoldSplitView {
            cameraSide
        } result: {
            CollectionView(collection: collection, inPane: true)
                .environment(\.foldLayout, .single)
        }
        .task {
            #if DEBUG
            // 스크린샷 장면: 시뮬레이터의 빈 캡처 세션은 메인 스레드를 붙잡으므로
            // 카메라는 아예 켜지 않고 화면만 연다
            if ScreenshotScene.isActive {
                camera.isAuthorized = true
                await openScreenshotScene()
                return
            }
            #endif
            await camera.requestAccess()
        }
        // 움직임이 깨진 스티커는 열 때 조용히 바로잡는다 (예전 '스티커 점검')
        .task { collection.repairBrokenMotion() }
        .onAppear { location.start() }
        .onChange(of: camera.capturedImage) { _, newValue in handleCapture(newValue) }
        // 움직임이 도착하면 바로 손떨림을 잡아 둔다 (고르는 화면 · 담기가 같은 것을 쓴다)
        .onChange(of: camera.capturedLiveFrames) { _, frames in
            guard let frames else { return }
            let token = captureToken
            DispatchQueue.global(qos: .userInitiated).async {
                let steady = Stabilizer.steady(frames)
                DispatchQueue.main.async { if captureToken == token { steadyMotion = steady } }
            }
        }
        // Control Center / Lock Screen tapped "펀칭 카메라 열기": drop whatever is
        // open and return to the live camera.
        // 받은 스티커 묶음(.kkuk) — 더하기만 하므로 묻지 않고 받고, 결과를 알린다
        .onChange(of: router.pendingImport) { _, url in
            guard let url else { return }
            router.pendingImport = nil
            // 알림이 가려지지 않게 위에 떠 있는 화면을 닫는다
            showCollection = false
            showSupport = false
            editTarget = nil
            collection.importArchive(at: url) { outcome in
                // 메시지 · AirDrop 으로 받은 사본(Documents/Inbox)은 다 읽었으면 치운다
                if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
                switch outcome {
                case .success(let r): receivedPack = r
                case .failure(let e): receiveError = e.localizedDescription
                }
            }
        }
        .alert(item: $receivedPack) { r in
            Alert(title: Text(StickerImportResult.title(r)),
                  message: Text(StickerImportResult.message(r)))
        }
        .alert("가져오지 못했어요", isPresented: Binding(
            get: { receiveError != nil }, set: { if !$0 { receiveError = nil } })) {
            Button("확인", role: .cancel) { }
        } message: {
            Text(receiveError ?? "")
        }
        .onChange(of: router.cameraRequestID) { _, _ in
            showCollection = false
            editTarget = nil
            showNewAlbum = false
            withAnimation(.easeOut(duration: 0.15)) { revealID = nil }
        }
        // Siri / Spotlight picked a sticker: close what's open and show that one.
        .onReceive(router.$stampRequest.compactMap { $0 }) { id in
            router.stampRequest = nil
            showNewAlbum = false
            revealID = nil
            if showCollection {
                stampAfterCollection = id   // the sheet can only rise once the book has closed
                showCollection = false
            } else {
                editTarget = EditTarget(id: id)
            }
        }
        .alert("새 수집함", isPresented: $showNewAlbum) {
            TextField("수집함 이름", text: $newAlbumName)
            Button("취소", role: .cancel) { }
            Button("만들기") { collection.createAlbum(newAlbumName) }
        }
        // 모음을 구경하는 동안엔 카메라를 쉬게 한다 — 초록불(카메라 사용
        // 표시등)도 꺼지고 배터리도 아낀다; 닫으면 즉시 재가동
        .onChange(of: showCollection) { _, open in
            guard !screenshotMode else { return }
            if open { camera.stop() } else { camera.start() }
        }
        .fullScreenCover(isPresented: $showCollection, onDismiss: {
            if let id = stampAfterCollection {
                stampAfterCollection = nil
                editTarget = EditTarget(id: id)
            }
        }) {
            CollectionView(collection: collection)
                .foldConfined()
        }
        .sheet(isPresented: $showSupport) {
            StampCameraSupportView(collection: collection)
        }
        .paywall($paywallFeature)
        .sheet(isPresented: $showGraduation) {
            LeeoGraduationOfferView(graduate: plans.product(PlanProducts.graduate)) {
                await plans.refresh()
            }
            // 실제로 보인 때를 적는다. 다른 화면에 밀려 못 뜬 판은 세지 않는다.
            .onAppear { plans.markGraduationOffered() }
            .presentationDragIndicator(.visible)
        }
        // 카메라만 떠 있을 때만 띄운다. 뜯는 중이거나 다른 화면이 열려 있으면 다음에 연 때로 미룬다.
        .onChange(of: plans.graduationIsDue) { _, due in
            guard due, !showCollection, !showSupport, editTarget == nil, revealID == nil,
                  paywallFeature == nil else { return }
            showGraduation = true
        }
        .sheet(item: $editTarget) { target in
            NavigationStack {
                StampDetailView(collection: collection, stampID: target.id)
            }
        }
        // result didn't match the request → offer to re-shoot or keep it
        .alert(captureIssue?.title ?? "", isPresented: Binding(
            get: { captureIssue != nil },
            set: { if !$0 { captureIssue = nil } }
        ), presenting: captureIssue) { issue in
            Button("다시 찍기", role: .destructive) {
                collection.delete(issue.id)            // drop the mismatched piece
                if revealID == issue.id { revealID = nil }
            }
            Button("그대로 두기", role: .cancel) { }
        } message: { issue in
            Text(issue.message)
        }
    }

    /// 카메라와 그 위에 뜨는 것(뜯은 직후 카드 · 한 줄 안내). 펼친 화면에서는 고르는 쪽 판에 선다.
    private var cameraSide: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                cameraScreen
            } else if camera.permissionDenied {
                // access refused → black screen explaining the camera is needed
                permissionScreen
            }

            // the post-capture celebration: the fresh stamp as a holographic
            // card over a dimmed blur; tucking it away thumps the bin below.
            if let revealID {
                CaptureRevealView(
                    collection: collection, stampID: revealID, exitPoint: binCenter,
                    onDetail: {
                        self.revealID = nil
                        editTarget = EditTarget(id: revealID)
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) { self.revealID = nil }
                        Haptics.plop()
                        collectPulse += 1                       // the "+1"/ring reward
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.42)) { binBounce = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { binBounce = false }
                        }
                    },
                    onDiscard: {
                        collection.delete(revealID)
                        withAnimation(.easeOut(duration: 0.15)) { self.revealID = nil }
                    })
                .zIndex(20)
                .transition(.opacity)
            }
            if let shot {
                SubjectPickView(shot: shot, cutout: liveCaptureStyle.cutout,
                                motion: { steadyMotion.map { ($0, camera.capturedLiveSeconds) } },
                                onCollect: { picks, moving in
                                    withAnimation(.easeOut(duration: 0.15)) { self.shot = nil }
                                    collect(picks, from: shot, moving: moving)
                                },
                                onCancel: { withAnimation(.easeOut(duration: 0.15)) { self.shot = nil } })
                .zIndex(15)
                .transition(.opacity)
            }
            // a passing note (above the reveal card, which may be up by then)
            if let captureNote {
                VStack {
                    Text(captureNote)
                        .scaledFont(14, weight: .semibold, design: .rounded)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(.top, 64)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(30)
            }
            // while access is still being determined: just the black background,
            // so the guidance never flashes for users who already granted it.
        }
    }

    // MARK: - Camera screen

    private var cameraScreen: some View {
        GeometryReader { geo in
            ZStack {
                if !screenshotMode {
                CameraPreview(session: camera.session) { devicePoint, viewPoint in
                    // tapping the live area focuses + meters there, stock-camera style.
                    camera.focusAndExpose(atDevicePoint: devicePoint)
                    Haptics.tick()
                    focusPoint = viewPoint
                    focusTapID += 1
                }
                .ignoresSafeArea()
                }
                #if DEBUG
                // 스크린샷 장면: 시뮬레이터엔 카메라가 없어 사진 한 장을 비춘다
                if let backdrop = ScreenshotScene.cameraBackdrop {
                    Color.clear
                        .ignoresSafeArea()
                        .overlay { Image(uiImage: backdrop).resizable().scaledToFill() }
                        .clipped()
                        .allowsHitTesting(false)
                }
                #endif

                // "줍줍" — a ring pulse + a "+1" floating up out of the bin each
                // time a stamp is filed, so collecting reads as a little reward.
                if collectPulse > 0 {
                    CollectFX(at: binCenter)
                        .id(collectPulse)
                        .allowsHitTesting(false)
                }

                // tap-to-focus reticle, redrawn (snap + pulse) on every tap
                if let focusPoint {
                    FocusReticle()
                        .id(focusTapID)
                        .position(focusPoint)
                        .allowsHitTesting(false)
                }

                albumBar
                bottomBar

                // ×HUD while pinching — fades out with the gesture
                if pinching {
                    Text(String(format: camera.zoom < 1 ? "%.1f×" : "%.1f×", camera.zoom))
                        .scaledFont(17, weight: .bold, design: .rounded)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(.black.opacity(0.45)))
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.18)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: "cam")
            // two fingers anywhere = continuous zoom (the press is cancelled,
            // so a pinch over the frame never fires the shutter)
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.02)
                    .onChanged { v in
                        if pinchStartZoom == nil {
                            pinchStartZoom = camera.zoom
                            withAnimation(.easeOut(duration: 0.12)) {
                                pinching = true
                                pressed = false           // cancel the punch press
                            }
                        }
                        if let base = pinchStartZoom {
                            camera.setZoom(base * v.magnification)
                        }
                    }
                    .onEnded { _ in
                        pinchStartZoom = nil
                        // linger long enough for the press-drag's onEnded to see
                        // the flag and skip the shutter, then fade the HUD
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            guard pinchStartZoom == nil else { return }
                            withAnimation(.easeOut(duration: 0.25)) { pinching = false }
                        }
                    }
            )
            .onPreferenceChange(BinCenterKey.self) { binCenter = $0 }
            // 미리보기는 안전 영역 밖까지 화면을 가득 채운다 — 자르는 계산도 그 크기로 한다
            .onAppear { previewSize = fullSize(geo) }
            .onChange(of: fullSize(geo)) { _, s in previewSize = s }
        }
    }

    private func fullSize(_ geo: GeometryProxy) -> CGSize {
        let i = geo.safeAreaInsets
        return CGSize(width: geo.size.width + i.leading + i.trailing,
                      height: geo.size.height + i.top + i.bottom)
    }

    /// Top bar: the album chip (where punches get filed) on the left, with the
    /// settings and selfie-flip buttons on the right.
    private var albumBar: some View {
        VStack {
            HStack(spacing: 10) {
                albumChip                    // top-left: 담길 수집함
                // the gap never closes past this, so a long book name truncates
                // instead of sliding under the buttons on the right
                Spacer(minLength: 12)
                supportButton                // top-right: 설정/지원
                flipButton                   // top-right (selfie toggle)
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
            Button {
                if plans.canCreateAlbum(having: collection.albums.count) {
                    newAlbumName = ""; showNewAlbum = true
                } else {
                    paywallFeature = .albums
                }
            } label: {
                Label("새 수집함…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "book.closed.fill")
                Text(collection.activeAlbum)
                    .lineLimit(1)
                Image(systemName: "chevron.down").scaledFont(10, weight: .bold)
            }
            .scaledFont(14, weight: .semibold, design: .rounded)
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .accessibilityLabel("수집함")
        .accessibilityValue(collection.activeAlbum)
    }

    /// 설정/지원 화면을 여는 톱니바퀴 버튼.
    private var supportButton: some View {
        Button {
            Haptics.tick()
            showSupport = true
        } label: {
            Image(systemName: "gearshape")
                .scaledFont(18, weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("설정")
    }

    /// Flips between the back and front (selfie) camera with a little spin.
    private var flipButton: some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { flipAngle += 180 }
            Haptics.select()
            camera.flipCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .scaledFont(19, weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .rotationEffect(.degrees(flipAngle))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("카메라 전환")
    }

    private var bottomBar: some View {
        VStack {
            Spacer()
            if camera.maxZoom > camera.minZoom + 0.01 {
                ZoomControl(camera: camera)
                    .padding(.bottom, 14)
            }
            ZStack {
                shutterButton
                HStack {
                    collectionButton         // bottom-left (gallery)
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    /// 꾹 누르면 들어가고, 떼면 찍힌다.
    private var shutterButton: some View {
        Circle()
            .fill(.white)
            .frame(width: 62, height: 62)
            .scaleEffect(pressed ? 0.84 : 1)
            .frame(width: 78, height: 78)
            .overlay(Circle().strokeBorder(.white, lineWidth: 4))
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressDown() }
                    .onEnded { _ in releaseShutter() }
            )
            .accessibilityElement()
            .accessibilityLabel("촬영")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                pressDown()
                releaseShutter()
            }
    }

    private var screenshotMode: Bool {
        #if DEBUG
        ScreenshotScene.isActive
        #else
        false
        #endif
    }

    #if DEBUG
    /// -ScreenshotScene: seed the photos, then open the asked-for screen.
    private func openScreenshotScene() async {
        guard let scene = ScreenshotScene.scene else { return }
        let ids = await ScreenshotScene.seed(collection)
        guard let first = ids.first else { return }
        switch scene {
        case "reveal": revealID = first
        case "detail": editTarget = EditTarget(id: first)
        case "album", "arrange": showCollection = true
        case "settings": showSupport = true
        case "pick":
            // 고르는 화면 (시뮬레이터는 대상을 찾지 못하므로 "사진 그대로"와 직접 그리기만 보인다)
            if let photo = ScreenshotScene.cameraBackdrop {
                let size = previewSize == .zero ? UIScreen.main.bounds.size : previewSize
                shot = PhotoShot.make(raw: photo, size: size, mirrored: false)
            }
        default: break
        }
    }
    #endif

    /// Shows `text` over the camera for a moment, then fades it.
    private func showCaptureNote(_ text: String) {
        captureNoteToken += 1
        let token = captureNoteToken
        withAnimation(.easeOut(duration: 0.2)) { captureNote = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            guard captureNoteToken == token else { return }
            withAnimation(.easeOut(duration: 0.3)) { captureNote = nil }
        }
    }

    /// Finger down: the shutter sinks in.
    private func pressDown() {
        guard shot == nil, !pressed, !pinching else { return }   // 고르는 중 · 줌 중에는 찍지 않는다
        withAnimation(.easeIn(duration: 0.12)) { pressed = true }
    }

    /// Finger up: spring the frame back up and fire the shutter on release.
    private func releaseShutter() {
        if pinching {                         // the lift that ends a pinch — no shutter
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pressed = false }
            return
        }
        guard pressed else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.5)) { pressed = false }
        // 한 번에 한 장: 누른 뒤 사진이 뜰 때까지 다시 찍히지 않는다
        guard !captureInFlight else { return }
        captureInFlight = true
        awaitingImage = true
        captureToken += 1
        let token = captureToken
        // watchdog: if no photo ever arrives (a hard pipeline failure), release
        // the lock so the shutter isn't stuck.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if captureToken == token { captureInFlight = false; awaitingImage = false }
        }
        PunchSound.play()                     // 펀칭! — ~1s punch sound
        Haptics.ratchet()                     // 드르륵 — the punch biting through
        camera.capturedLiveFrames = nil       // 지난 사진의 움직임이 섞이지 않게
        steadyMotion = nil
        liveCaptureStyle = captureStyle
        // 항상 라이브로 찍어 "마스터"(움직임 + 원본)를 무조건 보관한다.
        // 보이는 모습(정지/우표/스티커/라이브)은 전부 이 마스터에서 후가공으로
        // 파생되므로, 찍은 뒤 어느 모습으로도 무손실 전환할 수 있다.
        camera.capturePhoto(live: true)
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
        .accessibilityLabel("모아보기")
        .accessibilityValue(Text("\(collection.stamps.count)장"))
    }

    // MARK: - Capture → crop → fly into collection

    private func handleCapture(_ newValue: UIImage?) {
        // only the FIRST capturedImage per shutter counts — a duplicate publish
        // (e.g. the photo + the error-fallback video frame) is ignored.
        guard awaitingImage else { return }
        awaitingImage = false
        guard let raw = newValue, previewSize != .zero else { captureInFlight = false; return }
        let size = previewSize
        let mirrored = camera.position == .front
        let token = captureToken
        // 화면에 보이던 그대로의 사진에서 대상 · 얼굴을 찾는다 (Vision 은 느리다 → 뒤에서)
        DispatchQueue.global(qos: .userInitiated).async {
            let made = PhotoShot.make(raw: raw, size: size, mirrored: mirrored)
            DispatchQueue.main.async {
                guard captureToken == token else { return }      // 그새 다시 찍었다
                captureInFlight = false
                withAnimation(.easeOut(duration: 0.18)) { shot = made }
            }
        }
    }

    /// 고른 후보들을 스티커로 담는다. 첫 스티커는 카드로 뜨고, 여럿이면 몇 개 담았는지 알린다.
    private func collect(_ picks: [StickerCandidate], from shot: PhotoShot, moving: Bool) {
        guard !picks.isEmpty else { return }
        // 모양은 설정의 기본 모양, 움직임은 고르는 화면에서 정한 대로
        let style = StampStyle.make(moving: moving, cutout: liveCaptureStyle.cutout)
        let here = location.current
        // 움직임 프레임은 셔터 뒤 1초 남짓 지나 도착한다 — 아직이면 잠깐 기다린다
        let wait: Double = steadyMotion == nil ? 1.6 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            // 멈춘 스티커로 담아도 움직임 원본은 함께 남긴다 — 나중에 상세에서 움직이게 바꿀 수 있게
            let motion = steadyMotion.map { (frames: $0, seconds: camera.capturedLiveSeconds) }
            collection.addStickers(from: shot, picks: picks, style: style,
                                   motion: motion, location: here) { ids, fellBack in
                guard let first = ids.first else { return }
                Haptics.bounce()   // the soft "착" of paper settling
                if let here {
                    Task {
                        if let place = await location.placeName(for: here) {
                            ids.forEach { collection.setPlace(place, for: $0) }
                        }
                    }
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { revealID = first }
                if ids.count > 1 {
                    showCaptureNote(String(localized: "스티커 \(ids.count)개를 담았어요"))
                } else if fellBack {
                    showCaptureNote(String(localized: "오려낼 대상이 없어 우표 모양으로 뜯었어요"))
                }
                verifyMotion(first)
            }
        }
    }

    /// 움직이는 모양으로 담았는데 움직임이 붙지 않았으면 다시 찍을지 묻는다.
    /// (움직임은 스티커가 담긴 뒤에 잘라 붙이므로 조금 기다렸다 본다)
    private func verifyMotion(_ id: String) {
        guard collection.style(for: id).moving else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            guard captureIssue == nil,
                  collection.stamps.contains(where: { $0.id == id }) else { return }
            if !collection.isPlayablyLive(id) {
                captureIssue = CaptureIssue(id: id, kind: .motion)
            }
        }
    }

    // MARK: - Permission

    /// Shown only when camera access has been refused — a black screen telling
    /// the user the camera is needed, with a shortcut into Settings. Once access
    /// is granted this never appears again.
    private var permissionScreen: some View {
        VStack(spacing: 18) {
            Text("📮 펀칭")
                .scaledFont(28, weight: .heavy, design: .rounded)
                .foregroundStyle(.white)
            Text("순간을 스티커로 뜯으려면 카메라 권한이 필요해요.\n설정에서 카메라를 켜주세요.")
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

/// 수집함 목록 — 카메라 왼쪽 아래 썸네일이 여는 화면. 수집함 하나하나가
/// 메시지·키보드의 스티커 묶음이다.
struct CollectionView: View {
    @ObservedObject var collection: CollectionStore
    /// 아이폰 듀오를 폈을 때 카메라 옆 판에 서는가. 그때는 닫을 것이 없어 '카메라' 단추를 빼고,
    /// 뜯은 스티커가 담기는 수집함(지금 고른 것)을 펴 둔다.
    var inPane = false
    @Environment(\.dismiss) private var dismiss

    /// Album names pushed on the stack. Starts deep-linked to the album last
    /// opened, for a quick look; back from there lands on this list.
    @State private var path: [String]

    init(collection: CollectionStore, inPane: Bool = false) {
        _collection = ObservedObject(wrappedValue: collection)
        self.inPane = inPane
        let last = inPane ? collection.activeAlbum
            : UserDefaults.standard.string(forKey: "lastVisitedAlbum") ?? ""
        _path = State(initialValue: (!last.isEmpty && collection.albums.contains(last)) ? [last] : [])
    }

    @State private var showNewAlbum = false
    @State private var newAlbumName = ""
    @ObservedObject private var plans = PunchingPlans.shared
    @State private var paywallFeature: PlanFeature?
    @State private var searchQuery = ""
    @State private var searchTarget: EditTarget?
    // 사진 앱에서 가져오기 — 활성 수집함에 기본 모양의 멈춘 스티커로 담는다
    @State private var importShot: PhotoShot?
    @State private var photoItem: PhotosPickerItem?
    @AppStorage("captureStyle") private var captureStyleRaw = StampStyle.liveSticker.rawValue

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 18)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // 모은 스티커를 둘러보는 자리. 숫자가 쌓였을 때만, 드물게 응원을 부탁한다 (모달 아님)
                if searchQuery.isEmpty {
                    LeeoTipAskSlot<StampCameraSpec>(tipJar: StampCameraSpec.tipJar,
                                                    reached: StampCameraTipMoments.reached(punchedCount: collection.stamps.count))
                        .padding([.horizontal, .top], 20)
                    albumShelf
                } else {
                    searchResults
                }
            }
            .background(Color(hex: 0x141210).ignoresSafeArea())
            // 한 마디 · 장소 · 수집함 · 날짜 · 스티커 글자로 찾기 — 사진 앱 스티커엔 없는 검색
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: Text("한 마디, 장소, 날짜로 찾기"))
            .sheet(item: $searchTarget) { target in
                NavigationStack { StampDetailView(collection: collection, stampID: target.id) }
            }
            .navigationTitle("수집함")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { name in
                AlbumPageView(collection: collection, album: name)
            }
            .toolbar {
                // 사진 앱처럼 — 왼쪽 위 뒤로가기로 카메라로 돌아간다
                if !inPane {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Label("카메라", systemImage: "chevron.backward")
                        }
                        .scaledFont(15, weight: .semibold)
                    }
                }
                // 두 동작을 한 항목 안에 나란히 둬서 시스템이 '...'로 접지
                // 않고 항상 펼쳐 보이게 한다: 새 수집함 · 사진 가져오기
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 18) {
                        Button {
                            if plans.canCreateAlbum(having: collection.albums.count) {
                                newAlbumName = ""; showNewAlbum = true
                            } else {
                                paywallFeature = .albums
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("새 수집함")
                        PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                            Image(systemName: "photo.badge.plus")
                        }
                        .accessibilityLabel("사진에서 가져오기")
                    }
                }
            }
            .alert("새 수집함", isPresented: $showNewAlbum) {
                TextField("수집함 이름", text: $newAlbumName)
                Button("취소", role: .cancel) { }
                Button("만들기") { collection.createAlbum(newAlbumName) }
            }
            .onChange(of: photoItem) { _, item in loadImportedPhoto(item) }
            .fullScreenCover(isPresented: Binding(get: { importShot != nil },
                                                  set: { if !$0 { importShot = nil } })) {
                if let shot = importShot {
                    SubjectPickView(shot: shot, cancelTitle: "취소",
                                    cutout: (StampStyle(rawValue: captureStyleRaw) ?? .liveSticker).cutout,
                                    onCollect: { picks, _ in
                                        importShot = nil
                                        collectImported(picks, from: shot)
                                    },
                                    onCancel: { importShot = nil })
                }
            }
            .paywall($paywallFeature)
            // 옆 판에서는 카메라 칩으로 수집함을 바꾸면 그 수집함을 따라 편다.
            .onChange(of: collection.activeAlbum) { _, album in
                if inPane { path = [album] }
            }
        }
        // the list is dark; an open album follows its paper (status bar too —
        // a pushed page's own preference loses to this one, so decide it here).
        // 옆 판에서는 창 전체(카메라 쪽)의 어둠을 바꾸지 않도록 이 판에만 건다.
        .modifier(PaperScheme(light: topIsLightPaper, scopedToPane: inPane))
    }

    private var topIsLightPaper: Bool {
        guard let album = path.last else { return false }
        return collection.count(in: album) > 0 && !collection.backgroundStyle(of: album).isDark
    }

    /// Loads the chosen library photo and files it straight away.
    private func loadImportedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data) else { return }
            await MainActor.run {
                photoItem = nil
                makeFromLibrary(img)
            }
        }
    }

    /// 가져온 사진도 카메라와 같은 화면에서 스티커로 만들 것을 고른다.
    private func makeFromLibrary(_ photo: UIImage) {
        DispatchQueue.global(qos: .userInitiated).async {
            let made = PhotoShot.make(photo: photo)
            DispatchQueue.main.async { importShot = made }
        }
    }

    /// 고른 것을 기본 모양(설정 ▸ 기본 모양)의 멈춘 스티커로 담고, 담긴 수집함을 편다.
    private func collectImported(_ picks: [StickerCandidate], from shot: PhotoShot) {
        let cutout = (StampStyle(rawValue: captureStyleRaw) ?? .liveSticker).cutout
        collection.addStickers(from: shot, picks: picks, style: .make(moving: false, cutout: cutout),
                               motion: nil) { ids, _ in
            guard !ids.isEmpty else { return }
            Haptics.bounce()
            path = [collection.activeAlbum]
        }
    }

    /// 검색 결과 — 모든 수집함을 가로질러 찾는다.
    private var searchResults: some View {
        let hits = collection.search(searchQuery)
        return Group {
            if hits.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.35))
                    Text("찾는 스티커가 없어요")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(hits.count)장")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 14)], spacing: 16) {
                        ForEach(hits) { stamp in
                            Button { searchTarget = EditTarget(id: stamp.id) } label: {
                                VStack(spacing: 6) {
                                    LiveArt(collection: collection, stamp: stamp)
                                        .frame(height: 96)
                                    Text(stamp.caption.isEmpty ? stamp.album : stamp.caption)
                                        .font(.body)
                                        .lineLimit(1)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var albumShelf: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(collection.albums, id: \.self) { album in
                NavigationLink(value: album) {
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
}

/// 수집함의 밝기. 창을 혼자 쓰면 창 전체(상태 막대까지)를, 카메라 옆 판이면 그 판만 바꾼다.
private struct PaperScheme: ViewModifier {
    let light: Bool
    let scopedToPane: Bool

    func body(content: Content) -> some View {
        if scopedToPane {
            content.environment(\.colorScheme, light ? .light : .dark)
        } else {
            content.preferredColorScheme(light ? .light : .dark)
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

// MARK: - Album page (stamps pressed onto the book's pages)

struct AlbumPageView: View {
    @ObservedObject var collection: CollectionStore
    let album: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastVisitedAlbum") private var lastVisitedAlbum = ""

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteAlbum = false
    @State private var deleteTarget: CollectedStamp?

    // Tapping a stamp opens its detail as a modal (not a pushed page).
    @State private var selectedStamp: CollectedStamp?

    // 쓰기: 수집함을 통째로 — 이미지 카드 공유 · 인쇄용 스티커 시트
    @State private var sharePayload: SharePayload?
    @State private var showPrintGuide = false
    @State private var exporting = false
    @ObservedObject private var plans = PunchingPlans.shared
    @State private var paywallFeature: PlanFeature?
    @State private var makeSheetAfterGuide = false

    // 움직임 자동 재생이 꺼져 있으면 라이브 심볼도 숨긴다 (안 움직이는
    // 이미지에 라이브 표식이 붙는 거짓말 방지)
    @AppStorage("liveAutoPlay") private var liveAutoPlay = true
    // 책처럼 넘기기(설정) — 켜면 종이 넘김, 끄면 점 인디케이터
    @AppStorage("pageCurl") private var pageCurl = false

    /// 모아보기 필터 — 모양 · 움직임으로 추려 본다.
    private enum PocketFilter: String, CaseIterable, Identifiable {
        case all, moving, cutout, stampShape
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return String(localized: "전체")
            case .moving: return String(localized: "움직이는 것")
            case .cutout: return String(localized: "오려낸 모양")
            case .stampShape: return String(localized: "우표 모양")
            }
        }
        var icon: String {
            switch self {
            case .all: return "square.grid.3x3"
            case .moving: return "livephoto"
            case .cutout: return "scissors"
            case .stampShape: return "square.dashed"
            }
        }
    }
    @State private var filter: PocketFilter = .all

    // Multi-select mode: tap stamps to tick them, then move or delete in one go.
    @State private var selecting = false
    @State private var selectedIDs = Set<String>()
    @State private var showDeleteSelected = false

    // 자유롭게 꾸미기: pick the paper and hold-then-drag stickers into any order.
    @State private var arranging = false
    /// The sticker being carried while arranging, and where (leaf coords).
    @State private var lifted: String?
    @State private var liftPos: CGPoint = .zero

    private let perPage = 12          // 3×4 pockets per leaf
    private let pad: CGFloat = 18
    private let spacing: CGFloat = 16

    private var stamps: [CollectedStamp] {
        let base = collection.stamps(in: album)
        switch filter {
        case .all: return base
        case .moving: return base.filter { collection.style(for: $0.id).moving }
        case .cutout: return base.filter { collection.style(for: $0.id).cutout }
        case .stampShape: return base.filter { !collection.style(for: $0.id).cutout }
        }
    }
    private var background: BackgroundStyle { collection.backgroundStyle(of: album) }
    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }
    private var otherAlbums: [String] { collection.albums.filter { $0 != album } }

    /// Everything the curled leaves render from — when any of it changes the
    /// visible page must be rebuilt (ids, selection, badges, looks, paper).
    private var leafContentKey: String {
        let ids: String = stamps.map(\.id).joined(separator: ",")
        let fresh: Int = stamps.filter { collection.isFresh($0) }.count
        let live: Int = stamps.filter { collection.isPlayablyLive($0.id) }.count
        let rev: Int = collection.liveRev.values.reduce(0, +)
        return ids + "|sel:\(selecting)|ticks:\(selectedIDs.count)-\(selectedIDs.hashValue)"
            + "|fresh:\(fresh)|live:\(live)|rev:\(rev)|auto:\(liveAutoPlay)|f:\(filter.rawValue)"
            + "|arr:\(arranging)-\(lifted ?? "")|bg:\(background.rawValue)"
    }

    /// Time order unless arranged — so a fresh capture lands on the last page.
    private var pageCount: Int {
        max(1, Int(ceil(Double(stamps.count) / Double(perPage))))
    }
    @State private var currentPage = 0

    /// The booklet of leaves — a plain paged indicator by default, or the paper
    /// page-curl when "책처럼 넘기기" is on. Extracted from `body` so the type
    /// checker doesn't choke on the large expression.
    @ViewBuilder private var pagedBook: some View {
        if pageCurl {
            PageCurlView(pageCount: pageCount, currentPage: $currentPage,
                         contentKey: leafContentKey,
                         interactive: lifted == nil) { pageIndex in
                albumLeaf(pageIndex)
            }
        } else {
            // a horizontal paging ScrollView (not TabView): the arrange carry is a
            // simultaneous drag designed to coexist with a scroll pan, which
            // TabView's own paging gesture fights. Frozen only while carrying.
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<pageCount, id: \.self) { pageIndex in
                            albumLeaf(pageIndex)
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: scrollPageBinding)
                .scrollDisabled(lifted != nil)
            }
        }
    }

    /// Bridges the `Int?` scroll position to the `Int` currentPage, so the same
    /// page state drives both the ScrollView and the page-curl.
    private var scrollPageBinding: Binding<Int?> {
        Binding(get: { currentPage }, set: { currentPage = $0 ?? currentPage })
    }

    var body: some View {
        VStack(spacing: 0) {
            if stamps.isEmpty {
                if filter == .all {
                    emptyPage
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: filter.icon)
                            .scaledFont(38)
                            .accessibilityHidden(true)
                            .foregroundStyle(.white.opacity(0.3))
                        Text("\(filter.title)에 해당하는 스티커가 아직 없어요")
                            .scaledFont(14, weight: .medium, design: .rounded)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 140)
                }
                Spacer()
            } else {
                // leaves of 12, flipped with a horizontal swipe — no vertical
                // scrolling anywhere. Default is a plain paged indicator (dots);
                // "책처럼 넘기기"(설정) switches to the paper page-curl.
                pagedBook
                .onChange(of: stamps.count) { _, _ in
                    if currentPage > pageCount - 1 { currentPage = max(0, pageCount - 1) }
                }
                .onAppear { currentPage = pageCount - 1 }   // open at the working page
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // the album's diary paper fills edge-to-edge as the backdrop, so each
        // leaf can sit inside the safe area and still look like one page.
        .background {
            Group {
                if stamps.isEmpty && !arranging {
                    Color(hex: 0x141210)
                } else {
                    DiaryBackground(style: background)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            lastVisitedAlbum = album   // remember for the camera shortcut
            #if DEBUG
            if ScreenshotScene.scene == "arrange" { startArranging() }
            #endif
        }
        .navigationTitle(album)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if arranging {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료", systemImage: "checkmark") { finishArranging() }
                }
            } else {
                // 선택은 그대로 우측 상단에
                ToolbarItem(placement: .topBarTrailing) {
                    if !stamps.isEmpty {
                        Button(selecting ? String(localized: "취소") : String(localized: "선택"),
                               systemImage: selecting ? "xmark" : "checkmark.circle") {
                            withAnimation(.easeOut(duration: 0.18)) {
                                selecting.toggle()
                                selectedIDs.removeAll()
                            }
                        }
                        .scaledFont(14, weight: .semibold, design: .rounded)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { albumMenu }
                // 필터 → 왼쪽 하단 툴바
                ToolbarItemGroup(placement: .bottomBar) {
                    Menu {
                        ForEach(PocketFilter.allCases) { f in
                            Button {
                                filter = f
                                currentPage = 0
                                Haptics.tick()
                            } label: {
                                Label(f.title, systemImage: f == filter ? "checkmark" : f.icon)
                            }
                        }
                    } label: {
                        Image(systemName: filter == .all
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("모아보기")
                    Spacer()
                }
            }
        }
        .navigationBarBackButtonHidden(arranging)
        .toolbar(arranging ? .hidden : .automatic, for: .bottomBar)
        .safeAreaInset(edge: .bottom) {
            Group {
                if arranging {
                    arrangeBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if selecting {
                    selectionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .environment(\.colorScheme, .dark)   // white-on-glass, whatever the paper
        }
        .confirmationDialog("선택한 스티커 \(selectedIDs.count)장을 삭제할까요?",
                            isPresented: $showDeleteSelected, titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                for id in selectedIDs { collection.delete(id) }
                Haptics.placed()
                endSelecting()
            }
            Button("취소", role: .cancel) { }
        }
        .alert("이름 변경", isPresented: $showRename) {
            TextField("수집함 이름", text: $renameText)
            Button("취소", role: .cancel) { }
            Button("저장") { collection.renameAlbum(album, to: renameText) }
        }
        .confirmationDialog("수집함 '\(album)' 과(와) 안의 스티커 \(collection.count(in: album))장을 모두 삭제할까요?",
                            isPresented: $showDeleteAlbum, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { collection.deleteAlbum(album); dismiss() }
            Button("취소", role: .cancel) { }
        }
        .confirmationDialog("이 스티커를 삭제할까요?", isPresented: deletePresented,
                            titleVisibility: .visible, presenting: deleteTarget) { stamp in
            Button("삭제", role: .destructive) { collection.delete(stamp.id) }
            Button("취소", role: .cancel) { }
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
        // 가이드 끝에서 '스티커 시트 만들기'를 눌렀으면 가이드가 다 닫힌 뒤에 만든다 (공유 시트가 설 자리)
        .sheet(isPresented: $showPrintGuide, onDismiss: {
            if makeSheetAfterGuide { makeSheetAfterGuide = false; exportStickers() }
        }) {
            PrintGuideView(makeSheet: collection.count(in: album) > 0 ? { makeSheetAfterGuide = true } : nil)
        }
        .paywall($paywallFeature)
        .fullScreenCover(item: $selectedStamp, onDismiss: { Haptics.deselect() }) { stamp in
            StampRevealView(collection: collection, stampID: stamp.id)
                .foldConfined()
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
        // title · status bar · toolbar follow the paper: ink on light papers,
        // white on dark ones (and on the dark empty page), so nothing vanishes
        // (the status bar follows it too — CollectionView decides that one)
        .toolbarColorScheme(onLightPaper ? .light : .dark, for: .navigationBar)
    }

    private var onLightPaper: Bool { !(stamps.isEmpty && !arranging) && !background.isDark }

    // MARK: - Menus & bars

    private var albumMenu: some View {
        Menu {
            if collection.activeAlbum != album {
                Button { collection.setActive(album) } label: {
                    Label("여기에 담기", systemImage: "tray.and.arrow.down")
                }
            } else {
                Label("여기에 담는 중", systemImage: "checkmark")
            }
            Button { renameText = album; showRename = true } label: {
                Label("이름 변경", systemImage: "pencil")
            }
            Button { startArranging() } label: {
                Label("자유롭게 꾸미기", systemImage: "paintbrush.pointed")
            }
            Divider()
            Section("쓰기") {
                // 수집함을 통째로 — 받은 사람이 펀칭에서 열면 같은 수집함으로 들어온다
                Button { sendPack() } label: {
                    Label("수집함 통째로 보내기", systemImage: "shippingbox")
                }
                .disabled(collection.count(in: album) == 0)
                Button { exportCard() } label: {
                    Label("이미지로 공유", systemImage: plans.allows(.albumImage) ? "square.and.arrow.up" : "lock")
                }
                .disabled(collection.count(in: album) == 0)
                Button { exportStickers() } label: {
                    Label("인쇄용 스티커 시트 (PDF)", systemImage: plans.allows(.printSheet) ? "printer" : "lock")
                }
                .disabled(collection.count(in: album) == 0)
                Button { showPrintGuide = true } label: {
                    Label("인쇄 가이드", systemImage: "questionmark.circle")
                }
            }
            if collection.albums.count > 1 {
                Divider()
                Button(role: .destructive) { showDeleteAlbum = true } label: {
                    Label("수집함 삭제", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("더 보기")
    }

    /// multi-select: a tally + move + delete bar over the bottom edge
    private var selectionBar: some View {
        let allIDs = Set(stamps.map(\.id))
        let allPicked = !allIDs.isEmpty && selectedIDs.isSuperset(of: allIDs)
        return HStack(spacing: 14) {
            Button(allPicked ? String(localized: "모두 해제") : String(localized: "모두 선택")) {
                Haptics.tick()
                selectedIDs = allPicked ? [] : allIDs
            }
            .scaledFont(14, weight: .semibold, design: .rounded)
            .tint(.white)
            Spacer()
            Text(selectedIDs.isEmpty ? String(localized: "스티커를 골라주세요")
                                     : String(localized: "\(selectedIDs.count)장 선택됨"))
                .scaledFont(14, weight: .semibold, design: .rounded)
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            if !otherAlbums.isEmpty {
                Menu {
                    ForEach(otherAlbums, id: \.self) { a in
                        Button(a) {
                            for id in selectedIDs { collection.move(id, to: a) }
                            Haptics.placed()
                            endSelecting()
                        }
                    }
                } label: {
                    Label("옮기기", systemImage: "folder")
                        .scaledFont(15, weight: .bold, design: .rounded)
                }
                .tint(.white)
                .disabled(selectedIDs.isEmpty)
            }
            Button(role: .destructive) { showDeleteSelected = true } label: {
                Label("삭제", systemImage: "trash")
                    .scaledFont(15, weight: .bold, design: .rounded)
            }
            .tint(.red)
            .disabled(selectedIDs.isEmpty)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    /// 자유롭게 꾸미기: the papers to choose from, a hint, and a way back to
    /// plain time order.
    private var arrangeBar: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(BackgroundStyle.allCases) { style in
                        let open = plans.allows(style)
                        Button {
                            Haptics.tick()
                            // 잠긴 속지도 미리보기로 보인다. 누르면 고르는 대신 Plus 를 보여 준다.
                            if open { collection.setBackground(style, for: album) } else { paywallFeature = .papers }
                        } label: {
                            VStack(spacing: 4) {
                                DiaryBackground(style: style)
                                    .frame(width: 46, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(style == background ? Color(hex: 0xF2B23B) : .white.opacity(0.25),
                                                      lineWidth: style == background ? 2.5 : 1))
                                    .overlay(alignment: .topTrailing) {
                                        if !open { PlanLockBadge(feature: .papers).padding(2) }
                                    }
                                Text(style.title)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(style == background ? 1 : 0.6))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(style.title) 배경")
                        .accessibilityValue(open ? "" : String(localized: "잠김, \(PlanFeature.papers.tier.title)에서 열려요"))
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                if plans.allows(.arrange) {
                    Text("스티커를 꾹 눌러 원하는 자리로 옮겨요")
                        .scaledFont(12, weight: .medium, design: .rounded)
                        .foregroundStyle(.white.opacity(0.65))
                } else {
                    Button { paywallFeature = .arrange } label: {
                        Label("스티커 순서 바꾸기는 Plus에서 열려요", systemImage: "lock.fill")
                            .scaledFont(12, weight: .semibold, design: .rounded)
                    }
                    .tint(.white)
                }
                Spacer()
                if collection.isArranged(album) {
                    Button("찍은 순서로") {
                        Haptics.tick()
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                            collection.resetOrder(album)
                        }
                    }
                    .scaledFont(13, weight: .semibold, design: .rounded)
                    .tint(.white)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func startArranging() {
        Haptics.select()
        withAnimation(.easeOut(duration: 0.2)) {
            selecting = false
            selectedIDs.removeAll()
            filter = .all          // arranging works on the whole album's order
            arranging = true
        }
    }

    private func finishArranging() {
        Haptics.tick()
        withAnimation(.easeOut(duration: 0.2)) {
            arranging = false
            lifted = nil
        }
    }

    private func endSelecting() {
        withAnimation(.easeOut(duration: 0.18)) {
            selecting = false
            selectedIDs.removeAll()
        }
    }

    // MARK: - Leaves

    /// One full-bleed leaf of the album book: this page's 12 pockets in a 3×4
    /// spread, the page dots at the foot. A tap opens the sticker; a long press
    /// offers copy / send / move. While arranging, a hold lifts a sticker and
    /// the same touch carries it to another cell.
    private func albumLeaf(_ pageIndex: Int) -> some View {
        GeometryReader { geo in
            let cellW = (geo.size.width - 2 * pad - 2 * spacing) / 3
            let gold = goldIDs
            let firstPlaces = firstPlaceIDs
            let start = pageIndex * perPage
            let slice = Array(stamps.dropFirst(start).prefix(perPage))
            let columns = Array(repeating: GridItem(.fixed(cellW), spacing: spacing), count: 3)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    LazyVGrid(columns: columns, spacing: spacing) {
                        ForEach(Array(slice.enumerated()), id: \.element.id) { i, stamp in
                            PocketAppear(index: i) {
                                stampCell(stamp, gold: gold, firstPlaces: firstPlaces, cell: cellW,
                                          pageIndex: pageIndex, cellIndex: i, pageW: geo.size.width)
                            }
                        }
                    }
                    .padding(pad)
                    Spacer(minLength: 0)
                    if pageCount > 1 {
                        PageDots(count: pageCount, current: pageIndex)
                            .environment(\.colorScheme, .dark)
                            .padding(.bottom, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // the lifted sticker riding the finger, exactly where it'll land
                if let id = lifted, slice.contains(where: { $0.id == id }),
                   let s = collection.stamps.first(where: { $0.id == id }) {
                    pagePocket(s, height: cellW)
                        .frame(width: cellW)
                        .scaleEffect(1.1)
                        .rotationEffect(.degrees(-3))
                        .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
                        .position(liftPos)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "leaf")
        }
    }

    /// Every 10th sticker collected into this book is a gold edition — mounted
    /// on foil with a little crown. By time, so arranging never reshuffles it.
    private var goldIDs: Set<String> {
        let ordered = collection.stamps(in: album).sorted { $0.createdAt < $1.createdAt }
        return Set(ordered.enumerated().compactMap { i, s in (i + 1) % 10 == 0 ? s.id : nil })
    }

    /// The first sticker made at each distinct place — a collector's "첫 발도장".
    private var firstPlaceIDs: Set<String> {
        let ordered = collection.stamps(in: album).sorted { $0.createdAt < $1.createdAt }
        var seen = Set<String>(), out = Set<String>()
        for s in ordered where !s.place.isEmpty {
            if seen.insert(s.place).inserted { out.insert(s.id) }
        }
        return out
    }

    @ViewBuilder
    private func stampCell(_ stamp: CollectedStamp,
                           gold: Set<String>, firstPlaces: Set<String>, cell: CGFloat,
                           pageIndex: Int, cellIndex: Int, pageW: CGFloat) -> some View {
        let isTicked = selectedIDs.contains(stamp.id)
        let isNew = collection.isFresh(stamp)
        let moves = liveAutoPlay && collection.isPlayablyLive(stamp.id)
        let badges = !selecting && !arranging
        let pocket = pagePocket(stamp, gold: gold.contains(stamp.id), height: cell)
            .overlay(alignment: .topLeading) {
                if isNew && badges {
                    Text("NEW")
                        .font(.system(size: 7, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Capsule().fill(Color(hex: 0xE8504E)))
                        .offset(x: -3, y: -5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if firstPlaces.contains(stamp.id) && badges {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, Color(hex: 0x4D6A9C))
                        .background(Circle().fill(.white).padding(1))
                        .offset(x: 4, y: 4)
                }
            }
            // 살아 움직이는 스티커의 표식
            .overlay(alignment: .bottomLeading) {
                if moves && badges {
                    Image(systemName: "livephoto")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(hex: 0xFFD60A))
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .offset(x: -2, y: 3)
                }
            }
        if arranging {
            arrangeCell(pocket, id: stamp.id, cell: cell,
                        pageIndex: pageIndex, cellIndex: cellIndex, pageW: pageW)
        } else {
            pocket
                .opacity(selecting && !isTicked ? 0.55 : 1)
                // the tick badge while picking stickers to move / delete
                .overlay(alignment: .topTrailing) {
                    if selecting {
                        Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(isTicked ? Color(hex: 0xF2B23B) : .white.opacity(0.65))
                            .background(Circle().fill(.black.opacity(0.45)).padding(1))
                            .padding(3)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selecting {
                        Haptics.tick()
                        if isTicked { selectedIDs.remove(stamp.id) }
                        else { selectedIDs.insert(stamp.id) }
                    } else {
                        Haptics.select()
                        collection.markSeen(stamp.id)   // NEW 배지는 한 번 보면 끝
                        selectedStamp = stamp
                    }
                }
                // a system context menu (not a drag gesture) so swiping over the
                // grid still turns the page
                .contextMenu { if !selecting { stickerMenu(stamp) } }
                // VoiceOver: 그림 대신 한 마디·날짜·장소·표식을 읽는다
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stampAccessibilityLabel(stamp, isNew: isNew && badges, moves: moves,
                                                            gold: gold.contains(stamp.id)))
                .accessibilityAddTraits(isTicked ? [.isButton, .isSelected] : .isButton)
        }
    }

    /// "한 마디, 10월 3일 오후 2:10, 성수동, 새 스티커" 처럼 읽는 이름.
    private func stampAccessibilityLabel(_ stamp: CollectedStamp, isNew: Bool, moves: Bool, gold: Bool) -> String {
        var parts = [stamp.caption.isEmpty ? String(localized: "스티커") : stamp.caption,
                     stamp.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if !stamp.place.isEmpty { parts.append(stamp.place) }
        if isNew { parts.append(String(localized: "새 스티커")) }
        if moves { parts.append(String(localized: "움직이는 스티커")) }
        if gold { parts.append(String(localized: "골드 에디션")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func stickerMenu(_ stamp: CollectedStamp) -> some View {
        Button {
            collection.makeExport(for: stamp.id) { export in
                export?.copy()
                Haptics.placed()
            }
        } label: { Label("복사", systemImage: "doc.on.doc") }
        Button {
            collection.makeExport(for: stamp.id) { export in
                if let url = export?.url { sharePayload = SharePayload(items: [url]) }
            }
        } label: { Label("보내기", systemImage: "paperplane") }
        if !otherAlbums.isEmpty {
            Menu {
                ForEach(otherAlbums, id: \.self) { a in
                    Button(a) { collection.move(stamp.id, to: a); Haptics.placed() }
                }
            } label: { Label("다른 수집함으로", systemImage: "folder") }
        }
        Divider()
        Button(role: .destructive) { deleteTarget = stamp } label: {
            Label("삭제", systemImage: "trash")
        }
    }

    /// A pocket while arranging: hold to lift (the system long press, so the
    /// pager keeps any quick swipe), then the same touch carries it; release
    /// snaps it into the nearest cell of this page.
    private func arrangeCell(_ pocket: some View, id: String, cell: CGFloat,
                             pageIndex: Int, cellIndex: Int, pageW: CGFloat) -> some View {
        let home = CGPoint(x: pad + CGFloat(cellIndex % 3) * (cell + spacing) + cell / 2,
                           y: pad + CGFloat(cellIndex / 3) * (cell + spacing) + cell / 2)
        return pocket
            .opacity(lifted == id ? 0 : 1)        // its lifted copy rides the finger
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .opacity(lifted == id ? 0 : 1)
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 12) {
                guard plans.allows(.arrange) else { paywallFeature = .arrange; return }
                liftPos = home
                lifted = id
                Haptics.select()
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("leaf"))
                    .onChanged { v in
                        guard lifted == id else { return }
                        liftPos = v.location
                    }
                    .onEnded { v in
                        guard lifted == id else { return }
                        let target = pageIndex * perPage + nearestCell(v.location, cell: cell)
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.75)) {
                            collection.reorder(in: album, moving: id, to: target)
                            lifted = nil
                        }
                        Haptics.placed()
                    }
            )
    }

    /// Index (0…11) of the cell nearest a point on the leaf.
    private func nearestCell(_ p: CGPoint, cell: CGFloat) -> Int {
        let step = cell + spacing
        let c = min(max(Int(((p.x - pad - cell / 2) / step).rounded()), 0), 2)
        let r = min(max(Int(((p.y - pad - cell / 2) / step).rounded()), 0), perPage / 3 - 1)
        return r * 3 + c
    }

    /// One sticker pressed onto the album page, on its own white tile.
    private func pagePocket(_ stamp: CollectedStamp, gold: Bool = false,
                            height: CGFloat = 78) -> some View {
        // every sticker sits on its own WHITE tile — the cut-out's transparent
        // areas (and a stamp's perforations) read as clean white instead of
        // letting the page/shadow show through as a "hole".
        return LiveArt(collection: collection, stamp: stamp, maxPixel: 280)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background {
                if gold {
                    // gold edition: a foil mat instead of plain white
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(hex: 0xF6DE9A), Color(hex: 0xD9A93C),
                                     Color(hex: 0xF2CF74), Color(hex: 0xB8842B)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .top) {
                if gold {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(hex: 0xB8842B))
                        .padding(3)
                        .background(Circle().fill(Color(hex: 0xF6DE9A)))
                        .offset(y: -9)
                }
            }
            // a soft RECTANGULAR tile shadow (not the silhouette) for a little lift
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    // MARK: - 쓰기 (the whole album)

    /// Build a print-ready sticker-sheet PDF of this album (300-DPI
    /// re-composite, white base, bleed, kiss-cut guides) and offer to share/save.
    private func exportStickers() {
        guard plans.allows(.printSheet) else { paywallFeature = .printSheet; return }
        let ids = collection.stamps(in: album).map(\.id)
        guard !ids.isEmpty else { return }
        exporting = true
        DispatchQueue.main.async {
            let url = StickerSheet.makePDF(stampIDs: ids, store: collection, title: album)
            exporting = false
            if let url { sharePayload = SharePayload(items: [url]) }
        }
    }

    /// 이 수집함을 `.kkuk` 하나로 묶어 보낸다 (메시지 · AirDrop · 파일 앱).
    private func sendPack() {
        guard collection.count(in: album) > 0 else { return }
        exporting = true
        collection.makeArchive(album: album) { url in
            exporting = false
            if let url { sharePayload = SharePayload(items: [url]) }
        }
    }

    /// Render a square SNS card of this album (paper, title, a grid of
    /// stickers, brand) and offer to share it as an image.
    private func exportCard() {
        guard plans.allows(.albumImage) else { paywallFeature = .albumImage; return }
        let imgs = collection.stamps(in: album).map(\.image)
        guard !imgs.isEmpty else { return }
        let card = CollectionCardView(title: album,
                                      count: imgs.count,
                                      style: background,
                                      stamps: Array(imgs.prefix(12)))
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1   // the card view is already laid out at 1080pt
        guard let image = renderer.uiImage else { return }
        let caption = String(localized: "내 스티커 수집함 ‘\(album)’ #펀칭")
        sharePayload = SharePayload(items: [image, caption])
    }

    private var emptyPage: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed")
                .scaledFont(44)
                .foregroundStyle(.white.opacity(0.35))
            Text("아직 비어 있는 수집함이에요")
                .foregroundStyle(.white.opacity(0.7))
            if collection.activeAlbum == album {
                Text("여기에 담는 중 — 카메라로 스티커를 뜯어 채워보세요")
                    .scaledFont(13)
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Button { collection.setActive(album) } label: {
                    Label("여기에 담기", systemImage: "tray.and.arrow.down")
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

/// "모습" — how this capture presents itself: 우표/라이브 우표/스티커/라이브
/// 스티커. One tap re-dresses the stamp from its kept materials, anytime.
struct StampStylePicker: View {
    @ObservedObject var collection: CollectionStore
    let stampID: String
    /// dark = over the reveal's dimmed glass; light = on parchment.
    var dark = true

    var body: some View {
        let current = collection.style(for: stampID)
        let canMove = collection.canMove(stampID)
        // 이름 칸은 두 줄 중 긴 이름에 맞춘다 — 고정 폭이면 "Motio/n", "Bewegu/ng" 처럼 끊긴다.
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
            // 모양 축: 오려낸(배경 제거) ↔ 우표(톱니) — 스티커가 먼저
            axis(title: "모양",
                 a: ("오려낸", "scissors"), b: ("우표", "square.dashed"),
                 onB: !current.cutout, bEnabled: true) { wantStamp in
                set(moving: current.moving, cutout: !wantStamp)
            }
            // 움직임 축: 멈춤 ↔ 움직임
            axis(title: "움직임",
                 a: ("멈춤", "stop.circle"), b: ("움직임", "livephoto"),
                 onB: current.moving, bEnabled: canMove) { wantMoving in
                set(moving: wantMoving, cutout: current.cutout)
            }
        }
    }

    private func set(moving: Bool, cutout: Bool) {
        let s = StampStyle.make(moving: moving, cutout: cutout)
        guard s != collection.style(for: stampID) else { return }
        Haptics.tick()
        collection.applyStyle(s, for: stampID)
    }

    /// One axis as a two-segment pill: tapping the off side flips just that axis.
    @ViewBuilder
    private func axis(title: LocalizedStringKey, a: (LocalizedStringKey, String), b: (LocalizedStringKey, String),
                      onB: Bool, bEnabled: Bool, pick: @escaping (Bool) -> Void) -> some View {
        GridRow {
            Text(title)
                .scaledFont(12, weight: .bold, design: .rounded)
                .foregroundStyle(chipInk(selected: false))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 38, alignment: .leading)
            HStack(spacing: 4) {
                segment(a.0, a.1, selected: !onB, enabled: true) { pick(false) }
                segment(b.0, b.1, selected: onB, enabled: bEnabled) { pick(true) }
            }
            .padding(3)
            .background(Capsule().fill(dark ? Color.white.opacity(0.08) : Color.white.opacity(0.20)))
        }
    }

    @ViewBuilder
    private func segment(_ title: LocalizedStringKey, _ icon: String, selected: Bool,
                         enabled: Bool, tap: @escaping () -> Void) -> some View {
        Button { if enabled { tap() } } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).scaledFont(13, weight: .semibold)
                Text(title).scaledFont(13, weight: .semibold, design: .rounded)
            }
            .foregroundStyle(chipInk(selected: selected))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                if selected { Capsule().fill(chipFill(selected: true)) }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }

    private func chipInk(selected: Bool) -> Color {
        if dark { return selected ? Color(hex: 0x3A2C12) : .white.opacity(0.75) }
        return Color(hex: selected ? 0x42331E : 0x9A875E)
    }
    private func chipFill(selected: Bool) -> Color {
        if dark { return selected ? Color(hex: 0xFFD966) : .white.opacity(0.10) }
        return Color.white.opacity(selected ? 0.55 : 0.25)
    }
    private func chipStroke(selected: Bool) -> Color {
        if dark { return selected ? Color(hex: 0xFFD966) : .white.opacity(0.22) }
        return selected ? Color(hex: 0xB0863E) : Color(hex: 0xCBB585).opacity(0.6)
    }
}

/// A stamp's artwork wherever it's shown: live stamps loop their clip (decoded
/// once, optionally thumbnail-sized so a full grid of them stays light),
/// stills stay still — and the "움직임 자동 재생" setting freezes them all.
struct LiveArt: View {
    let collection: CollectionStore
    let stamp: CollectedStamp
    var maxPixel: CGFloat? = 280
    @AppStorage("liveAutoPlay") private var liveAutoPlay = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clip: (frames: [UIImage], delay: Double)?
    @State private var loadedRev = -1

    var body: some View {
        Group {
            // 동작 줄이기면 저절로 움직이지 않고 멈춘 그림으로 둔다
            if liveAutoPlay, !reduceMotion, let clip {
                LiveStampView(frames: clip.frames, delay: clip.delay)
                    .aspectRatio(stamp.image.size.width / max(stamp.image.size.height, 1),
                                 contentMode: .fit)
            } else {
                Image(uiImage: stamp.image)
                    .resizable().scaledToFit()
            }
        }
        .task(id: stamp.id) { await load() }
        // a clip can finish encoding (or the stamp can change its look) while
        // we're on screen — the store pings; reload when the revision moved
        .onReceive(collection.objectWillChange) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        guard liveAutoPlay else { return }
        let rev = collection.liveRev[stamp.id] ?? 0
        guard clip == nil || rev != loadedRev else { return }
        loadedRev = rev
        // a just-captured clip is already decoded in memory — play it instantly
        if let hot = collection.hotClips[stamp.id] {
            clip = hot
            return
        }
        guard collection.hasLive(stamp.id) else {
            clip = nil   // this look doesn't move (or the clip was stripped)
            return
        }
        let id = stamp.id, px = maxPixel, store = collection
        clip = await Task.detached(priority: .utility) {
            store.liveClip(for: id, maxPixel: px)
        }.value
    }
}

/// Ripples a pocket into place the first time it scrolls on screen — a small
/// staggered rise that makes flipping through the book feel alive.
private struct PocketAppear<Content: View>: View {
    let index: Int
    @ViewBuilder var content: Content
    @State private var shown = false

    var body: some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.92)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                guard !shown else { return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.8)
                    .delay(Double(index % 8) * 0.045)) { shown = true }
            }
    }
}

// MARK: - Diary-insert backgrounds

/// Diary / planner insert paper styles a user can pick for an album (자유롭게 꾸미기).
enum BackgroundStyle: String, CaseIterable, Identifiable {
    case cream, grid, ruled, dot, kraft, parchment, cornell, graph, mint, slate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cream:     return String(localized: "무지 크림")
        case .grid:      return String(localized: "모눈")
        case .ruled:     return String(localized: "줄노트")
        case .dot:       return String(localized: "도트")
        case .kraft:     return String(localized: "크라프트")
        case .parchment: return String(localized: "양피지")
        case .cornell:   return String(localized: "코넬")
        case .graph:     return String(localized: "그래프")
        case .mint:      return String(localized: "민트")
        case .slate:     return String(localized: "다크 그리드")
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

// MARK: - Collection store (disk-backed)

struct CollectedStamp: Identifiable {
    let id: String
    var image: UIImage         // re-rendered when a finish (ink) is applied
    var caption: String
    var album: String          // which collecting book this stamp lives in
    let createdAt: Date        // when this stamp was made
    var place: String          // where it was made (human-readable; may be empty)
}

/// How an album is dressed up (자유롭게 꾸미기): its diary paper and, once the
/// user has dragged things around, a hand-arranged order.
struct AlbumDecor: Codable, Equatable {
    var background: String? = nil   // BackgroundStyle raw value; nil = cream
    var order: [String]? = nil      // stamp ids in arranged order; nil = time order
}

/// A disk-backed stamp collection organised into albums ("수집함"). New photos
/// are filed into the *active* album, the way you'd press fresh stamps into the
/// page of a collecting book.
final class CollectionStore: ObservableObject {
    static let defaultAlbum = "내 수집함"

    @Published private(set) var stamps: [CollectedStamp] = []
    @Published private(set) var albums: [String] = []
    @Published private(set) var activeAlbum: String = ""
    /// Per-album paper + arranged order, keyed by album name.
    @Published private(set) var decor: [String: AlbumDecor] = [:]

    private let dir: URL
    private var metaURL: URL { dir.appendingPathComponent("albums.json") }
    private struct Meta: Codable {
        var albums: [String]
        var active: String
        var decor: [String: AlbumDecor]? = nil
    }
    // 컬렉션(옛 전시) 파일 — 수집함으로 한 번 옮길 때만 읽는다 (IDENTITY.md §5)
    private var legacyCollectionsURL: URL { dir.appendingPathComponent("exhibitions.json") }
    private struct LegacyPlacement: Codable { var id: String }
    private struct LegacyCollection: Codable {
        var name: String
        var stampIDs: [String]? = nil
        var slots: [String?]? = nil
        var placements: [LegacyPlacement]? = nil
        var background: String?
    }
    private struct LegacyCollectionsFile: Codable { var exhibitions: [LegacyCollection] }

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
        var filter: String? = nil   // applied finish (StampInk raw value)
        var clipDelay: Double? = nil   // per-frame delay of the motion master
        var style: String? = nil       // chosen look (StampStyle raw value)
        var outline: String? = nil     // StickerDecor.Outline raw value
        var outlineColor: UInt32? = nil
        var label: String? = nil       // 스티커에 얹은 글자
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
    /// Cheap check (no decode) for whether the full original photo was kept.
    func hasOriginal(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: originalURL(for: id).path)
    }

    // MARK: - NEW badge (seen tracking)

    /// Stamps the user has tapped in the book — their NEW badge is spent.
    @Published private(set) var seenIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "seenStampIDs") ?? [])

    func markSeen(_ id: String) {
        guard !seenIDs.contains(id) else { return }
        seenIDs.insert(id)
        // keep the list tiny: drop ids whose stamps are gone
        seenIDs.formIntersection(Set(stamps.map(\.id)))
        UserDefaults.standard.set(Array(seenIDs), forKey: "seenStampIDs")
    }

    /// NEW = younger than a day AND not yet tapped in the book.
    func isFresh(_ stamp: CollectedStamp) -> Bool {
        Date().timeIntervalSince(stamp.createdAt) < 86_400 && !seenIDs.contains(stamp.id)
    }

    // MARK: - Stamp styles (모습)

    /// Clip revision per stamp — bumped whenever a stamp's look changes, so
    /// every LiveArt on screen knows to reload its frames.
    private(set) var liveRev: [String: Int] = [:]
    private func bumpLiveRev(_ id: String) { liveRev[id, default: 0] += 1 }

    func style(for id: String) -> StampStyle {
        if let raw = existingMeta(for: id).style, let style = StampStyle(rawValue: raw) {
            return style
        }
        return hasLive(id) ? .liveStamp : .stamp
    }

    /// Records the look a stamp was born with — capture already produced the
    /// matching still/clip, so nothing needs re-deriving.
    func recordStyle(_ style: StampStyle, for id: String) {
        var meta = existingMeta(for: id)
        meta.style = style.rawValue
        writeStampMeta(meta, for: id)
    }

    /// Re-dresses a stamp in a new style, re-deriving the still and the clip
    /// from the kept original photo and motion master. Heavy parts (Vision)
    /// run off-main; the choice itself is recorded immediately.
    func applyStyle(_ style: StampStyle, for id: String) {
        guard stamps.contains(where: { $0.id == id }) else { return }
        var meta = existingMeta(for: id)
        meta.style = style.rawValue
        writeStampMeta(meta, for: id)
        // 빠르게 여러 번 바꾸면 늦게 끝난 옛 작업이 새 선택을 덮지 않도록 세대 번호로 막는다
        styleGeneration[id, default: 0] += 1
        let generation = styleGeneration[id] ?? 0
        restyling.insert(id)
        objectWillChange.send()   // pickers highlight the choice right away
        // 색감 · 테두리 · 글자 — 모양을 바꿔도 따라온다
        let ink = meta.filter.flatMap(StampInk.init(rawValue:))
        let decor = stickerDecor(for: id)
        let mask = customMask(for: id)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // RESCUE FIRST: stamps from before the master system only carry
            // their motion inside the live clip — back it up as the master
            // before anything below could delete it, so motion is never lost
            let material = self.motionMaterial(for: id)
            // --- the still --- (one canonical path: shape axis can't flip)
            let still: UIImage? = self.printStamp(for: id, longSidePx: PhotoShot.stickerSide, clipToShape: false)
                .map { Self.finishLook(Self.stillLook($0, style: style, mask: mask), ink: ink, decor: decor) }
            // --- the clip --- (only moving looks; never frozen, never wrong shape)
            var apng: Data?
            var lean: Data?
            var hot: (frames: [UIImage], delay: Double)?
            if style.moving, let master = material {
                let styled = Self.clipLook(master.frames, style: style, mask: mask)
                    .map { Self.finishLook($0, ink: ink, decor: decor) }
                if styled.count > 1 {
                    hot = (styled, master.delay)
                    apng = APNG.encode(styled, delay: master.delay)
                    lean = APNG.encodeForMessages(styled, delay: master.delay)
                }
            }
            let newStill = still
            let newAPNG = apng, newLean = lean, newHot = hot
            await MainActor.run {
                guard self.styleGeneration[id] == generation else { return }   // 더 새 선택이 진행 중
                self.restyling.remove(id)
                if let newStill { self.updateImage(newStill, for: id) }
                if let newAPNG {
                    self.setLive(newAPNG, sticker: newLean, for: id)
                    if let newHot { self.setHotClip(newHot.frames, delay: newHot.delay, for: id) }
                } else {
                    self.removeLive(for: id)
                }
                self.bumpLiveRev(id)
                self.objectWillChange.send()
            }
        }
    }

    /// 모양을 다시 만드는 중인 스티커 — 상세 화면이 '만드는 중'을 보여 준다.
    @Published private(set) var restyling: Set<String> = []
    private var styleGeneration: [String: Int] = [:]

    // MARK: - 테두리 · 글자 (StickerDecor)

    func stickerDecor(for id: String) -> StickerDecor {
        let meta = existingMeta(for: id)
        return StickerDecor(outline: meta.outline.flatMap(StickerDecor.Outline.init(rawValue:)) ?? .none,
                            color: meta.outlineColor ?? 0xFFFFFF,
                            label: meta.label ?? "")
    }

    /// 테두리 · 글자를 바꾸고 원본에서 다시 만든다 (움직임 프레임까지).
    func setStickerDecor(_ decor: StickerDecor, for id: String) {
        guard decor != stickerDecor(for: id) else { return }
        var meta = existingMeta(for: id)
        meta.outline = decor.outline == .none ? nil : decor.outline.rawValue
        meta.outlineColor = decor.color == 0xFFFFFF ? nil : decor.color
        meta.label = decor.trimmedLabel.isEmpty ? nil : decor.trimmedLabel
        writeStampMeta(meta, for: id)
        applyStyle(style(for: id), for: id)
    }

    /// 색감을 바꾸고 원본에서 다시 만든다 — 모양 · 테두리 · 움직임이 함께 따라온다.
    func applyFinish(_ ink: StampInk, for id: String) {
        setFinish(ink == .original ? nil : ink.rawValue, for: id)
        applyStyle(style(for: id), for: id)
    }

    /// 모양을 만든 뒤 마지막 손질: 색감 → 테두리 · 글자. 그림이 만들어지는 모든 길이 여기를 지난다.
    static func finishLook(_ image: UIImage, ink: StampInk?, decor: StickerDecor) -> UIImage {
        var out = image
        if let ink, ink != .original { out = ink.apply(to: out) }
        return decor.apply(to: out)
    }

    private func existingMeta(for id: String) -> StampMeta {
        if let data = try? Data(contentsOf: stampMetaURL(for: id)),
           let meta = try? JSONDecoder().decode(StampMeta.self, from: data) {
            return meta
        }
        let created = stamps.first { $0.id == id }?.createdAt ?? Date()
        return StampMeta(createdAt: created, latitude: nil, longitude: nil, place: nil)
    }

    /// An image clipped to the perforated stamp outline (in its own rect).
    static func stampShaped(_ image: UIImage) -> UIImage {
        let size = image.size
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            ctx.cgContext.addPath(
                stampBezierPath(in: CGRect(origin: .zero, size: size)).cgPath)
            ctx.cgContext.clip()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Canonical look derivation (the ONLY place a look is built)
    //
    // Both axes are honoured no matter what, so the result can never disagree
    // with the chosen style:
    //   • shape   — `.cutout` styles are background-removed (a sticker) and NEVER
    //     get the perforation; non-cutout styles ALWAYS get the perforation.
    //     A sticker with no detectable subject falls back to the plain crop
    //     (still no teeth) — it stays a sticker, it never becomes a stamp.
    //   • motion  — a moving look's clip is always ≥2 frames (falls back to the
    //     raw frames), so a "moving" style is never delivered frozen.

    /// The still image for `style`, derived from a plain rectangular crop.
    /// `mask` 는 손으로 정한 모양(둘러 그린 테두리 · 지우개로 손본 것) — 있으면 자동 대신 그 모양대로 오린다.
    static func stillLook(_ rectCrop: UIImage, style: StampStyle, mask: UIImage? = nil) -> UIImage {
        if style.cutout {
            if let mask, let cut = SubjectLift.cut(rectCrop, mask: mask, trim: true) { return cut }
            return SubjectLift.cutout(from: rectCrop) ?? rectCrop   // sticker: never perforated
        }
        return stampShaped(rectCrop)                                 // stamp: always perforated
    }

    /// The clip frames for a moving `style`, from plain rectangular frames.
    /// Returns frames unchanged for a still style (caller shouldn't store them).
    static func clipLook(_ rectFrames: [UIImage], style: StampStyle, mask: UIImage? = nil) -> [UIImage] {
        guard rectFrames.count > 1 else { return rectFrames }
        if style.cutout, let mask {
            // 손으로 정한 모양은 프레임마다 같다 — 테두리는 그대로, 안의 장면만 움직인다
            let cut = rectFrames.compactMap { SubjectLift.cut($0, mask: mask, trim: false) }
            return cut.count > 1 ? cut : rectFrames
        }
        if style.cutout {
            // PER-FRAME masks: one shared mask (from the middle frame) ghosts —
            // when the subject moves, the stale silhouette keeps the background
            // where the subject used to be, covering it. Cutting each frame with
            // its own mask keeps the cutout aligned. `apply` returns full-extent
            // frames, so they stay the same size (no dropped/jittering frames).
            let cut = rectFrames.compactMap { frame -> UIImage? in
                guard let m = SubjectLift.subjectMask(from: frame) else { return nil }
                return SubjectLift.apply(mask: m, to: frame)
            }
            return cut.count > 1 ? cut : rectFrames     // sticker: cutout, never perforated
        }
        return rectFrames.map { stampShaped($0) }            // stamp: every frame perforated
    }

    // MARK: - Motion master (style-agnostic raw frames)

    private func framesDir(for id: String) -> URL {
        dir.appendingPathComponent("\(id).frames", isDirectory: true)
    }
    func hasMotionMaster(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: framesDir(for: id).path)
    }

    /// Keeps the plain window-cropped frames forever, so any style can be
    /// derived later. JPEG ~85%: a clip costs roughly a megabyte.
    func setMotionMaster(_ frames: [UIImage], delay: Double, for id: String) {
        guard frames.count > 1 else { return }
        let d = framesDir(for: id)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (i, f) in frames.enumerated() {
            if let data = f.jpegData(compressionQuality: 0.85) {
                try? data.write(to: d.appendingPathComponent(String(format: "%02d.jpg", i)))
            }
        }
        var meta = existingMeta(for: id)
        meta.clipDelay = delay
        writeStampMeta(meta, for: id)
    }

    func motionMaster(for id: String) -> (frames: [UIImage], delay: Double)? {
        let d = framesDir(for: id)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: d.path),
              !names.isEmpty else { return nil }
        let frames = names.sorted()
            .compactMap { UIImage(contentsOfFile: d.appendingPathComponent($0).path) }
        guard frames.count > 1 else { return nil }
        let delay = existingMeta(for: id).clipDelay ?? 0.12
        return (frames, delay)
    }

    /// Motion material for re-styling: the kept master, or — for stamps from
    /// before the master system — the decoded live clip, which is immediately
    /// backed up AS the master so it can never be lost to a style switch.
    private func motionMaterial(for id: String) -> (frames: [UIImage], delay: Double)? {
        if let master = motionMaster(for: id) { return master }
        guard let clip = liveClip(for: id) else { return nil }
        setMotionMaster(clip.frames, delay: clip.delay, for: id)
        return clip
    }

    /// Whether this stamp has any motion source at all (master or clip) —
    /// i.e. whether the live looks are available to it.
    func canMove(_ id: String) -> Bool {
        hasMotionMaster(id) || hasLive(id) || hotClips[id] != nil
    }

    /// Stamps whose recorded style claims motion (라이브 우표/스티커) but have no
    /// playable clip — i.e. "moving" that doesn't actually move. The checkup tool
    /// lists these so the user can fix each: rebuild the motion (if a master
    /// exists) or switch it to the matching still style.
    func brokenMovingStamps() -> [CollectedStamp] {
        stamps.filter { style(for: $0.id).moving && !isPlayablyLive($0.id) }
    }

    /// Fixes every "moving" stamp that doesn't actually move, without asking:
    /// rebuild the clip when motion was kept, otherwise switch it honestly to
    /// the matching still look. Nothing is deleted. Run once at launch — not
    /// mid-capture, when a fresh clip may still be encoding.
    func repairBrokenMotion() {
        for stamp in brokenMovingStamps() {
            let style = style(for: stamp.id)
            applyStyle(canMove(stamp.id) ? style : StampStyle.make(moving: false, cutout: style.cutout),
                       for: stamp.id)
        }
    }

    // cheap per-stamp validity cache, keyed by the clip revision
    private var playableCache: [String: (rev: Int, ok: Bool)] = [:]

    /// Whether the current look ACTUALLY animates: a live file must exist and
    /// hold 2+ frames — a corrupt or single-frame clip is just a still wearing
    /// a costume, and badges must not lie about it. Header-only parse, cached.
    func isPlayablyLive(_ id: String) -> Bool {
        if let hot = hotClips[id] { return hot.frames.count > 1 }
        let rev = liveRev[id] ?? 0
        if let cached = playableCache[id], cached.rev == rev { return cached.ok }
        var ok = false
        if let data = try? Data(contentsOf: liveURL(for: id)),
           let src = CGImageSourceCreateWithData(data as CFData, nil) {
            ok = CGImageSourceGetCount(src) > 1
        }
        playableCache[id] = (rev, ok)
        return ok
    }

    /// Strips the moving look: the in-app clip and hot frames go away and the
    /// shared sticker falls back to the (high-res) still.
    func removeLive(for id: String) {
        try? FileManager.default.removeItem(at: liveURL(for: id))
        hotClips.removeValue(forKey: id)
        bumpLiveRev(id)
        // Drop the canonical Messages sticker so syncStickers re-exports it as a
        // still in place of the (now-removed) animated clip.
        invalidateSharedSticker(for: id)
        syncStickers()
    }

    /// Deletes the canonical Messages sticker file (`<id>.<scheme>.png` in the
    /// App Group) so the next syncStickers() re-exports it — picking up a clip
    /// that was just attached or removed. Without this, syncStickers's
    /// fileExists guard keeps serving whatever was written first (typically the
    /// still that landed before the async clip finished encoding).
    private func invalidateSharedSticker(for id: String) {
        guard let base = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: Self.stickerGroupID) else { return }
        // Remove both possible formats — a stamp may have just flipped between
        // still (.png) and moving (.gif), so clear whichever is on disk.
        for ext in ["png", "gif"] {
            let url = base.appendingPathComponent("Stickers/\(id).\(Self.stickerScheme).\(ext)")
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Live stamps (a short APNG clip that makes the stamp move)

    private func liveURL(for id: String) -> URL {
        dir.appendingPathComponent("\(id).live.png")
    }
    func hasLive(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: liveURL(for: id).path)
    }
    /// The freshest clip's decoded frames, published the instant the burst is
    /// cropped — before the APNG has even finished encoding — so the reveal
    /// card starts moving right away. Holds only the latest capture; disk is
    /// the durable copy everyone else reads.
    private(set) var hotClips: [String: (frames: [UIImage], delay: Double)] = [:]
    func setHotClip(_ frames: [UIImage], delay: Double, for id: String) {
        hotClips = [id: (frames, delay)]
        objectWillChange.send()
    }

    /// Attach the animated clip to a stamp; `sticker` is the lean (≤500 KB)
    /// re-encode for the iMessage tray — Messages animates it in place of the
    /// still. When nil (couldn't fit the budget), the still sticker stays.
    func setLive(_ apng: Data, sticker: Data?, for id: String) {
        guard stamps.contains(where: { $0.id == id }) else { return }
        try? apng.write(to: liveURL(for: id))
        bumpLiveRev(id)
        // The Messages sticker for this stamp was almost always written as a
        // STILL when it was filed (add() syncs immediately, but the clip is
        // encoded ~1.2s later and only attaches here). Drop that stale file and
        // re-sync so the tray regenerates it from the now-attached clip as an
        // animated APNG — otherwise it never moves in Messages. `sticker` (the
        // pre-encoded lean clip) is intentionally not written directly: the
        // canonical export wraps frames on a uniform canvas for MSSticker's
        // size requirement, so we let syncStickers produce that version.
        invalidateSharedSticker(for: id)
        syncStickers()
        objectWillChange.send()
    }
    /// Decoded frames (with per-frame delay) for in-app playback, or nil.
    /// `maxPixel` decodes thumbnail-sized frames — use it anywhere many clips
    /// play at once (the album grid) so memory stays sane.
    func liveClip(for id: String, maxPixel: CGFloat? = nil) -> (frames: [UIImage], delay: Double)? {
        guard let data = try? Data(contentsOf: liveURL(for: id)),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 1 else { return nil }
        var frames: [UIImage] = []
        var delay = 0.12
        for i in 0..<n {
            // decode the full frame, then downscale by hand — the thumbnail
            // API can't be trusted to honour the frame index on animated PNGs
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            if i == 0,
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
               let d = png[kCGImagePropertyAPNGDelayTime] as? Double, d > 0 {
                delay = d
            }
            let full = UIImage(cgImage: cg)
            if let maxPixel,
               max(full.size.width, full.size.height) > maxPixel {
                let s = maxPixel / max(full.size.width, full.size.height)
                let size = CGSize(width: (full.size.width * s).rounded(),
                                  height: (full.size.height * s).rounded())
                let fmt = UIGraphicsImageRendererFormat()
                fmt.scale = 1
                fmt.opaque = false
                frames.append(UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
                    full.draw(in: CGRect(origin: .zero, size: size))
                })
            } else {
                frames.append(full)
            }
        }
        return frames.count > 1 ? (frames, delay) : nil
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
    /// High-res render for export / copy / share: a perforated 우표 or a
    /// background-removed 스티커, matching the stamp's chosen style. Heavy
    /// (re-crops the original, runs Vision for cutouts) — call off the main thread.
    func exportImage(for id: String, longSidePx: CGFloat = 2048) -> UIImage? {
        let style = self.style(for: id)
        var image = printStamp(for: id, longSidePx: longSidePx,
                               clipToShape: style == .stamp || style == .liveStamp)
        if style == .sticker || style == .liveSticker,
           let base = printStamp(for: id, longSidePx: longSidePx, clipToShape: false),
           let cut = customMask(for: id).flatMap({ SubjectLift.cut(base, mask: $0, trim: true) })
                ?? SubjectLift.cutout(from: base) {
            image = cut
        }
        guard let image else { return stamps.first { $0.id == id }?.image }
        let meta = existingMeta(for: id)
        return Self.finishLook(image, ink: meta.filter.flatMap(StampInk.init(rawValue:)),
                               decor: stickerDecor(for: id))
    }

    /// What leaves the app on copy / share: a moving sticker goes out as an
    /// animated GIF (it keeps moving in Messages, Notes, …), a still one as a
    /// high-res transparent PNG. The heavy part runs off-main; `done` lands
    /// on main with nil if nothing could be made.
    func makeExport(for id: String, done: @escaping (StickerExport?) -> Void) {
        guard stamps.contains(where: { $0.id == id }) else { done(nil); return }
        let moving = style(for: id).moving && isPlayablyLive(id)
        DispatchQueue.global(qos: .userInitiated).async {
            var export: StickerExport?
            if moving, let clip = self.liveClip(for: id),
               let gif = AnimatedGIF.encode(clip.frames, delay: clip.delay) {
                export = StickerExport(data: gif, ext: "gif", pasteboardType: "com.compuserve.gif", id: id)
            } else if let png = self.exportImage(for: id)?.pngData() {
                export = StickerExport(data: png, ext: "png", pasteboardType: "public.png", id: id)
            }
            DispatchQueue.main.async { done(export) }
        }
    }

    func printStamp(for id: String, longSidePx: CGFloat,
                    clipToShape: Bool = true) -> UIImage? {
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
        let long = min(longSidePx, max(src.width, src.height))    // 원본보다 크게 늘리지 않는다
        let outSize = aspect >= 1
            ? CGSize(width: long, height: (long / aspect).rounded())
            : CGSize(width: (long * aspect).rounded(), height: long)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: outSize, format: fmt).image { ctx in
            let c = ctx.cgContext
            let r = CGRect(origin: .zero, size: outSize)
            if clipToShape {
                c.addPath(stampBezierPath(in: r).cgPath)
                c.clip()
            }
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
        // `.first ?? temporaryDirectory` — never force-index [0]: in the Xcode
        // Preview/build sandbox the documents-directory list can be empty, and
        // a trap there surfaces as "invalid reuse after initialization failure".
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        dir = directory ?? base.appendingPathComponent("Collection", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadStamps()
        loadMeta()
        migrateCollectionsIntoAlbums()
        reconcile()          // saves meta → syncs stickers
        refreshCutoutsOnce()
    }

    /// One-time: re-derive existing sticker cutouts so they pick up the new
    /// crisp, halo-free edge (older builds baked a pale matte outline). Skipped
    /// for good after it runs once.
    private func refreshCutoutsOnce() {
        let key = "cutoutCrispV2"   // v2: crisp edges + per-frame clip masks (no ghost)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let cutoutIDs = stamps.filter { style(for: $0.id).cutout }.map(\.id)
        for id in cutoutIDs { applyStyle(style(for: id), for: id) }   // re-derives off-main
    }

    /// App Group shared with the iMessage sticker extension, so collected stamps
    /// show up as real iMessage stickers. (No-op until the App Group is enabled.)
    static let stickerGroupID = "group.com.devkoan.StampCamera"
    /// Bumped whenever the sticker LOOK or FORMAT changes — it's part of every
    /// sticker's filename, so Messages never serves a stale cached image at the
    /// same URL. (s9: moving stickers ship as GIF — see syncStickers.)
    static let stickerScheme = "s9"
    /// Serial queue so rapid syncs (capture → setLive → applyStyle …) run to
    /// completion one at a time. On a concurrent queue their write/cleanup
    /// passes interleave and can leave a stale still next to a fresh clip.
    private static let stickerSyncQueue = DispatchQueue(label: "com.devkoan.StampCamera.stickerSync", qos: .utility)
    /// Messages-tray sticker file for a stamp. Moving stickers are GIF, stills
    /// are PNG — see `syncStickers` for why.
    private func stickerFilename(for id: String) -> String {
        "\(id).\(Self.stickerScheme).\(isPlayablyLive(id) ? "gif" : "png")"
    }
    func syncStickers() {
        guard let base = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: Self.stickerGroupID) else { return }
        // Decide each stamp's format up front (cheap header-only liveness check)
        // so the manifest filenames match the files we actually write below.
        let snapshot: [(id: String, image: UIImage, live: Bool)] =
            stamps.map { ($0.id, $0.image, isPlayablyLive($0.id)) }
        let nameByID = Dictionary(uniqueKeysWithValues:
            snapshot.map { ($0.id, "\($0.id).\(Self.stickerScheme).\($0.live ? "gif" : "png")") })
        // 수집함 → 스티커 팩: 이름과 파일 목록(수집함 순서)을 함께 내보내
        // 메시지 서랍·키보드가 수집함별로 보여줄 수 있게 한다
        let packs: [[String: Any]] = albums.compactMap { album in
            let files = stamps(in: album).compactMap { nameByID[$0.id] }
            return files.isEmpty ? nil : ["name": album, "files": files]
        }
        // 찾을 말: 파일 이름 → 한 마디 · 장소 · 수집함 · 글자 · 날짜 (메시지 · 키보드의 찾기)
        let words = Dictionary(uniqueKeysWithValues:
            searchWords.compactMap { id, text in nameByID[id].map { ($0, text) } })
        Self.stickerSyncQueue.async { [weak self] in
            guard let self else { return }
            let dir = base.appendingPathComponent("Stickers", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: ["collections": packs, "words": words]) {
                try? data.write(to: dir.appendingPathComponent("collections.json"))
            }

            // one-time migration: earlier builds composited stickers onto a
            // WHITE square (it showed as a box in dark mode) — wipe once so
            // everything regenerates onto a transparent canvas.
            let marker = dir.appendingPathComponent(".v7-clearcanvas")
            if !FileManager.default.fileExists(atPath: marker.path) {
                for f in (try? FileManager.default.contentsOfDirectory(at: dir,
                            includingPropertiesForKeys: nil)) ?? []
                    where ["png", "gif"].contains(f.pathExtension.lowercased()) {
                    try? FileManager.default.removeItem(at: f)
                }
                FileManager.default.createFile(atPath: marker.path, contents: nil)
            }

            let wanted = Set(snapshot.map { "\($0.id).\(Self.stickerScheme).\($0.live ? "gif" : "png")" })
            for item in snapshot {
                let url = dir.appendingPathComponent("\(item.id).\(Self.stickerScheme).\(item.live ? "gif" : "png")")
                guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                // Every sticker is composited onto a uniform TRANSPARENT square
                // so it ALWAYS meets MSSticker's 100–618pt size (tight cut-outs
                // were being rejected and vanishing from the tray) while keeping
                // its background clear in both light and dark mode.
                //
                // Moving stickers ship as animated GIF, NOT APNG: iMessage only
                // animates a dynamically-loaded sticker in the conversation
                // transcript when it's a GIF — an APNG animates in the tray but
                // freezes to its first frame once peeled/sent. Stills stay PNG
                // (full 8-bit alpha, sharper edges than GIF's 1-bit key).
                if item.live, let clip = self.liveClip(for: item.id) {
                    let framesOnCanvas = clip.frames.map { Self.stickerCanvas($0, side: 512) }
                    if let gif = AnimatedGIF.encodeForMessages(framesOnCanvas, delay: clip.delay) {
                        try? gif.write(to: url)
                        continue
                    }
                    // GIF couldn't be built — fall back to a still so the stamp
                    // still appears. Write it under the same (.gif) URL the
                    // manifest points at: MSSticker sniffs content, so a PNG
                    // there shows static but survives the cleanup pass.
                    if let data = self.stickerStillData(id: item.id, fallback: item.image) {
                        try? data.write(to: url)
                    }
                    continue
                }
                if let data = self.stickerStillData(id: item.id, fallback: item.image) {
                    try? data.write(to: url)
                }
            }
            // drop stickers whose stamp is gone, plus any stale format/scheme
            // (e.g. a stamp that switched still↔moving) — keep the marker.
            for f in (try? FileManager.default.contentsOfDirectory(at: dir,
                        includingPropertiesForKeys: nil)) ?? []
                where ["png", "gif"].contains(f.pathExtension.lowercased())
                    && !wanted.contains(f.lastPathComponent) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    /// A still sticker for Messages: the style-correct art (스티커=cut-out,
    /// 우표=perforated) composited onto a uniform transparent square — so it
    /// always fits MSSticker's 100–618pt size and shows up in the tray.
    private func stickerStillData(id: String, fallback: UIImage) -> Data? {
        let art = exportImage(for: id, longSidePx: 1024) ?? fallback
        for side: CGFloat in [512, 408, 320] {
            if let data = Self.stickerCanvas(art, side: side).pngData(), data.count <= 480_000 {
                return data
            }
        }
        return Self.stickerCanvas(art, side: 320).pngData()
    }

    /// Centers `art` (with a small inset) on a TRANSPARENT `side`×`side`
    /// canvas — a clean, uniformly-sized sticker base that meets MSSticker's
    /// 100–618pt size requirement while keeping the cut-out background clear
    /// (so it never shows a white box, in light or dark mode).
    static func stickerCanvas(_ art: UIImage, side: CGFloat) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
            let inset = side * 0.08
            let box = CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
            let s = min(box.width / max(art.size.width, 1), box.height / max(art.size.height, 1))
            let w = art.size.width * s, h = art.size.height * s
            art.draw(in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
        }
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
            // Real stamps are "<ms>.png"; the live clip is filed alongside as
            // "<ms>.png.live.png" (also a .png). Exclude that sidecar, or it
            // gets read as a phantom second (still) stamp next to the real one.
            .filter { $0.pathExtension == "png" && !$0.lastPathComponent.hasSuffix(".live.png") }
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
        guard let data = try? Data(contentsOf: metaURL) else { return }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
            // 못 읽은 앨범 정보를 옆에 남긴다 — 다음 저장이 덮어써도 되찾을 수 있게
            try? FileManager.default.copyItem(at: metaURL, to: metaURL.appendingPathExtension("unreadable"))
            return
        }
        albums = meta.albums
        activeAlbum = meta.active
        decor = meta.decor ?? [:]
    }
    /// Every album change lands here, so the Messages / keyboard packs (one per
    /// album) follow along.
    private func saveMeta() {
        defer { syncStickers() }
        if let data = try? JSONEncoder().encode(Meta(albums: albums, active: activeAlbum,
                                                     decor: decor.isEmpty ? nil : decor)) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    /// One-time: every 컬렉션 becomes a 수집함 of the same name (IDENTITY.md §5).
    /// Its stamps MOVE there — the user hand-picked them, so that home wins —
    /// keeping the collection's paper and order. A name already taken by an
    /// album gets " (컬렉션)". The old file is renamed, not deleted, so the
    /// move can be undone by hand.
    private func migrateCollectionsIntoAlbums() {
        guard let data = try? Data(contentsOf: legacyCollectionsURL) else { return }
        let file = try? JSONDecoder().decode(LegacyCollectionsFile.self, from: data)
        let live = Set(stamps.map(\.id))
        var taken = Set<String>()                    // one stamp, one new home
        for rec in file?.exhibitions ?? [] {
            let base = rec.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { continue }
            let listed = rec.placements?.map(\.id)
                ?? rec.slots?.compactMap { $0 }
                ?? rec.stampIDs ?? []
            let ids = listed.filter { live.contains($0) && taken.insert($0).inserted }
            var name = base
            if albums.contains(name) || stamps.contains(where: { $0.album == name }) {
                name = "\(base) (컬렉션)"
                var n = 2
                while albums.contains(name) { name = "\(base) (컬렉션 \(n))"; n += 1 }
            }
            albums.append(name)
            for id in ids { fileStamp(id, into: name) }
            let bg = rec.background.flatMap { $0 == BackgroundStyle.cream.rawValue ? nil : $0 }
            if bg != nil || !ids.isEmpty {
                decor[name] = AlbumDecor(background: bg, order: ids.isEmpty ? nil : ids)
            }
        }
        let done = dir.appendingPathComponent("exhibitions.migrated.json")
        try? FileManager.default.removeItem(at: done)
        try? FileManager.default.moveItem(at: legacyCollectionsURL, to: done)
        saveMeta()
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

    /// Stamps in an album: hand-arranged ones first in their arranged order,
    /// then the rest oldest → newest (so a fresh capture lands at the end).
    func stamps(in album: String) -> [CollectedStamp] {
        let members = stamps.filter { $0.album == album }
        guard let order = decor[album]?.order, !order.isEmpty else { return members }
        var rank: [String: Int] = [:]
        for (i, id) in order.enumerated() where rank[id] == nil { rank[id] = i }
        return members.enumerated().sorted { l, r in
            switch (rank[l.element.id], rank[r.element.id]) {
            case let (a?, b?): return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return l.offset < r.offset
            }
        }.map(\.element)
    }
    func count(in album: String) -> Int {
        stamps.reduce(0) { $0 + ($1.album == album ? 1 : 0) }
    }


    // MARK: - Stamps

    @discardableResult
    func add(_ image: UIImage, location: CLLocation? = nil,
             original: UIImage? = nil, sharingOriginalOf sibling: String? = nil,
             cropNorm: CGRect? = nil, mirrored: Bool = false) -> String {
        let now = Date()
        // 이름은 만든 때(ms). 사진 한 장에서 여러 개를 잇달아 담아도 겹치지 않게 한다
        var stampMS = Int(now.timeIntervalSince1970 * 1000)
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(stampMS).png").path) { stampMS += 1 }
        let name = "\(stampMS).png"
        let url = dir.appendingPathComponent(name)
        if let data = image.pngData() { try? data.write(to: url) }
        // keep the full pre-crop photo so the border can be customised later
        if let original, let data = original.jpegData(compressionQuality: 0.9) {
            try? data.write(to: originalURL(for: name))
        } else if let sibling {
            // 같은 사진에서 나온 스티커는 원본 한 장을 나눠 쓴다 (자리를 더 차지하지 않는다)
            try? FileManager.default.linkItem(at: originalURL(for: sibling), to: originalURL(for: name))
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
                                 mirrored: (original != nil || sibling != nil) ? mirrored : nil), for: name)
        stamps.append(CollectedStamp(id: name, image: image, caption: "", album: album,
                                     createdAt: now, place: ""))
        syncStickers()
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
        syncStickers()   // 메시지 · 키보드에서 장소로 찾을 수 있게
    }

    func setCaption(_ text: String, for id: String) {
        guard let idx = stamps.firstIndex(where: { $0.id == id }), stamps[idx].caption != text else { return }
        stamps[idx].caption = text
        try? text.write(to: captionURL(for: id), atomically: true, encoding: .utf8)
        syncStickers()   // 메시지 · 키보드에서 한 마디로 찾을 수 있게
    }

    /// Swap the rendered stamp PNG (after applying a finish), keeping the
    /// caption, place and original photo intact.
    func updateImage(_ image: UIImage, for id: String) {
        guard let idx = stamps.firstIndex(where: { $0.id == id }),
              let data = image.pngData() else { return }
        try? data.write(to: dir.appendingPathComponent(id))
        stamps[idx].image = image
        // The stamp's rendered art changed (finish/ink, border, restyle) — drop
        // the stale Messages sticker and re-export it, or the tray keeps the old
        // look (syncStickers's fileExists guard never overwrites otherwise).
        invalidateSharedSticker(for: id)
        syncStickers()
    }

    /// The decorating finish currently on a stamp (StampInk raw value), if any.
    func finish(for id: String) -> String? {
        guard let data = try? Data(contentsOf: stampMetaURL(for: id)),
              let meta = try? JSONDecoder().decode(StampMeta.self, from: data) else { return nil }
        return meta.filter
    }

    func setFinish(_ name: String?, for id: String) {
        guard let idx = stamps.firstIndex(where: { $0.id == id }) else { return }
        var meta = StampMeta(createdAt: stamps[idx].createdAt,
                             latitude: nil, longitude: nil, place: nil)
        if let data = try? Data(contentsOf: stampMetaURL(for: id)),
           let existing = try? JSONDecoder().decode(StampMeta.self, from: data) {
            meta = existing
        }
        meta.filter = name
        writeStampMeta(meta, for: id)
    }

    func move(_ id: String, to album: String) {
        fileStamp(id, into: album)
        if !albums.contains(album) { albums.append(album) }
        saveMeta()
    }

    /// Re-homes a stamp (the `.grp` sidecar) without saving meta.
    private func fileStamp(_ id: String, into album: String) {
        guard let idx = stamps.firstIndex(where: { $0.id == id }) else { return }
        stamps[idx].album = album
        try? album.write(to: albumURL(for: id), atomically: true, encoding: .utf8)
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id))
        try? FileManager.default.removeItem(at: captionURL(for: id))
        try? FileManager.default.removeItem(at: albumURL(for: id))
        try? FileManager.default.removeItem(at: stampMetaURL(for: id))
        try? FileManager.default.removeItem(at: originalURL(for: id))
        try? FileManager.default.removeItem(at: liveURL(for: id))
        try? FileManager.default.removeItem(at: framesDir(for: id))
        try? FileManager.default.removeItem(at: cutURL(for: id))
        hotClips.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: liveURL(for: id))
        stamps.removeAll { $0.id == id }
        syncStickers()
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
        decor[n] = decor.removeValue(forKey: old)
        saveMeta()
    }

    /// Deletes the album and every stamp whose home is it. Always keeps at
    /// least one album.
    func deleteAlbum(_ name: String) {
        guard albums.count > 1, albums.contains(name) else { return }
        for s in stamps.filter({ $0.album == name }) { delete(s.id) }
        albums.removeAll { $0 == name }
        decor.removeValue(forKey: name)
        if activeAlbum == name { activeAlbum = albums[0] }
        saveMeta()
    }

    // MARK: - 손으로 정한 모양 (둘러 그린 테두리 · 지우개)

    private func cutURL(for id: String) -> URL { dir.appendingPathComponent("\(id).cut") }

    /// 손으로 정한 스티커 모양(불투명한 곳만 남는 그림). 없으면 자동으로 오려낸다.
    func customMask(for id: String) -> UIImage? {
        // 파일이 있을 때만 읽는다 — UIImage(contentsOfFile:) 은 없는 이름을 비슷한 이름(스티커 그림)으로 찾아 준다
        guard let data = try? Data(contentsOf: cutURL(for: id)) else { return nil }
        return UIImage(data: data)
    }

    /// 모양을 바꾸고 스티커를 다시 만든다. nil 이면 자동으로 오려낸 모양으로 되돌린다.
    func setCustomMask(_ mask: UIImage?, for id: String) {
        if let data = mask?.pngData() {
            try? data.write(to: cutURL(for: id), options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: cutURL(for: id))
        }
        let now = style(for: id)
        applyStyle(mask != nil ? .make(moving: now.moving, cutout: true) : now, for: id)
    }

    /// 손보기 화면의 재료: 오려내기 전 네모 조각과 지금 모양. Vision 을 쓰니 뒤에서 부른다.
    func edgeMaterial(for id: String) -> EdgeMaterial? {
        guard let photo = printStamp(for: id, longSidePx: PhotoShot.stickerSide, clipToShape: false) else { return nil }
        return EdgeMaterial(photo: photo, mask: customMask(for: id) ?? SubjectLift.autoMask(of: photo))
    }

    // MARK: - 사진 한 장에서 스티커 여러 개

    /// 사진(`shot`)에서 고른 후보들을 스티커로 담는다. 모양은 `style` 을 따르되
    /// "사진 그대로"는 우표 모양, 손으로 그린 것은 그린 모양대로다.
    /// `done` 은 멈춘 스티커가 모두 담긴 뒤 main 에서 불린다 — 움직임은 그 뒤에 잘라 붙인다.
    func addStickers(from shot: PhotoShot, picks: [StickerCandidate], style: StampStyle,
                     motion: (frames: [UIImage], seconds: Double)?, location: CLLocation? = nil,
                     done: @escaping (_ ids: [String], _ fellBack: Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var made: [(id: String, win: CGRect, mask: UIImage?, style: StampStyle)] = []
            var fellBack = false
            for pick in picks {
                let win = CGRect(x: pick.window.minX * shot.size.width, y: pick.window.minY * shot.size.height,
                                 width: pick.window.width * shot.size.width,
                                 height: pick.window.height * shot.size.height)
                // 원본 해상도로 자른다 (화면 크기로 자르면 작은 대상이 흐려진다)
                guard let base = shot.crop(pick.window) else { continue }
                var look = style
                if pick.kind == .photo { look = .make(moving: style.moving, cutout: false) }
                if pick.kind == .drawn { look = .make(moving: style.moving, cutout: true) }
                // 직접 그린 것: 그 안의 대상을 또렷한 원본에서 다시 찾아 딴다
                let mask = pick.kind == .drawn ? StickerMask.refine(pick.outlineInWindow, in: base.image) : nil
                let cut: UIImage? = look.cutout
                    ? (mask.flatMap { SubjectLift.cut(base.image, mask: $0, trim: true) }
                       ?? SubjectLift.cutout(from: base.image))
                    : nil
                let still: UIImage
                if let cut {
                    still = cut
                } else {
                    // 오려낼 대상이 없다 → 우표 모양으로
                    if look.cutout { fellBack = true }
                    look = .make(moving: look.moving, cutout: false)
                    still = Self.stampShaped(base.image)
                }
                let sibling = made.first?.id
                let kept = look.cutout ? mask : nil
                let id: String = DispatchQueue.main.sync {
                    let id = self.add(still, location: location,
                                      original: sibling == nil ? shot.raw : nil, sharingOriginalOf: sibling,
                                      cropNorm: base.cropNorm, mirrored: shot.mirrored)
                    self.recordStyle(look, for: id)
                    if let data = kept?.pngData() { try? data.write(to: self.cutURL(for: id), options: .atomic) }
                    return id
                }
                made.append((id, win, kept, look))
            }
            let ids = made.map(\.id)
            DispatchQueue.main.async { done(ids, fellBack) }

            // 움직임: 스티커마다 같은 자리로 프레임을 잘라 원본(마스터)을 남기고, 움직이는 모양이면 클립을 만든다
            guard let motion, motion.frames.count > 1 else { return }
            let delay = max(0.06, motion.seconds / Double(motion.frames.count - 1))
            for item in made {
                let scale = min(2, 680 / max(item.win.width, item.win.height))
                let master = motion.frames.compactMap {
                    StampCompositor.makeStamp(from: $0, previewSize: shot.size, windowRect: item.win,
                                              mirrored: shot.mirrored, clipToShape: false, scale: scale)?.image
                }
                guard master.count > 1 else { continue }
                let clip = item.style.moving ? Self.clipLook(master, style: item.style, mask: item.mask) : []
                DispatchQueue.main.sync {
                    self.setMotionMaster(master, delay: delay, for: item.id)
                    if clip.count > 1 { self.setHotClip(clip, delay: delay, for: item.id) }
                }
                guard clip.count > 1, let data = APNG.encode(clip, delay: delay) else { continue }
                let lean = APNG.encodeForMessages(clip, delay: delay)
                DispatchQueue.main.sync { self.setLive(data, sticker: lean, for: item.id) }
            }
        }
    }

    // MARK: - 찾기

    /// 한 마디 · 장소 · 수집함 · 스티커 글자 · 날짜에서 찾는다. 낱말을 띄어 쓰면 모두 맞는 것만.
    func search(_ query: String) -> [CollectedStamp] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let hay = searchWords
        return stamps.reversed().filter { s in
            guard let text = hay[s.id] else { return false }
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// 스티커마다 찾을 말(소문자) — 한 마디 · 장소 · 수집함 · 스티커 글자 · 날짜.
    /// 앱의 찾기와, 메시지 · 키보드로 내보내는 목록(`collections.json` 의 `words`)이 같은 말을 쓴다.
    var searchWords: [String: String] {
        Dictionary(uniqueKeysWithValues: stamps.map { s in
            (s.id, [s.caption, s.place, s.album, existingMeta(for: s.id).label ?? "",
                    s.createdAt.formatted(date: .long, time: .omitted),
                    s.createdAt.formatted(.dateTime.year().month(.wide)),
                    s.createdAt.formatted(.dateTime.month(.defaultDigits).day())]
                .joined(separator: " ").lowercased())
        })
    }

    // MARK: - 백업 · 수집함 보내기 (StickerArchive)

    /// 스티커 하나를 이루는 파일들(묶음 안 경로, 실제 위치).
    private func stickerFiles(_ id: String) -> [(path: String, source: URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = []
        for name in [id, "\(id).txt", "\(id).grp", "\(id).json", "\(id).orig.jpg", "\(id).live.png", "\(id).cut"] {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { out.append((name, url)) }
        }
        let frames = framesDir(for: id)
        for f in ((try? fm.contentsOfDirectory(atPath: frames.path)) ?? []).sorted() {
            out.append(("\(id).frames/\(f)", frames.appendingPathComponent(f)))
        }
        return out
    }

    /// 묶음에 넣을 파일 — `album` 이 nil 이면 전체 백업(수집함 정보 포함), 아니면 그 수집함만.
    func archiveFiles(album: String?) -> [(path: String, source: URL)] {
        let ids = (album.map { stamps(in: $0) } ?? stamps).map(\.id)
        var files = ids.flatMap(stickerFiles)
        if album == nil { files.append(("albums.json", metaURL)) }
        return files
    }

    /// `.kkuk` 파일을 만들어 임시 폴더에 둔다. 다 되면 메인에서 `done(url or nil)`.
    func makeArchive(album: String?, done: @escaping (URL?) -> Void) {
        var files = archiveFiles(album: album)
        let count = album.map { count(in: $0) } ?? stamps.count
        // 수집함 하나를 보낼 때도 속지 · 순서가 함께 가도록 그 수집함만 적은 albums.json 을 넣는다
        if let album,
           let data = try? JSONEncoder().encode(Meta(albums: [album], active: album,
                                                     decor: decor[album].map { [album: $0] })) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("pack-albums-\(UUID().uuidString).json")
            if (try? data.write(to: tmp)) != nil { files.append(("albums.json", tmp)) }
        }
        let manifest = StickerArchive.Manifest(kind: album == nil ? .backup : .pack,
                                               album: album, count: count)
        let base: String
        if let album {
            base = StickerArchive.safeName(album)
        } else {
            let day = Date().formatted(.iso8601.year().month().day())
            base = StickerArchive.safeName(String(localized: "펀칭 백업 \(day)"))
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Outgoing-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent(base).appendingPathExtension(StickerArchive.fileExtension)
        Task.detached(priority: .userInitiated) {
            var result: URL?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try StickerArchive.write(files: files, manifest: manifest, to: url)
                result = url
            } catch {
                result = nil
            }
            let made = result
            await MainActor.run { done(made) }
        }
    }

    /// 받은 `.kkuk` 을 더한다. 이미 있는 스티커는 건너뛰고, 아무것도 지우지 않는다.
    func importArchive(at url: URL, done: @escaping (Result<StickerImportResult, Error>) -> Void) {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Incoming-\(UUID().uuidString)", isDirectory: true)
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let outcome: Result<StickerArchive.Manifest, Error>
            do { outcome = .success(try StickerArchive.read(url, into: staging)) }
            catch { outcome = .failure(error) }
            await MainActor.run {
                defer { try? FileManager.default.removeItem(at: staging) }
                switch outcome {
                case .failure(let e): done(.failure(e))
                case .success(let manifest): done(.success(self.mergeImported(from: staging, manifest: manifest)))
                }
            }
        }
    }

    private func mergeImported(from staging: URL, manifest: StickerArchive.Manifest) -> StickerImportResult {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: staging.path)) ?? []
        let ids = names.filter { $0.range(of: #"^\d{1,16}\.png$"#, options: .regularExpression) != nil }.sorted()
        let have = Set(stamps.map(\.id))
        let theirMeta = (try? Data(contentsOf: staging.appendingPathComponent("albums.json")))
            .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        let packAlbum = manifest.kind == .pack
            ? manifest.album?.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        var added = 0, skipped = 0
        var touched: [String] = []
        for id in ids {
            guard !have.contains(id), UIImage(contentsOfFile: staging.appendingPathComponent(id).path) != nil
            else { skipped += 1; continue }
            let theirAlbum = ((try? String(contentsOf: staging.appendingPathComponent("\(id).grp"),
                                           encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let home = [packAlbum ?? "", theirAlbum, activeAlbum].first { !$0.isEmpty } ?? Self.defaultAlbum
            for name in names where name == id || name.hasPrefix("\(id).") {
                try? fm.copyItem(at: staging.appendingPathComponent(name), to: dir.appendingPathComponent(name))
            }
            try? home.write(to: albumURL(for: id), atomically: true, encoding: .utf8)
            if !touched.contains(home) { touched.append(home) }
            added += 1
        }

        // 새 수집함: 백업에 적힌 순서대로 덧붙이고, 꾸미기(속지 · 순서)도 새 수집함에만 가져온다
        let order = (theirMeta?.albums ?? []) + touched
        for album in order where touched.contains(album) && !albums.contains(album) {
            albums.append(album)
            if let theirDecor = theirMeta?.decor?[album] {
                decor[album] = theirDecor
            }
        }
        loadStamps()
        reconcile()   // 저장 + 메시지 · 키보드 스티커 팩 동기화
        return StickerImportResult(added: added, skipped: skipped, albums: touched)
    }

    // MARK: - Album decor (자유롭게 꾸미기)

    func backgroundStyle(of album: String) -> BackgroundStyle {
        decor[album]?.background.flatMap(BackgroundStyle.init(rawValue:)) ?? .cream
    }

    func setBackground(_ style: BackgroundStyle, for album: String) {
        guard albums.contains(album) else { return }
        decor[album, default: AlbumDecor()].background = style == .cream ? nil : style.rawValue
        saveMeta()
    }

    /// Whether the album has a hand-arranged order (vs plain time order).
    func isArranged(_ album: String) -> Bool { decor[album]?.order != nil }

    /// Moves a stamp to `index` within the album's current order, which from
    /// then on is the album's arranged order.
    func reorder(in album: String, moving id: String, to index: Int) {
        var ids = stamps(in: album).map(\.id)
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        ids.insert(id, at: max(0, min(index, ids.count)))
        decor[album, default: AlbumDecor()].order = ids
        saveMeta()
    }

    /// Back to plain time order (oldest → newest).
    func resetOrder(_ album: String) {
        guard decor[album]?.order != nil else { return }
        decor[album]?.order = nil
        saveMeta()
    }

}

// MARK: - Live stamps (APNG encode + playback)

/// Encodes frames into an animated PNG — Messages animates these as stickers,
/// and the app plays them back wherever a stamp should move.
enum APNG {
    static func encode(_ frames: [UIImage], delay: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(dest,
            [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyPNGDictionary:
                            [kCGImagePropertyAPNGDelayTime: delay]] as CFDictionary
        for f in frames {
            guard let cg = f.cgImage else { continue }
            CGImageDestinationAddImage(dest, cg, frameProps)
        }
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// A lean variant for iMessage: Messages rejects sticker files over
    /// ~500 KB (an oversized one doesn't just stay still — it vanishes from
    /// the tray), AND it renders stickers at pixels÷3 — so shrinking pixels
    /// makes thumbnail-tiny stickers. Spend the budget on SIZE first and give
    /// up frames instead; nil means "keep the still sticker".
    static func encodeForMessages(_ frames: [UIImage], delay: Double) -> Data? {
        let attempts: [(px: CGFloat, maxFrames: Int)] = [
            (480, 6), (408, 6), (408, 5), (360, 5), (320, 4), (280, 4),
        ]
        for attempt in attempts {
            let kept = thin(frames, to: attempt.maxFrames)
            guard kept.count > 1 else { continue }
            // stretch the per-frame delay so the clip keeps its real-time span
            let keptDelay = delay * Double(frames.count) / Double(kept.count)
            let small = kept.map { shrunk($0, maxPixel: attempt.px) }
            if let data = encode(small, delay: keptDelay), data.count <= 480_000 {
                return data
            }
        }
        return nil
    }

    /// Evenly samples `frames` down to at most `maxCount`.
    static func thin(_ frames: [UIImage], to maxCount: Int) -> [UIImage] {
        guard frames.count > maxCount else { return frames }
        let step = Double(frames.count) / Double(maxCount)
        return (0..<maxCount).map { frames[Int(Double($0) * step)] }
    }

    static func shrunk(_ img: UIImage, maxPixel: CGFloat) -> UIImage {
        let s = min(1, maxPixel / max(img.size.width, img.size.height))
        guard s < 1 else { return img }
        let size = CGSize(width: (img.size.width * s).rounded(),
                          height: (img.size.height * s).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Encodes frames into an animated GIF. Unlike APNG, a dynamically-loaded GIF
/// sticker actually keeps animating once it's peeled/sent into an iMessage
/// conversation (APNG freezes to its first frame there), so moving stickers
/// ship in this format. GIF is 256-color with 1-bit transparency — fine for a
/// small tray sticker, and it usually compresses smaller than the APNG.
enum AnimatedGIF {
    static func encode(_ frames: [UIImage], delay: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "com.compuserve.gif" as CFString, frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(dest,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary:
                            [kCGImagePropertyGIFDelayTime: delay,
                             kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        for f in frames {
            guard let cg = f.cgImage else { continue }
            CGImageDestinationAddImage(dest, cg, frameProps)
        }
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Lean variant for iMessage: same SIZE-first budget ladder as the APNG one
    /// (Messages renders stickers at pixels÷3 and drops files over ~500 KB), but
    /// GIF's indexed palette lets us keep more frames before hitting the cap.
    static func encodeForMessages(_ frames: [UIImage], delay: Double) -> Data? {
        let attempts: [(px: CGFloat, maxFrames: Int)] = [
            (480, 12), (480, 8), (408, 8), (360, 6), (320, 5), (280, 4),
        ]
        for attempt in attempts {
            let kept = APNG.thin(frames, to: attempt.maxFrames)
            guard kept.count > 1 else { continue }
            let keptDelay = delay * Double(frames.count) / Double(kept.count)
            let small = kept.map { APNG.shrunk($0, maxPixel: attempt.px) }
            if let data = encode(small, delay: keptDelay), data.count <= 480_000 {
                return data
            }
        }
        return nil
    }
}

/// Plays a live stamp's frames in a loop. Driven by TimelineView, so playback
/// is plain SwiftUI state — UIImageView's animation can silently stall when
/// re-hosted inside masks/animated containers; this can't.
struct LiveStampView: View {
    let frames: [UIImage]
    let delay: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: max(delay, 1.0 / 30))) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Image(uiImage: frames[frameIndex(at: t)])
                .resizable()
                .scaledToFit()
        }
    }

    /// Which frame is on show at time `t` — pure math, unit-testable.
    func frameIndex(at t: TimeInterval) -> Int {
        guard !frames.isEmpty else { return 0 }
        return Int(t / max(delay, 0.01)) % frames.count
    }
}

// MARK: - Subject lift (Apple's "lift the subject" sticker cutout)

/// Wraps Vision's foreground-subject mask to cut the subject out of a photo with
/// a transparent background — the same "make sticker" effect as iOS Photos.
enum SubjectLift {
    /// Returns a transparent cutout of the photo's main subject, or nil if the
    /// OS is too old or no subject is found (caller falls back to the crop).
    static func cutout(from image: UIImage) -> UIImage? {
        guard #available(iOS 17.0, *), let cg = image.normalizedUp().cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }
            let buffer = try result.generateMaskedImage(ofInstances: wanted(in: result),
                                                         from: handler,
                                                         croppedToInstancesExtent: true)
            // The masked image keeps a soft, semi-transparent matte at the
            // silhouette — against a dark background it reads as a pale outline.
            // Pull the alpha into a grayscale mask, ERODE it a couple of pixels
            // (so the boundary's background-tinted pixels are dropped), then
            // threshold it crisp — leaving a clean, halo-free transparent edge.
            let masked = CIImage(cvPixelBuffer: buffer)
            let mask = SubjectLift.crispEdgeMask(fromAlphaOf: masked)
            guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
            blend.setValue(masked, forKey: kCIInputImageKey)
            blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
            blend.setValue(mask, forKey: kCIInputMaskImageKey)
            guard let out = blend.outputImage,
                  let cgOut = ciCtx.createCGImage(out, from: masked.extent) else { return nil }
            return UIImage(cgImage: cgOut)
        } catch {
            return nil
        }
    }

    /// Erodes (~2px) + hard-thresholds a soft matte into a crisp silhouette mask,
    /// so a cutout has no translucent halo. `fromAlphaOf` first lifts the source
    /// image's alpha channel into grayscale; pass `alphaIsGrayscale: true` for a
    /// mask that's already grayscale (Vision's scaled mask).
    static func crispEdgeMask(fromAlphaOf image: CIImage, alphaIsGrayscale: Bool = false) -> CIImage {
        let gray: CIImage = alphaIsGrayscale ? image : image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        return gray
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 2.0])
            .applyingFilter("CIColorMatrix", parameters: [   // threshold ALL channels at ~0.5
                "inputRVector": CIVector(x: 16, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 16, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 16, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 16, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -8, y: -8, z: -8, w: -8),
            ])
            .applyingFilter("CIColorClamp")
            .cropped(to: image.extent)
    }

    private static let ciCtx = CIContext()

    /// 사진 속 대상들이 어디에 있는지. 찍은 뒤 무엇을 스티커로 만들지 고를 때 쓴다.
    static func subjects(in image: UIImage) -> SubjectMap? {
        guard #available(iOS 17.0, *), let cg = image.normalizedUp().cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? VNImageRequestHandler(cgImage: cg).perform([request])) != nil,
              let result = request.results?.first else { return nil }
        return SubjectMap(result.instanceMask)
    }

    /// 조각에서 오려낼 대상 — 고른 것 옆에서 끼어든 조각은 버린다 (`SubjectMap.kept`).
    @available(iOS 17.0, *)
    private static func wanted(in result: VNInstanceMaskObservation) -> IndexSet {
        guard let map = SubjectMap(result.instanceMask) else { return result.allInstances }
        let keep = IndexSet(map.kept.map(Int.init)).intersection(result.allInstances)
        return keep.isEmpty ? result.allInstances : keep
    }

    /// The subject's foreground mask (full-frame, NOT cropped to the subject) —
    /// computed once and reused across a clip's frames so the cutout silhouette
    /// stays put while the photo inside it moves (no per-frame Vision, no jitter,
    /// no dropped frames).
    static func subjectMask(from image: UIImage) -> CIImage? {
        guard #available(iOS 17.0, *), let cg = image.normalizedUp().cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }
            let buffer = try result.generateScaledMaskForImage(forInstances: wanted(in: result),
                                                                from: handler)
            return CIImage(cvPixelBuffer: buffer)
        } catch {
            return nil
        }
    }

    /// Cut an image to a previously-computed mask (same look, every frame).
    static func apply(mask: CIImage, to image: UIImage) -> UIImage? {
        guard let cg = image.normalizedUp().cgImage else { return nil }
        let src = CIImage(cgImage: cg)
        let scaled = mask.transformed(by: CGAffineTransform(scaleX: src.extent.width / mask.extent.width,
                                                            y: src.extent.height / mask.extent.height))
        // erode + hard-threshold the soft mask → a crisp silhouette with no
        // translucent matte halo (the pale outline the user sees).
        let m = crispEdgeMask(fromAlphaOf: scaled, alphaIsGrayscale: true)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        filter.setValue(src, forKey: kCIInputImageKey)
        filter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        filter.setValue(m, forKey: kCIInputMaskImageKey)
        guard let out = filter.outputImage,
              let cgOut = ciCtx.createCGImage(out, from: src.extent) else { return nil }
        return UIImage(cgImage: cgOut)
    }
}

// MARK: - 대상 지도 (누가 어디 있는지)

/// 사진 속 대상들의 지도. 점마다 누구 것인지(0 = 바탕)와, 대상마다 차지한 자리를 안다.
struct SubjectMap {
    let width: Int
    let height: Int
    let labels: [UInt8]
    /// 대상마다 차지한 자리 (0...1, 왼쪽 위가 원점). 티끌만 한 것은 뺀다.
    private(set) var boxes: [UInt8: CGRect] = [:]
    private var areas: [UInt8: Int] = [:]
    private var onEdge: Set<UInt8> = []

    init?(width: Int, height: Int, labels: [UInt8]) {
        guard width > 0, height > 0, labels.count == width * height else { return nil }
        self.width = width; self.height = height; self.labels = labels
        var minX = [Int](repeating: .max, count: 256), minY = minX
        var maxX = [Int](repeating: -1, count: 256), maxY = maxX
        var area = [Int](repeating: 0, count: 256)
        for y in 0..<height {
            for x in 0..<width {
                let l = Int(labels[y * width + x])
                guard l != 0 else { continue }
                area[l] += 1
                if x < minX[l] { minX[l] = x }
                if x > maxX[l] { maxX[l] = x }
                if y < minY[l] { minY[l] = y }
                if y > maxY[l] { maxY[l] = y }
            }
        }
        let speck = width * height / 250          // 화면의 0.4% 보다 작으면 대상으로 치지 않는다
        let w = CGFloat(width), h = CGFloat(height)
        for l in 1..<256 where area[l] > speck {
            let key = UInt8(l)
            areas[key] = area[l]
            boxes[key] = CGRect(x: CGFloat(minX[l]) / w, y: CGFloat(minY[l]) / h,
                                width: CGFloat(maxX[l] - minX[l] + 1) / w,
                                height: CGFloat(maxY[l] - minY[l] + 1) / h)
            if minX[l] == 0 || minY[l] == 0 || maxX[l] == width - 1 || maxY[l] == height - 1 {
                onEdge.insert(key)
            }
        }
    }

    /// Vision 이 준 대상 마스크(점마다 대상 번호)에서 만든다.
    init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var out = [UInt8](repeating: 0, count: w * h)
        out.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                memcpy(dst.baseAddress! + y * w, base + y * row, w)
            }
        }
        self.init(width: w, height: h, labels: out)
    }

    var count: Int { boxes.count }

    /// 조각에 남길 대상: 가장 큰 것, 그리고 가장자리에 걸리지 않고 온전히 담긴 것.
    /// 고른 대상에 맞춰 자른 조각에서는 옆에서 끼어든 것이 늘 가장자리에 걸린다.
    var kept: [UInt8] {
        guard let main = areas.max(by: { $0.value < $1.value })?.key else { return [] }
        return boxes.keys.filter { $0 == main || !onEdge.contains($0) }.sorted()
    }

    /// 모든 대상을 한꺼번에 담는 자리.
    var everything: CGRect? {
        boxes.values.reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
    }

    /// 누른 자리(0...1)의 대상. 살짝 빗나가도 가까운 대상을 잡는다. 없으면 0.
    func label(near point: CGPoint) -> UInt8 {
        let cx = Int(point.x * CGFloat(width)), cy = Int(point.y * CGFloat(height))
        let reach = max(width, height) / 25
        for r in stride(from: 0, through: reach, by: max(reach / 6, 1)) {
            for (dx, dy) in [(0, 0), (r, 0), (-r, 0), (0, r), (0, -r), (r, r), (-r, r), (r, -r), (-r, -r)] {
                let x = cx + dx, y = cy + dy
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                let l = labels[y * width + x]
                if boxes[l] != nil { return l }
            }
        }
        return 0
    }

    /// 대상 자리만 불투명한 그림. `only` 를 주면 그 대상들만 남긴다.
    func mask(of only: Set<UInt8>? = nil) -> UIImage? {
        let keep = only ?? Set(boxes.keys)
        return StickerMask.image(width: width, height: height) { keep.contains(labels[$0]) }
    }
}

// MARK: - Sticker sheet export (print-ready PDF)

/// Wraps share items (a PDF URL, an image + caption, …) to drive `.sheet(item:)`.
/// A sticker ready to hand to another app (see `CollectionStore.makeExport`).
struct StickerExport {
    let data: Data
    /// A temp file holding `data`, for the share sheet (nil if it couldn't be written).
    let url: URL?
    let pasteboardType: String

    init(data: Data, ext: String, pasteboardType: String, id: String) {
        self.data = data
        self.pasteboardType = pasteboardType
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("펀칭-\(id).\(ext)")
        url = (try? data.write(to: u)) != nil ? u : nil
    }

    func copy() { UIPasteboard.general.setData(data, forPasteboardType: pasteboardType) }
}

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
///  • Die-cut — the cut follows the stamp's perforated outline itself (the same
///    `stampBezierPath` the app punches with), drawn as a magenta
///    `CutContour`-style guide a cutter/vendor can follow — so the peeled
///    sticker IS stamp-shaped, teeth and all.
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
        var stickerInches: CGFloat = 2.0                  // grid cell; the stamp sits inside
        var bleedInches: CGFloat = 0.08                   // ~2 mm white rim
        var artInsetInches: CGFloat = 0.14                // stamp inset from the cell edge
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
                        drawSticker(cg, cell: cell, bleed: bleed,
                                    inset: inset, art: arts[index])
                    }
                }
            }
        } catch { return nil }
        return url
    }

    /// One sticker, stamp-shaped throughout: a white bleed base in the
    /// perforated outline → the stamp art → a kiss-cut guide tracing the same
    /// toothed outline — so what peels off the sheet looks like a real stamp.
    ///
    /// The base and the cut are the art's own path geometrically scaled about
    /// its centre — NOT re-generated in a bigger rect. `stampBezierPath`
    /// recomputes hole radii/positions from the rect, so regenerated outlines
    /// drift out of phase with the art's teeth (and the cut's inward bites
    /// then cross over the photo). Scaling one path keeps every tooth nested.
    private static func drawSticker(_ cg: CGContext, cell: CGRect,
                                    bleed: CGFloat, inset: CGFloat, art: UIImage?) {
        guard let art else { return }

        // the stamp's box: aspect-fit inside the cell with a small inset
        let avail = cell.insetBy(dx: inset, dy: inset)
        let s = min(avail.width / art.size.width, avail.height / art.size.height)
        let w = art.size.width * s, h = art.size.height * s
        let box = CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h)

        // one source outline, in perfect phase with the art's perforation
        let outline = stampBezierPath(in: box).cgPath
        func grown(by amount: CGFloat) -> CGPath {
            var t = CGAffineTransform(translationX: box.midX, y: box.midY)
                .scaledBy(x: (box.width + 2 * amount) / box.width,
                          y: (box.height + 2 * amount) / box.height)
                .translatedBy(x: -box.midX, y: -box.midY)
            return outline.copy(using: &t) ?? outline
        }

        // White base: the same outline pushed out by the bleed, so the peeled
        // sticker keeps an even white paper rim around every tooth.
        cg.saveGState()
        cg.setFillColor(UIColor.white.cgColor)
        cg.addPath(grown(by: bleed))
        cg.fillPath()
        cg.restoreGState()

        // The stamp art (already clipped to its own perforation).
        art.draw(in: box)

        // Kiss-cut guide (magenta dashed = CutContour convention): midway
        // through the white rim — parallel to the art edge along the whole
        // contour, never straying onto the photo.
        cg.saveGState()
        cg.setStrokeColor(UIColor.magenta.cgColor)
        cg.setLineWidth(0.8)
        cg.setLineDash(phase: 0, lengths: [3.5, 2.5])
        cg.addPath(grown(by: bleed * 0.5))
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
                    Text("PUNCHING")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .tracking(4)
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

// MARK: - Print guide

/// "찍은 우표를 진짜 스티커 우표로" — the journey from capture to a printed,
/// cut-out sticker sheet, told as numbered steps. Reachable from the
/// settings (쓰기) and each album's ⋯ menu.
struct PrintGuideView: View {
    /// 수집함에서 열었으면 그 수집함의 시트를 만드는 길. 설정에서 열었으면 nil.
    var makeSheet: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var plans = PunchingPlans.shared
    @State private var paywallFeature: PlanFeature?

    private let gold = Color(hex: 0xF2B23B)
    private let paper = Color.white.opacity(0.07)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header

                    step(1, "뜯기", "camera.fill",
                         "카메라에서 셔터를 꾹 눌렀다 놓으면 찰칵! 사진 속 주인공이 스티커로 뜯겨요. 여럿이면 원하는 것만 골라요.")
                    step(2, "색감 고르기", "paintbrush.pointed.fill",
                         "갓 나온 스티커 카드에 한 마디를 적고, ‘자세히’에서 세피아·흑백 같은 색감을 입혀보세요. 색감은 언제든 바꿔도 화질이 상하지 않아요.")
                    step(3, "수집함에 모으기", "book.closed.fill",
                         "스티커 시트는 수집함 단위로 만들어져요. 인쇄하고 싶은 스티커를 한 수집함에 모으세요 — 수집함에서 ‘선택’ 후 ‘옮기기’로 한 번에 옮길 수 있어요.")
                    step(4, "인쇄용 시트 만들기", "square.on.square",
                         "수집함 오른쪽 위 ⋯ 메뉴 → ‘쓰기’ → ‘인쇄용 스티커 시트 (PDF)’. 인쇄소에 바로 건넬 수 있는 300dpi PDF가 만들어져요. ‘파일에 저장’으로 보관하거나 AirDrop·메일로 보내세요.")
                    step(5, "인쇄하기", "printer.fill",
                         "집에서: A4·레터 라벨/스티커 용지(무광 추천)에 ‘실제 크기(100%)’로 인쇄하세요 — ‘용지에 맞춤’은 꼭 끄기.\n인쇄소·스티커 업체: PDF를 그대로 전달하면 돼요. 마젠타 점선이 칼선(kiss-cut), 모서리 표시가 재단 기준이에요.")
                    step(6, "오려서 붙이기", "scissors",
                         "점선을 따라 가위나 커팅기로 오리면 완성! 봉투, 다이어리, 노트북… 어디든 붙여보세요.")

                    tips
                    makeButton
                }
                .padding(20)
            }
            .background(Color(hex: 0x141210).ignoresSafeArea())
            .paywall($paywallFeature)
            .navigationTitle("종이 스티커로 인쇄하기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// 가이드 끝의 '스티커 시트 만들기'. Pro 가 아니면 Pro 를 보여 주고, 수집함에서 열었으면 바로 만든다.
    @ViewBuilder
    private var makeButton: some View {
        let open = plans.allows(.printSheet)
        if !open || makeSheet != nil {
            Button {
                if !open {
                    paywallFeature = .printSheet
                } else if let makeSheet {
                    makeSheet()
                    dismiss()
                }
            } label: {
                Label("스티커 시트 만들기", systemImage: open ? "printer.fill" : "lock.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: 0xE8504E))
            .controlSize(.large)
            .padding(.top, 6)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("📮 뜯은 순간, 손에 잡히는 스티커로")
                .scaledFont(20, weight: .heavy, design: .rounded)
                .foregroundStyle(.white)
            Text("여섯 걸음이면 휴대폰 속 스티커가 책상 위 스티커가 돼요.")
                .scaledFont(13, weight: .medium, design: .rounded)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.bottom, 6)
    }

    private func step(_ n: Int, _ title: LocalizedStringKey, _ icon: String, _ body: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(gold.opacity(0.18))
                Text("\(n)")
                    .scaledFont(15, weight: .heavy, design: .rounded)
                    .foregroundStyle(gold)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon)
                    .scaledFont(15, weight: .bold, design: .rounded)
                    .foregroundStyle(.white)
                Text(body)
                    .scaledFont(13.5, weight: .regular, design: .rounded)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(paper))
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("알아두면 좋아요", systemImage: "lightbulb.fill")
                .scaledFont(14, weight: .bold, design: .rounded)
                .foregroundStyle(gold)
            VStack(alignment: .leading, spacing: 6) {
                Text("• 인쇄용 시트는 모두 우표 모양으로 나와요. 칼선이 톱니 모양 그대로라, 떼어내면 진짜 우표처럼 생긴 스티커가 돼요(약 5cm, 한 페이지 12장).")
                Text("• 원본 사진을 간직한 스티커는 인쇄 때 300dpi로 새로 구워져 또렷하게 나와요.")
                Text("• 종이 말고 디지털로도: 모든 스티커는 자동으로 메시지 스티커가 돼요 — 메시지 앱 스티커 서랍에서 바로 붙이고, 움직이는 스티커는 움직이며 붙어요.")
                Text("• 진짜 우편요금 우표는 아니에요 — 편지 장식은 마음껏, 우표 자리는 진짜 우표에게 양보!")
            }
            .scaledFont(13, weight: .regular, design: .rounded)
            .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(gold.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(gold.opacity(0.25), lineWidth: 1))
        .padding(.top, 4)
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
    /// 소리 일은 전용 줄에서 한다 — 오디오 세션을 켜고 플레이어를 만드는 일은 메인 스레드를 붙잡을 수 있다.
    private static let queue = DispatchQueue(label: "com.devkoan.StampCamera.punchSound", qos: .userInteractive)
    // 아래 둘은 queue 에서만 만진다
    nonisolated(unsafe) private static var player: AVAudioPlayer?
    nonisolated(unsafe) private static var playing = 0      // 몇 번째 소리인지 — 늦게 온 페이드가 새 소리를 끊지 않게

    static func play() {
        queue.async {
            // audible even alongside other audio
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try? AVAudioSession.sharedInstance().setActive(true)
            if player == nil, let url = Bundle.main.url(forResource: "punching", withExtension: "mp3") {
                player = try? AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
            }
            guard let p = player else { return }
            playing += 1
            let mine = playing
            p.stop()
            p.currentTime = 0
            p.volume = 1
            p.play()
            queue.asyncAfter(deadline: .now() + 0.85) {
                if playing == mine { p.setVolume(0, fadeDuration: 0.15) }
            }
            queue.asyncAfter(deadline: .now() + 1.0) {
                guard playing == mine else { return }
                p.stop()
                p.volume = 1
            }
        }
    }
}

// MARK: - Button styles

private struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(15, weight: .semibold, design: .rounded)
            .foregroundStyle(.white)
            .padding(.horizontal, 24).padding(.vertical, 13)
            .background(Color(hex: 0xE8504E), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A full-width frosted chip for the reveal viewer's 복사 / 공유 (on black).
private struct RevealActionChip: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(15, weight: .semibold, design: .rounded)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Capsule().fill(.white.opacity(0.18)))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A full-width warm chip used for the stamp detail's 복사 / 공유 actions.
private struct StampActionChip: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(14, weight: .semibold, design: .rounded)
            .foregroundStyle(Color(hex: 0xE9D9AE))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Capsule().fill(Color(hex: 0x3A2F22)))
            .overlay(Capsule().strokeBorder(Color(hex: 0xB89A5E).opacity(0.4), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}


// MARK: - Capture reveal (the "got it!" moment)

/// Full-screen celebration shown right after a stamp is cut: the fresh stamp
/// pops up as a glossy collectible card over a dimmed blur — it hovers, throws
/// a holographic sheen on a loop, and tilts in 3D under the finger like a
/// trading card. A caption can be jotted inline; "담기" flings it into the bin.
struct CaptureRevealView: View {
    @ObservedObject var collection: CollectionStore
    let stampID: String
    /// Where the card flies when tucked away (the bin, in screen coords).
    let exitPoint: CGPoint
    var onDetail: () -> Void
    var onDismiss: () -> Void
    /// "마음에 안 들어" — the stamp is dropped and deleted outright.
    var onDiscard: () -> Void

    @State private var entered = false
    @State private var ring = false
    @State private var leaving = false
    @State private var discarding = false
    @State private var drag: CGSize = .zero
    @State private var dragging = false
    @State private var spin: Double = 0      // settled y-rotation (multiples of 180°)
    @State private var flipped = false       // has the back been discovered yet
    @State private var caption = ""
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stamp: CollectedStamp? { collection.stamps.first { $0.id == stampID } }

    @State private var sharePayload: SharePayload?

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let exit = exitPoint == .zero
                ? CGPoint(x: center.x, y: geo.size.height + 100) : exitPoint
            ZStack {
                // dimmed glass over the camera with a warm glow behind the card
                BlurView().ignoresSafeArea()
                    .opacity(leaving || discarding ? 0 : 1)
                Color.black.opacity(0.45).ignoresSafeArea()
                    .opacity(leaving || discarding ? 0 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture { if focused { focused = false } else { tuckAway() } }
                RadialGradient(colors: [Color(hex: 0xF2B23B).opacity(0.30), .clear],
                               center: .center, startRadius: 10, endRadius: 330)
                    .ignoresSafeArea()
                    .opacity(leaving || discarding ? 0 : 1)
                    .allowsHitTesting(false)

                VStack(spacing: 18) {
                    Spacer(minLength: 10)

                    VStack(spacing: 8) {
                        Text("NEW")
                            .scaledFont(11, weight: .black, design: .rounded)
                            .tracking(3)
                            .foregroundStyle(Color(hex: 0x3A2C12))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color(hex: 0xFFD966)))
                        Text("스티커가 도착했어요!")
                            .scaledFont(25, weight: .heavy, design: .rounded)
                            .foregroundStyle(.white)
                    }
                    .chromeReveal(entered: entered, leaving: leaving || discarding, delay: 0.22)

                    holoCard(center: center, exit: exit)
                        .frame(maxWidth: 250, maxHeight: 330)

                    // a quiet nudge until the back has been found once
                    Text("스티커를 빙글 돌려보세요")
                        .scaledFont(12, weight: .medium, design: .rounded)
                        .foregroundStyle(.white.opacity(0.45))
                        .opacity(flipped ? 0 : 1)
                        .animation(.easeOut(duration: 0.3), value: flipped)
                        .chromeReveal(entered: entered, leaving: leaving || discarding, delay: 0.32)

                    captionPill
                        .chromeReveal(entered: entered, leaving: leaving || discarding, delay: 0.40)

                    Spacer(minLength: 6)

                    actions
                        .chromeReveal(entered: entered, leaving: leaving || discarding, delay: 0.48)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
        }
        .onAppear {
            caption = stamp?.caption ?? ""
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { entered = true }
            withAnimation(.easeOut(duration: 0.9).delay(0.08)) { ring = true }
            Haptics.placed()
        }
    }

    /// The stamp as a spinnable card: horizontal drags spin it right round
    /// (past 90° the postmarked paper back shows), vertical drags tilt it,
    /// and a holographic sheen loops across the front while it idles. A
    /// still stamp hovers gently; a live stamp sits rock-still and lets its
    /// own captured motion do the moving.
    private func holoCard(center: CGPoint, exit: CGPoint) -> some View {
        let hasMotion = collection.hotClips[stampID] != nil || collection.hasLive(stampID)
        return TimelineView(.animation(minimumInterval: 1.0 / 50)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            // idle: a slow hover (stills only), and a sheen streak every ~3.4s
            // 동작 줄이기: 둥실 떠 있기·반짝이 줄기를 멈춘다
            let hover: CGFloat = entered && !dragging && !leaving && !hasMotion && !reduceMotion
                ? sin(t * 1.7) * 5 : 0
            let phase = t.truncatingRemainder(dividingBy: 3.4) / 3.4
            let idleBand: CGFloat = reduceMotion ? 1.8
                : (phase < 0.4 ? CGFloat(phase / 0.4) * 2.4 - 1.2 : 1.8)
            let band: CGFloat = dragging ? drag.width / 70 : idleBand

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.9), lineWidth: 2.5)
                    .frame(width: 130, height: 130)
                    .scaleEffect(ring ? 3.2 : 0.3)
                    .opacity(ring ? 0 : 0.9)

                if let img = stamp?.image {
                    SpinCard(angle: spin + Double(drag.width) * 0.7,
                             pitch: Double(-drag.height) / 11,
                             front: cardFront(img, band: band),
                             back: cardBack(img))
                        .shadow(color: .black.opacity(0.5), radius: 18, y: 12)
                        .shadow(color: Color(hex: 0xFFD966).opacity(0.30), radius: 28)
                }

                if !reduceMotion { SparkleBurst() }   // 동작 줄이기면 불꽃 생략
            }
            .offset(y: hover)
        }
        .scaleEffect(leaving ? 0.08 : (discarding ? 0.7 : (entered ? 1 : 0.3)))
        .rotationEffect(.degrees(discarding ? 26 : (entered ? 0 : -9)))
        .opacity(leaving || discarding || !entered ? 0 : 1)
        .offset(leaving ? CGSize(width: exit.x - center.x, height: exit.y - center.y)
                : (discarding ? CGSize(width: 30, height: center.y + 420) : .zero))
        .animation(.spring(response: 0.5, dampingFraction: 0.62), value: entered)
        .animation(.easeIn(duration: 0.34), value: leaving)
        .animation(.easeIn(duration: 0.4), value: discarding)
        .gesture(tilt)
        // VoiceOver: 카드를 돌리는 대신 '뒤집기' 동작
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stamp?.caption.isEmpty == false ? stamp!.caption : String(localized: "새 스티커"))
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: "뒤집기") {
            flipped = true
            withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.72)) { spin += 180 }
        }
    }

    /// The face of the stamp with its holographic film. A live stamp starts
    /// moving the moment its clip finishes encoding (a beat into the reveal).
    /// Only the SHINE is masked to the still's silhouette — the art carries
    /// its own alpha, and a moving cutout subject must not be clipped by the
    /// frozen pose of the still.
    private func cardFront(_ img: UIImage, band: CGFloat) -> some View {
        Group {
            if let stamp {
                LiveArt(collection: collection, stamp: stamp, maxPixel: 700)
            } else {
                Image(uiImage: img).resizable().scaledToFit()
            }
        }
        .overlay {
            shine(band: band)
                .mask { Image(uiImage: img).resizable().scaledToFit() }
        }
    }

    /// The back of the stamp: bare paper in the same perforated silhouette,
    /// hand-stamped (slightly askew) with a round postmark — the date, time
    /// and place live here, like a real piece of mail.
    private func cardBack(_ img: UIImage) -> some View {
        let ink = Color(hex: 0x4E5E70)
        return Image(uiImage: img.withRenderingMode(.alwaysTemplate))
            .resizable().scaledToFit()
            .foregroundStyle(Color(hex: 0xF1EBDD))
            .overlay {
                VStack(spacing: 12) {
                    Text("PUNCHING")
                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                        .tracking(3.2)
                        .foregroundStyle(ink.opacity(0.5))
                    postmark(ink: ink)
                    if let stamp, !stamp.place.isEmpty {
                        Text(stamp.place)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink.opacity(0.85))
                            .lineLimit(1)
                            .padding(.horizontal, 26)
                    }
                }
                .rotationEffect(.degrees(-6))
            }
    }

    /// A round postal-cancellation mark carrying the date and time.
    private func postmark(ink: Color) -> some View {
        VStack(spacing: 1) {
            if let stamp {
                Text(stamp.createdAt, format: .dateTime.year())
                    .font(.system(size: 11, weight: .semibold, design: .serif))
                    .foregroundStyle(ink.opacity(0.7))
                Text(stamp.createdAt, format: .dateTime.month().day())
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .foregroundStyle(ink)
                Text(stamp.createdAt,
                     format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.85))
            }
        }
        .monospacedDigit()
        .frame(width: 104, height: 104)
        .overlay(Circle().strokeBorder(ink.opacity(0.75), lineWidth: 1.5))
        .overlay(Circle().inset(by: 5).strokeBorder(ink.opacity(0.4), lineWidth: 1))
    }

    /// The holographic film: a rainbow streak whose position is driven by the
    /// idle sweep or the finger, plus a soft specular spot under the tilt.
    private func shine(band: CGFloat) -> some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack {
                LinearGradient(
                    colors: [.clear,
                             Color(hex: 0x8FE3FF).opacity(0.35),
                             .white.opacity(0.55),
                             Color(hex: 0xFFB3E2).opacity(0.35),
                             .clear],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 0.6)
                    .rotationEffect(.degrees(16))
                    .offset(x: band * w)
                    .blendMode(.screen)
                RadialGradient(colors: [.white.opacity(dragging ? 0.32 : 0.15), .clear],
                               center: UnitPoint(x: 0.5 + max(-90, min(90, drag.width)) / 480,
                                                 y: 0.42 + drag.height / 480),
                               startRadius: 6, endRadius: w * 0.75)
                    .blendMode(.screen)
            }
        }
        .allowsHitTesting(false)
    }

    /// Horizontal = free spin (with a fling, settling flat on the nearest
    /// face); vertical = a gentle pitch tilt that springs back.
    private var tilt: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                dragging = true
                drag = CGSize(width: v.translation.width,
                              height: max(-90, min(90, v.translation.height)))
            }
            .onEnded { v in
                dragging = false
                let thrown = spin + Double(v.translation.width) * 0.7
                    + Double(v.predictedEndTranslation.width - v.translation.width) * 0.25
                let snapped = (thrown / 180).rounded() * 180
                if snapped != spin {
                    flipped = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { Haptics.pageTurn() }
                }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                    spin = snapped
                    drag = .zero
                }
            }
    }

    private var captionPill: some View {
        TextField("", text: $caption,
                  prompt: Text("이 순간에 한 마디…").foregroundStyle(.white.opacity(0.45)),
                  axis: .vertical)
            .lineLimit(1...3)
            .focused($focused)
            .scaledFont(15, weight: .medium, design: .rounded)
            .foregroundStyle(.white)
            .tint(Color(hex: 0xFFD966))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: tuckAway) {
                Text("수집함에 담기")
                    .scaledFont(17, weight: .heavy, design: .rounded)
                    .foregroundStyle(Color(hex: 0x3A2C12))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(
                        LinearGradient(colors: [Color(hex: 0xFFE08A), Color(hex: 0xF2B23B)],
                                       startPoint: .top, endPoint: .bottom)))
                    .shadow(color: Color(hex: 0xF2B23B).opacity(0.45), radius: 14, y: 6)
            }
            HStack(spacing: 26) {
                Button(action: discard) {
                    Label("버리기", systemImage: "trash")
                        .scaledFont(14, weight: .semibold, design: .rounded)
                        .foregroundStyle(Color(hex: 0xFF9C9C).opacity(0.85))
                }
                // 뜯자마자 쓰기 — 움직이면 GIF, 아니면 PNG 로 공유 시트
                Button {
                    collection.setCaption(caption, for: stampID)
                    collection.makeExport(for: stampID) { export in
                        if let url = export?.url { sharePayload = SharePayload(items: [url]) }
                    }
                } label: {
                    Label("보내기", systemImage: "paperplane")
                        .scaledFont(14, weight: .semibold, design: .rounded)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Button {
                    collection.setCaption(caption, for: stampID)
                    onDetail()
                } label: {
                    Label("자세히", systemImage: "slider.horizontal.3")
                        .scaledFont(14, weight: .semibold, design: .rounded)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .labelStyle(.titleAndIcon)
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
    }

    /// Save the caption, fling the card into the bin, then hand off.
    private func tuckAway() {
        guard !leaving, !discarding else { return }
        focused = false
        collection.setCaption(caption, for: stampID)
        withAnimation(.easeIn(duration: 0.34)) { leaving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { onDismiss() }
    }

    /// Didn't turn out well — the card tumbles off the bottom of the screen
    /// and the stamp is deleted for good.
    private func discard() {
        guard !leaving, !discarding else { return }
        focused = false
        Haptics.deselect()
        withAnimation(.easeIn(duration: 0.4)) { discarding = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { onDiscard() }
    }
}

private extension View {
    /// Shared treatment for the reveal's chrome (texts, pills, buttons):
    /// staggered rise-in on entry, quick fade when the card flies off.
    func chromeReveal(entered: Bool, leaving: Bool, delay: Double) -> some View {
        self
            .opacity(entered ? 1 : 0)
            .offset(y: entered ? 0 : 14)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(delay), value: entered)
            .opacity(leaving ? 0 : 1)
            .animation(.easeIn(duration: 0.22), value: leaving)
    }
}

/// A two-faced card spun freely around its vertical axis. Conforming to
/// `Animatable` means the face swap happens exactly at the 90° silhouette
/// edge mid-animation, instead of jumping when the state value lands.
private struct SpinCard<Front: View, Back: View>: View, Animatable {
    var angle: Double   // y-rotation in degrees, unbounded
    var pitch: Double   // x-tilt in degrees
    let front: Front
    let back: Back

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(angle, pitch) }
        set { angle = newValue.first; pitch = newValue.second }
    }

    var body: some View {
        let a = (angle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        ZStack {
            if a > 90 && a < 270 {
                back.scaleEffect(x: -1)   // pre-mirrored so it reads right when turned
            } else {
                front
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
        .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
    }
}

/// A one-shot radial burst of tiny glints — fired once when the reveal opens.
private struct SparkleBurst: View {
    @State private var start: Date?
    private let life = 1.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { tl in
            Canvas { ctx, size in
                guard let start else { return }
                let t = tl.date.timeIntervalSince(start)
                guard t > 0, t < life else { return }
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let palette: [Color] = [.white, Color(hex: 0xFFE08A),
                                        Color(hex: 0x8FE3FF), Color(hex: 0xFFB3E2)]
                for i in 0..<30 {
                    // cheap deterministic per-particle randomness
                    func rnd(_ k: Double) -> Double {
                        let v = sin(Double(i) * 12.9898 + k * 78.233) * 43758.5453
                        return v - v.rounded(.down)
                    }
                    let delay = rnd(1) * 0.25
                    let p = max(0, min(1, (t - delay) / (life - 0.4)))
                    guard p > 0 else { continue }
                    let ease = 1 - pow(1 - p, 3)
                    let ang = rnd(2) * .pi * 2
                    let dist = (60 + rnd(3) * 150) * ease
                    let pos = CGPoint(x: c.x + cos(ang) * dist,
                                      y: c.y + sin(ang) * dist * 0.9 - 30 * p)
                    let s = (2.5 + rnd(4) * 4) * (1 - p * 0.8)
                    ctx.opacity = (1 - p) * 0.95
                    ctx.fill(Path(ellipseIn: CGRect(x: pos.x - s / 2, y: pos.y - s / 2,
                                                    width: s, height: s)),
                             with: .color(palette[i % palette.count]))
                }
            }
        }
        .onAppear { start = Date() }
        .allowsHitTesting(false)
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
                .scaledFont(13, weight: .medium, design: .serif)
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

    @State private var showControls = false
    @State private var editing = false
    @State private var stampOnly = true    // open on the stamp/sticker itself
    @State private var hasPhoto = false    // an original photo was kept → offer 전체사진
    @State private var sharePayload: SharePayload?
    @State private var justCopied = false

    private var stamp: CollectedStamp? { collection.stamps.first { $0.id == stampID } }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let stamp {
                    if !stampOnly,
                       let original = collection.originalImage(for: stampID)?.normalizedUp() {
                        // 전체사진 — the plain original photo, no slot, no hole
                        Image(uiImage: original)
                            .resizable().scaledToFit()
                            .scaleEffect(x: collection.cropInfo(for: stampID)?.mirrored == true ? -1 : 1)
                            .ignoresSafeArea()
                            .transition(.opacity)
                    } else {
                        // the stamp / sticker pasted on a WHITE card — a positive
                        // sticker on white, not a shape punched out of a photo.
                        // (Transparent areas read as clean white, no "hole".)
                        let side = min(geo.size.width, geo.size.height) * 0.82
                        LiveArt(collection: collection, stamp: stamp, maxPixel: nil)
                            .padding(22)
                            .frame(width: side, height: side)
                            .background(RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(.white))
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                            .transition(.opacity)
                    }
                }

                if showControls { controls }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !stampOnly { withAnimation(.easeOut(duration: 0.22)) { stampOnly = true } }
                else { dismiss() }
            }
            .onAppear {
                hasPhoto = collection.hasOriginal(stampID)
                withAnimation(.easeIn(duration: 0.25)) { showControls = true }
            }
            .sheet(isPresented: $editing) {
                NavigationStack { StampDetailView(collection: collection, stampID: stampID) }
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(items: payload.items)
            }
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(28)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .accessibilityLabel("닫기")
                Spacer()
                if hasPhoto {
                    Button {
                        withAnimation(.easeOut(duration: 0.22)) { stampOnly.toggle() }
                    } label: {
                        Label(stampOnly ? String(localized: "전체사진") : String(localized: "우표만"), systemImage: stampOnly ? "photo" : "seal")
                            .scaledFont(15, weight: .semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                    }
                }
                Button { editing = true } label: {
                    Label("편집", systemImage: "pencil")
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            Spacer()
            // copy / share, always visible at the bottom of the viewer
            HStack(spacing: 12) {
                Button { copyStamp() } label: {
                    Label(justCopied ? String(localized: "복사됨!") : String(localized: "복사"),
                          systemImage: justCopied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                Button { shareStamp() } label: {
                    Label("공유", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(RevealActionChip())
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .transition(.opacity)
    }

    private func copyStamp() {
        collection.makeExport(for: stampID) { export in
            guard let export else { return }
            export.copy()
            Haptics.placed()
            withAnimation(.easeOut(duration: 0.15)) { justCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeOut(duration: 0.2)) { justCopied = false }
            }
        }
    }

    private func shareStamp() {
        collection.makeExport(for: stampID) { export in
            if let url = export?.url { sharePayload = SharePayload(items: [url]) }
        }
    }

}

/// 한 장의 캡처가 입을 수 있는 네 가지 모습. 원본 사진과 모션 마스터를
/// 영구 보관하므로 언제든 무손실로 갈아입을 수 있다.
enum StampStyle: String, CaseIterable, Identifiable {
    case stamp        // 우표 (정지, 톱니)
    case liveStamp    // 움직이는 우표
    case sticker      // 스티커 (배경 없음, 정지)
    case liveSticker  // 움직이는 스티커 (배경 없음)

    var id: String { rawValue }
    var title: String {
        switch self {
        case .stamp: return String(localized: "우표 모양")
        case .liveStamp: return String(localized: "움직이는 우표 모양")
        case .sticker: return String(localized: "오려낸 스티커")
        case .liveSticker: return String(localized: "움직이는 오려낸 스티커")
        }
    }
    var icon: String {
        switch self {
        case .stamp: return "square.dashed"
        case .liveStamp: return "livephoto"
        case .sticker: return "scissors"
        case .liveSticker: return "wand.and.stars"
        }
    }
    var needsMotion: Bool { self == .liveStamp || self == .liveSticker }

    // The two independent axes a look is composed from.
    var moving: Bool { self == .liveStamp || self == .liveSticker }   // 정지 ↔ 움직임
    var cutout: Bool { self == .sticker || self == .liveSticker }     // 우표(톱니) ↔ 스티커(배경 제거)
    static func make(moving: Bool, cutout: Bool) -> StampStyle {
        switch (moving, cutout) {
        case (false, false): return .stamp
        case (true,  false): return .liveStamp
        case (false, true):  return .sticker
        case (true,  true):  return .liveSticker
        }
    }
}

/// The decorating finishes ("inks") a stamp can take — each is applied to a
/// fresh re-render of the original photo, so switching is always lossless.
enum StampInk: String, CaseIterable, Identifiable {
    case original = "원본"
    case sepia = "세피아"
    case mono = "흑백"
    case faded = "빛바램"
    case chrome = "쨍하게"
    case process = "푸름"

    var id: String { rawValue }

    private static let context = CIContext()

    /// Runs the finish over an image, preserving the perforation alpha.
    func apply(to image: UIImage) -> UIImage {
        guard self != .original, let input = CIImage(image: image) else { return image }
        let filter: CIFilter?
        switch self {
        case .original: return image
        case .sepia:
            filter = CIFilter(name: "CISepiaTone")
            filter?.setValue(0.85, forKey: kCIInputIntensityKey)
        case .mono: filter = CIFilter(name: "CIPhotoEffectNoir")
        case .faded: filter = CIFilter(name: "CIPhotoEffectInstant")
        case .chrome: filter = CIFilter(name: "CIPhotoEffectChrome")
        case .process: filter = CIFilter(name: "CIPhotoEffectProcess")
        }
        filter?.setValue(input, forKey: kCIInputImageKey)
        guard let out = filter?.outputImage,
              let cg = Self.context.createCGImage(out, from: input.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
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
    @State private var showFullImage = false
    @State private var finish: StampInk = .original
    @State private var inkPreviews: [String: UIImage] = [:]
    @State private var sharePayload: SharePayload?
    @State private var justCopied = false
    @FocusState private var focused: Bool
    @ObservedObject private var plans = PunchingPlans.shared
    @State private var paywallFeature: PlanFeature?
    // 테두리 · 글자
    @State private var decor = StickerDecor()
    // 가장자리 손보기 화면의 재료
    @State private var edge: EdgeMaterial?
    @State private var labelText = ""
    @FocusState private var labelFocused: Bool

    private var stamp: CollectedStamp? { collection.stamps.first { $0.id == stampID } }
    private var albumLabel: String { stamp?.album ?? CollectionStore.defaultAlbum }

    var body: some View {
        ZStack {
            // one seamless cream sheet — no dark frame, no card outline
            LinearGradient(colors: [Color(hex: 0xFBFAF7), Color(hex: 0xECE8DF)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            // Scrolls when the keyboard is up or the note grows past the screen.
            ScrollView {
              VStack(spacing: 16) {
                if let stamp {
                    LiveArt(collection: collection, stamp: stamp, maxPixel: nil)
                        .frame(maxHeight: 190)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
                        // 원본에서 다시 만드는 동안
                        .overlay {
                            if collection.restyling.contains(stampID) {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(Color(hex: 0x6B5836))
                                    .padding(14)
                                    .background(Circle().fill(.ultraThinMaterial))
                                    .accessibilityLabel("스티커를 다시 만드는 중")
                            }
                        }
                        // press & hold to see the whole photo this stamp was cut from
                        .onLongPressGesture(minimumDuration: 0.3) {
                            guard collection.originalImage(for: stampID) != nil else { return }
                            Haptics.select()
                            showFullImage = true
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(stamp.caption.isEmpty ? String(localized: "스티커") : stamp.caption)
                        .accessibilityAddTraits(.isImage)
                        .accessibilityAction(named: "전체사진") {
                            guard collection.originalImage(for: stampID) != nil else { return }
                            showFullImage = true
                        }
                    if collection.originalImage(for: stampID) != nil {
                        Text("꾹 눌러 전체 사진 보기")
                            .scaledFont(11, weight: .medium, design: .rounded)
                            .foregroundStyle(Color(hex: 0x8C7A52))
                    }
                    // 쓰기가 맨 위: copy or share — a GIF if it moves, else a
                    // high-res transparent PNG in its current shape.
                    HStack(spacing: 12) {
                        Button { copySticker() } label: {
                            Label(justCopied ? String(localized: "복사됨!") : String(localized: "복사"),
                                  systemImage: justCopied ? "checkmark" : "doc.on.doc")
                        }
                        Button { exportSticker() } label: {
                            Label("공유", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(StampActionChip())
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                }
                styleSection
                inkSection
                decorSection
                if let stamp {
                    // when & where this stamp was made
                    VStack(spacing: 3) {
                        Text(stamp.createdAt.formatted(date: .long, time: .shortened))
                        if !stamp.place.isEmpty {
                            Label(stamp.place, systemImage: "mappin.and.ellipse")
                        }
                    }
                    .scaledFont(13, weight: .medium, design: .rounded)
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
                .scaledFont(17, weight: .medium, design: .serif)
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

                Button(role: .destructive) { showDelete = true } label: {
                    Label("이 스티커 지우기", systemImage: "trash")
                        .scaledFont(14, weight: .semibold, design: .rounded)
                        .foregroundStyle(Color(hex: 0xB0473E))
                }
                .padding(.top, 8)
              }
              .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("완료", systemImage: "checkmark") { save(); dismiss() }
            }
        }
        .alert("새 수집함", isPresented: $showNewAlbum) {
            TextField("수집함 이름", text: $newAlbumName)
            Button("취소", role: .cancel) { }
            Button("만들기") {
                if let name = collection.createAlbum(newAlbumName) {
                    collection.move(stampID, to: name)
                }
            }
        }
        .confirmationDialog("이 스티커를 삭제할까요?", isPresented: $showDelete,
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) { collection.delete(stampID); dismiss() }
            Button("취소", role: .cancel) { }
        }
        .onAppear {
            caption = stamp?.caption ?? ""
            finish = StampInk(rawValue: collection.finish(for: stampID) ?? "") ?? .original
            decor = collection.stickerDecor(for: stampID)
            labelText = decor.label
        }
        .onDisappear(perform: save)
        // the sheet is now a light cream sheet → light nav bar (dark, readable
        // toolbar items) instead of the old dark frame
        .preferredColorScheme(.light)
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
                                    .scaledFont(28)
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .accessibilityLabel("닫기")
                            Spacer()
                        }
                        .padding(.horizontal, 18).padding(.top, 8)
                        Spacer()
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showFullImage = false }
                .foldConfined()
            }
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
        .paywall($paywallFeature)
    }

    /// Offers the sticker to share/save — a GIF if it moves, else a
    /// full-resolution transparent PNG in its current look.
    private func exportSticker() {
        collection.makeExport(for: stampID) { export in
            if let url = export?.url { sharePayload = SharePayload(items: [url]) }
        }
    }

    /// Copies the sticker to the clipboard — a GIF if it moves, else a
    /// transparent PNG — so it pastes into Messages, Notes, etc. intact.
    private func copySticker() {
        collection.makeExport(for: stampID) { export in
            guard let export else { return }
            export.copy()
            Haptics.placed()
            withAnimation(.easeOut(duration: 0.15)) { justCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeOut(duration: 0.2)) { justCopied = false }
            }
        }
    }

    /// 모양(오려낸/우표) × 움직임(멈춤/움직임) — 언제든 갈아입기.
    private var styleSection: some View {
        // the picker labels its own two rows (모양 · 움직임)
        VStack(alignment: .leading, spacing: 8) {
            StampStylePicker(collection: collection, stampID: stampID, dark: false)
            // 오려낸 스티커만: 잘못 오려진 곳을 지우거나 되살린다
            if collection.style(for: stampID).cutout {
                Button {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let material = collection.edgeMaterial(for: stampID)
                        DispatchQueue.main.async { edge = material }
                    }
                } label: {
                    Label("오려낸 가장자리 손보기", systemImage: "eraser")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $edge) { material in
            EdgeEditView(material: material) { mask in
                collection.setCustomMask(mask, for: stampID)
            }
        }
    }

    /// 색감: a row of finishes, each chip a live mini preview of this stamp
    /// wearing that ink. Tapping re-renders losslessly from the original photo.
    private var inkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("색감")
                .scaledFont(12, weight: .bold, design: .rounded)
                .foregroundStyle(Color(hex: 0x8C7A52))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11) {
                    ForEach(StampInk.allCases) { ink in inkChip(ink) }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: buildInkPreviews)
    }

    /// 테두리(굵기 · 색)와 스티커에 얹는 글자 — 사진 앱 스티커에는 없는 손질.
    private var decorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("테두리 · 글자")
                .font(.body.weight(.bold))
                .fontDesign(.rounded)
                .foregroundStyle(Color(hex: 0x8C7A52))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StickerDecor.Outline.allCases) { o in
                        let on = decor.outline == o
                        Button {
                            var d = decor; d.outline = o; commitDecor(d)
                        } label: {
                            Text(o.title)
                                .font(.body.weight(.semibold))
                                .fontDesign(.rounded)
                                .foregroundStyle(Color(hex: on ? 0x42331E : 0x9A875E))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(Color.white.opacity(on ? 0.6 : 0.25)))
                                .overlay(Capsule().strokeBorder(on ? Color(hex: 0xB0863E)
                                                                   : Color(hex: 0xCBB585).opacity(0.6),
                                                                lineWidth: on ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            if decor.outline != .none || !decor.trimmedLabel.isEmpty {
                HStack(spacing: 12) {
                    ForEach(StickerDecor.palette, id: \.self) { hex in
                        let on = decor.color == hex
                        Button {
                            var d = decor; d.color = hex; commitDecor(d)
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 32, height: 32)
                                .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().strokeBorder(on ? Color(hex: 0xB0863E) : .clear, lineWidth: 2.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.colorName(hex))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            HStack(spacing: 10) {
                TextField("", text: $labelText,
                          prompt: Text("스티커에 넣을 글자").foregroundStyle(Color(hex: 0x9A875E)))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(hex: 0x42331E))
                    .tint(Color(hex: 0x42331E))
                    .focused($labelFocused)
                    .submitLabel(.done)
                    .onSubmit(commitLabel)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.4)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(hex: 0xCBB585), lineWidth: 1))
                if labelText.trimmingCharacters(in: .whitespacesAndNewlines) != decor.label {
                    Button("넣기", action: commitLabel)
                        .font(.body.weight(.bold))
                        .tint(Color(hex: 0x6B5836))
                }
            }
            .environment(\.colorScheme, .light)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitLabel() {
        labelFocused = false
        var d = decor
        d.label = String(labelText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        labelText = d.label
        commitDecor(d)
    }

    private func commitDecor(_ d: StickerDecor) {
        guard d != decor else { return }
        Haptics.tick()
        decor = d
        collection.setStickerDecor(d, for: stampID)
    }

    private static func colorName(_ hex: UInt32) -> String {
        switch hex {
        case 0xFFFFFF: return String(localized: "흰색")
        case 0x1C1C1E: return String(localized: "검은색")
        case 0xFFD60A: return String(localized: "노란색")
        case 0xFF6FAE: return String(localized: "분홍색")
        case 0x5AC8FA: return String(localized: "하늘색")
        default: return String(localized: "초록색")
        }
    }

    private func inkChip(_ ink: StampInk) -> some View {
        let selected = finish == ink
        let open = plans.allows(ink)
        // 잠긴 색감도 이 스티커에 입힌 미리보기로 보인다. 누르면 입히는 대신 Plus 를 보여 준다.
        return Button { if open { applyFinish(ink) } else { paywallFeature = .inks } } label: {
            VStack(spacing: 5) {
                Group {
                    if let img = inkPreviews[ink.rawValue] {
                        Image(uiImage: img).resizable().scaledToFit()
                    } else if let img = stamp?.image {
                        Image(uiImage: img).resizable().scaledToFit()
                            .opacity(0.35)   // placeholder until previews bake
                    }
                }
                .frame(width: 52, height: 62)
                .overlay(alignment: .topTrailing) {
                    if !open { PlanLockBadge(feature: .inks) }
                }
                Text(LocalizedStringKey(ink.rawValue))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: selected ? 0x42331E : 0x9A875E))
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.55 : 0.25)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color(hex: 0xB0863E) : Color(hex: 0xCBB585).opacity(0.6),
                              lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: finish)
    }

    /// Bake the six mini previews off-main from one small pristine render.
    private func buildInkPreviews() {
        guard inkPreviews.isEmpty, let stamp else { return }
        let base = collection.printStamp(for: stampID, longSidePx: 220) ?? stamp.image
        Task.detached(priority: .utility) {
            var out: [String: UIImage] = [:]
            for ink in StampInk.allCases { out[ink.rawValue] = ink.apply(to: base) }
            let done = out
            await MainActor.run { inkPreviews = done }
        }
    }

    /// Re-render the stamp from its original with the chosen finish — never
    /// stacking filters on filters — and save it everywhere.
    private func applyFinish(_ ink: StampInk) {
        guard stamp != nil, finish != ink else { return }
        finish = ink
        Haptics.tick()
        // 원본에서 모양 · 테두리 · 움직임까지 함께 다시 만든다 (오려낸 스티커가 우표 모양으로 바뀌지 않게)
        collection.applyFinish(ink, for: stampID)
    }

    /// Which collecting book this stamp sits in — switch it or start a new one.
    private var albumPicker: some View {
        Menu {
            ForEach(collection.albums.filter { $0 != (stamp?.album ?? "") }, id: \.self) { a in
                Button(a) { collection.move(stampID, to: a) }
            }
            Divider()
            Button("새 수집함…") {
                if plans.canCreateAlbum(having: collection.albums.count) {
                    newAlbumName = ""; showNewAlbum = true
                } else {
                    paywallFeature = .albums
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "book.closed")
                Text(albumLabel)
                Image(systemName: "chevron.down").scaledFont(11, weight: .bold)
            }
            .scaledFont(15, weight: .semibold, design: .rounded)
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

/// Tiny tactile feedback for picking up / putting down a stamp. `select` is a
/// crisp tap when a stamp opens; `deselect` is a softer one when it closes.
enum Haptics {
    static func select() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    static func deselect() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
    }
    /// A confirming buzz when a sticker lands somewhere (a new spot / another album).
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

/// A compact page indicator on a frosted pill: dots for a handful of pages,
/// "n / total" once there are too many for dots to read cleanly.
struct PageDots: View {
    let count: Int
    let current: Int
    var body: some View {
        Group {
            if count > 8 {
                Text("\(min(current, count - 1) + 1) / \(count)")
                    .scaledFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(.white)
                    .monospacedDigit()
            } else {
                HStack(spacing: 6) {
                    ForEach(0..<max(count, 1), id: \.self) { i in
                        Circle()
                            .fill(i == current ? Color.white : Color.white.opacity(0.32))
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
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
    /// When false the page-turn swipe is disabled (e.g. while dragging a stamp).
    var interactive: Bool = true
    let page: (Int) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .pageCurl,
                                      navigationOrientation: .horizontal)
        pvc.dataSource = interactive ? context.coordinator : nil
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
        // toggle the swipe-to-turn gesture (off while a stamp is being dragged)
        let wantSource = interactive ? coord : nil
        if (pvc.dataSource == nil) == interactive { pvc.dataSource = wantSource }
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
    /// Asset names of every built-in frame, in pick order. Only frames that
    /// actually ship AND process into a usable cut-out (a detectable window) are
    /// offered — a malformed asset is skipped rather than blanking the camera.
    /// Adding "StampFrame3" later just works once the asset exists.
    static let names: [String] = ["StampFrame", "StampFrame2"]
        .filter { UIImage(named: $0) != nil }   // cheap existence check; heavy
                                                // processing stays lazy in frame(named:)

    /// Falls back to the first available asset (or the original name).
    static var defaultName: String { names.first ?? "StampFrame" }

    static let selectionKey = "stampFrameName"

    /// The asset name of the frame the user has chosen (persisted). Invalid /
    /// missing selections fall back to the default so a removed asset can't
    /// leave the camera frameless.
    static var selectedName: String {
        let n = UserDefaults.standard.string(forKey: selectionKey) ?? defaultName
        return names.contains(n) ? n : defaultName
    }

    /// Processing each frame (flood-fill + mask) is expensive, so keep the
    /// result per asset name.
    private static var cache: [String: StampFrame] = [:]

    /// The processed frame for a given asset name (cached).
    static func frame(named name: String) -> StampFrame? {
        if let cached = cache[name] { return cached }
        guard let made = make(named: name) else { return nil }
        cache[name] = made
        return made
    }

    /// The currently-selected processed frame.
    static var frame: StampFrame? { frame(named: selectedName) }

    /// Aspect ratio (w / h) of the stamp window — used to center-crop an
    /// imported photo into the same proportions a capture would have.
    static var windowAspect: CGFloat {
        guard let frame else { return 1 }
        let img = frame.image.size
        let n = frame.windowRectNorm
        let h = n.height * img.height
        return h > 0 ? (n.width * img.width) / h : 1
    }
    /// A fixed mount drawn on top of the (pressable) stamp frame — it never
    /// scales or moves, so only the inner frame presses. Optional asset.
    static let staticImage: UIImage? = UIImage(named: "staticFrame")

    private static func make(named name: String) -> StampFrame? {
        guard let source = UIImage(named: name),
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

        // A frame can arrive two ways:
        //   • a clean cut-out PNG — transparent around the frame AND through the
        //     window (the original StampFrame); "clear" = low alpha.
        //   • an opaque frame on a light background, with a light (white) window
        //     (StampFrame2); there's no alpha to read, so "clear" = near-white.
        // We detect which by checking whether the border is actually transparent.
        let alphaThreshold: UInt8 = 20
        func alphaOf(_ p: Int) -> UInt8 { buffer[p * 4 + 3] }
        var borderClear = 0
        for x in 0..<w {
            if alphaOf(x) < alphaThreshold { borderClear += 1 }
            if alphaOf((h - 1) * w + x) < alphaThreshold { borderClear += 1 }
        }
        let usesAlpha = borderClear > w / 4   // a genuine transparent background

        // For an opaque frame the "empty" areas (the outer background AND the
        // window) are one flat light colour, while the frame body is a distinct
        // colour. So "clear" = a pixel close to the corner background colour —
        // not absolute white, so a cream/pink frame works as well as a white one.
        let bgR = Int(buffer[0]), bgG = Int(buffer[1]), bgB = Int(buffer[2])
        let colorTol2 = 48 * 48
        func isClear(_ p: Int) -> Bool {
            if usesAlpha { return alphaOf(p) < alphaThreshold }
            let dr = Int(buffer[p * 4]) - bgR
            let dg = Int(buffer[p * 4 + 1]) - bgG
            let db = Int(buffer[p * 4 + 2]) - bgB
            return dr * dr + dg * dg + db * db < colorTol2
        }

        // flood the exterior background inward from every border pixel
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

        // The window is the LARGEST enclosed clear region (not connected to the
        // border) — taking the largest component ignores stray light specks in
        // the frame's decoration, which would otherwise blow up the bounding box.
        var visited = [Bool](repeating: false, count: w * h)
        var bestMinX = 0, bestMinY = 0, bestMaxX = -1, bestMaxY = -1
        var bestComp = [Int]()
        var comp = [Int]()
        for start in 0..<(w * h) where isClear(start) && !exterior[start] && !visited[start] {
            comp.removeAll(keepingCapacity: true)
            visited[start] = true
            var qi = 0
            comp.append(start)
            var cMinX = w, cMinY = h, cMaxX = -1, cMaxY = -1
            while qi < comp.count {
                let p = comp[qi]; qi += 1
                let x = p % w, y = p / w
                if x < cMinX { cMinX = x }; if x > cMaxX { cMaxX = x }
                if y < cMinY { cMinY = y }; if y > cMaxY { cMaxY = y }
                func grow(_ q: Int) {
                    if isClear(q) && !exterior[q] && !visited[q] { visited[q] = true; comp.append(q) }
                }
                if x > 0 { grow(p - 1) }
                if x < w - 1 { grow(p + 1) }
                if y > 0 { grow(p - w) }
                if y < h - 1 { grow(p + w) }
            }
            if comp.count > bestComp.count {
                bestComp = comp
                bestMinX = cMinX; bestMinY = cMinY; bestMaxX = cMaxX; bestMaxY = cMaxY
            }
        }
        var windowMask = [Bool](repeating: false, count: w * h)
        for q in bestComp { windowMask[q] = true }
        guard bestMaxX >= bestMinX, bestMaxY >= bestMinY else { return nil }
        let bw = bestMaxX - bestMinX + 1, bh = bestMaxY - bestMinY + 1

        let rectNorm = CGRect(
            x: CGFloat(bestMinX) / CGFloat(w), y: CGFloat(bestMinY) / CGFloat(h),
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

        // A cut-out PNG is already see-through, so use it as-is. An opaque frame
        // has to be punched: make the exterior background AND the window
        // transparent so the live camera shows through, while keeping the frame
        // body intact (stray light specks in the decoration stay opaque).
        let frameImage: UIImage
        if usesAlpha {
            frameImage = source
        } else {
            let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
            defer { outBuf.deallocate() }
            for i in 0..<(w * h) {
                if exterior[i] || windowMask[i] {
                    outBuf[i * 4 + 0] = 0; outBuf[i * 4 + 1] = 0
                    outBuf[i * 4 + 2] = 0; outBuf[i * 4 + 3] = 0
                } else {
                    outBuf[i * 4 + 0] = buffer[i * 4 + 0]
                    outBuf[i * 4 + 1] = buffer[i * 4 + 1]
                    outBuf[i * 4 + 2] = buffer[i * 4 + 2]
                    outBuf[i * 4 + 3] = 255
                }
            }
            guard let outCtx = CGContext(
                data: outBuf, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let outCG = outCtx.makeImage() else { return nil }
            frameImage = UIImage(cgImage: outCG, scale: source.scale,
                                 orientation: source.imageOrientation)
        }

        return StampFrame(image: frameImage, windowRectNorm: rectNorm,
                          interiorMask: interiorMask)
    }
}

#Preview {
    ContentView()
}
