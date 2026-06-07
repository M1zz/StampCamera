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
    @State private var flash = false
    @State private var dropped = false   // cropped piece dropped out of the frame
    @State private var pressed = false

    // newly-made stamp pending a caption on the parchment editor
    @State private var editTarget: EditTarget?

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
                        .position(flyToBin ? landing
                                           : CGPoint(x: flyStart.midX, y: flyStart.midY))
                        // the cut piece drops down a touch with a "톡" before flying off
                        .offset(y: flyToBin ? 0 : (dropped ? 22 : 0))
                        .allowsHitTesting(false)
                }

                // shutter flash
                Color.white
                    .ignoresSafeArea()
                    .opacity(flash ? 0.85 : 0)
                    .allowsHitTesting(false)

                bottomBar
            }
            .coordinateSpace(name: "cam")
            .onPreferenceChange(BinCenterKey.self) { binCenter = $0 }
            .onAppear { previewSize = geo.size }
            .onChange(of: geo.size) { _, s in previewSize = s }
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
            // 찰칵 — flash + take the photo at the bottom of the press
            withAnimation(.easeOut(duration: 0.06)) { flash = true }
            camera.capturePhoto()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeIn(duration: 0.2)) { flash = false }
            }
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
              let frame = StampFrameLoader.frame,
              previewSize != .zero else { return }
        let win = windowScreenRect(in: previewSize)
        guard let stamp = StampCompositor.makeStamp(
            from: raw,
            previewSize: previewSize,
            windowRect: win,
            mask: frame.windowMask,
            mirrored: camera.position == .front
        ) else { return }

        // The cropped piece detaches and drops with a little "톡"...
        flyStart = win
        flyToBin = false
        dropped = false
        flying = stamp
        withAnimation(.spring(response: 0.26, dampingFraction: 0.5)) { dropped = true }

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

// MARK: - Collection grid

struct CollectionView: View {
    @ObservedObject var collection: CollectionStore
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if collection.stamps.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("아직 모은 우표가 없어요")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 100)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(collection.stamps) { stamp in
                            NavigationLink {
                                StampDetailView(collection: collection, stampID: stamp.id)
                            } label: {
                                ParchmentCard(stamp: stamp)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
            .background(Color(hex: 0x141210).ignoresSafeArea())
            .navigationTitle("내 컬렉션")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Collection store (disk-backed)

struct CollectedStamp: Identifiable {
    let id: String
    let image: UIImage
    var caption: String
}

final class CollectionStore: ObservableObject {
    @Published private(set) var stamps: [CollectedStamp] = []
    private let dir: URL

    init() {
        dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Collection", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    private func captionURL(for id: String) -> URL {
        dir.appendingPathComponent(id).appendingPathExtension("txt")
    }

    private func load() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        stamps = urls
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let image = UIImage(contentsOfFile: url.path) else { return nil }
                let caption = (try? String(contentsOf: url.appendingPathExtension("txt"),
                                           encoding: .utf8)) ?? ""
                return CollectedStamp(id: url.lastPathComponent, image: image, caption: caption)
            }
    }

    @discardableResult
    func add(_ image: UIImage) -> String {
        let name = "\(Int(Date().timeIntervalSince1970 * 1000)).png"
        let url = dir.appendingPathComponent(name)
        if let data = image.pngData() { try? data.write(to: url) }
        stamps.append(CollectedStamp(id: name, image: image, caption: ""))
        return name
    }

    func setCaption(_ text: String, for id: String) {
        guard let idx = stamps.firstIndex(where: { $0.id == id }) else { return }
        stamps[idx].caption = text
        try? text.write(to: captionURL(for: id), atomically: true, encoding: .utf8)
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
                Text(String(format: "%.1f×", camera.zoom))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.65)))
                    .offset(y: -40)
            }
        }
        .scaleEffect(dialing ? 1.08 : 1)
        .animation(.easeOut(duration: 0.15), value: dialing)
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
                    // swipe right or up = zoom in; exponential feels natural
                    let delta = (drag.translation.width - drag.translation.height) / 160
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
                .rotationEffect(.degrees(-2.5))
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
    @FocusState private var focused: Bool

    private var stamp: CollectedStamp? { collection.stamps.first { $0.id == stampID } }

    var body: some View {
        ZStack {
            Color(hex: 0x241F18).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    if let stamp {
                        Image(uiImage: stamp.image)
                            .resizable().scaledToFit()
                            .frame(maxWidth: 240, maxHeight: 300)
                            .rotationEffect(.degrees(-2.5))
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
                            .padding(.top, 12)
                    }
                    TextField("몇 마디 적어보세요…", text: $caption, axis: .vertical)
                        .font(.system(size: 18, weight: .medium, design: .serif))
                        .foregroundStyle(Color(hex: 0x42331E))
                        .tint(Color(hex: 0x42331E))
                        .multilineTextAlignment(.center)
                        .lineLimit(1...5)
                        .focused($focused)
                        .padding(.vertical, 8)
                        .padding(.bottom, 12)
                }
                .padding(28)
                .background(Parchment(cornerRadius: 20))
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("완료") { save(); dismiss() }
            }
        }
        .onAppear { caption = stamp?.caption ?? "" }
        .onDisappear(perform: save)
        .preferredColorScheme(.dark)
    }

    private func save() { collection.setCaption(caption, for: stampID) }
}

struct EditTarget: Identifiable {
    let id: String
}

// MARK: - Stamp frame cut-out (background removal + window mask)

/// The processed `stampFrame` asset: the frame with its background and inner
/// window removed, plus the window's shape mask and position for cropping.
struct StampFrame {
    let image: UIImage          // cut-out frame (transparent bg + window)
    let windowMask: UIImage     // white = window shape, clear elsewhere
    let windowRectNorm: CGRect  // window bounding box in 0...1 image coords
}

enum StampFrameLoader {
    static let frame: StampFrame? = make()

    private static func make() -> StampFrame? {
        guard let source = UIImage(named: "stampFrame"),
              let cg = source.cgImage else { return nil }

        let w = cg.width, h = cg.height
        let bytesPerRow = w * 4
        let count = w * h * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: count)

        guard let ctx = CGContext(
            data: buffer, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // region tag per pixel: 0 = kept, 1 = outer background, 2 = window
        var region = [UInt8](repeating: 0, count: w * h)
        let tolerance = 32

        func flood(from sx: Int, _ sy: Int, tag: UInt8) {
            let seed = (sy * w + sx) * 4
            let r0 = Int(buffer[seed]), g0 = Int(buffer[seed + 1]), b0 = Int(buffer[seed + 2])
            var stack = [(sx, sy)]
            while let (x, y) = stack.popLast() {
                if x < 0 || x >= w || y < 0 || y >= h { continue }
                let p = y * w + x
                if region[p] != 0 { continue }
                let i = p * 4
                if abs(Int(buffer[i]) - r0) > tolerance ||
                   abs(Int(buffer[i + 1]) - g0) > tolerance ||
                   abs(Int(buffer[i + 2]) - b0) > tolerance { continue }
                region[p] = tag
                buffer[i] = 0; buffer[i + 1] = 0; buffer[i + 2] = 0; buffer[i + 3] = 0
                stack.append((x + 1, y)); stack.append((x - 1, y))
                stack.append((x, y + 1)); stack.append((x, y - 1))
            }
        }

        func luma(_ x: Int, _ y: Int) -> Int {
            let i = (y * w + x) * 4
            return (Int(buffer[i]) * 3 + Int(buffer[i + 1]) * 6 + Int(buffer[i + 2])) / 10
        }

        // outer background — flood from the four corners
        for (x, y) in [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)] {
            flood(from: x, y, tag: 1)
        }
        // inner window — flood from bright points near the center only
        for (fx, fy) in [(0.5, 0.40), (0.5, 0.45), (0.42, 0.45), (0.58, 0.45)] {
            let x = Int(Double(w) * fx), y = Int(Double(h) * fy)
            if region[y * w + x] == 0 && luma(x, y) > 200 { flood(from: x, y, tag: 2) }
        }

        guard let cutCG = ctx.makeImage() else { return nil }
        let cutout = UIImage(cgImage: cutCG, scale: source.scale, orientation: .up)

        // bounding box of the window region — where the photo gets cropped in
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where region[y * w + x] == 2 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let bw = maxX - minX + 1, bh = maxY - minY + 1

        // window shape mask: white where the window is, clear elsewhere
        let mBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bw * bh * 4)
        defer { mBuf.deallocate() }
        mBuf.initialize(repeating: 0, count: bw * bh * 4)
        for y in 0..<bh {
            for x in 0..<bw where region[(minY + y) * w + (minX + x)] == 2 {
                let i = (y * bw + x) * 4
                mBuf[i] = 255; mBuf[i + 1] = 255; mBuf[i + 2] = 255; mBuf[i + 3] = 255
            }
        }
        guard let mCtx = CGContext(
            data: mBuf, width: bw, height: bh,
            bitsPerComponent: 8, bytesPerRow: bw * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let maskCG = mCtx.makeImage() else { return nil }
        let mask = UIImage(cgImage: maskCG, scale: source.scale, orientation: .up)

        let rectNorm = CGRect(
            x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
            width: CGFloat(bw) / CGFloat(w), height: CGFloat(bh) / CGFloat(h))

        return StampFrame(image: cutout, windowMask: mask, windowRectNorm: rectNorm)
    }
}

#Preview {
    ContentView()
}
