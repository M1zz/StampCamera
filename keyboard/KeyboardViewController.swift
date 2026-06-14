//
//  KeyboardViewController.swift
//  keyboard — StampCamera's system-wide sticker keyboard
//
//  A custom keyboard that surfaces the same stamps the app exports into the
//  shared App Group (Stickers/*.gif + collections.json) so they can be used in
//  ANY app, not just iMessage. Custom keyboards can't insert images into a text
//  field, so tapping a sticker COPIES it to the pasteboard and the user pastes
//  it — exactly how Bitmoji and other sticker keyboards work.
//
//  Requires "전체 접근 허용 (Allow Full Access)": without it iOS blocks both the
//  App Group container (so there are no stickers to show) and the system
//  pasteboard (so copying can't work). We detect that and tell the user.
//

import UIKit
import UniformTypeIdentifiers

private let appGroupID = "group.com.devkoan.StampCamera"

/// One curated collection exported by the main app (Stickers/collections.json).
private struct StickerPack: Decodable {
    let name: String
    let files: [String]
}
private struct PackManifest: Decodable {
    let collections: [StickerPack]
}

class KeyboardViewController: UIInputViewController {

    private var nextKeyboardButton: UIButton!
    private let chipBar = UIScrollView()
    private let chipStack = UIStackView()
    private var collectionView: UICollectionView!
    private let toast = UILabel()
    private let emptyLabel = UILabel()
    private var heightConstraint: NSLayoutConstraint?

    /// All sticker file URLs (newest first) and the curated packs.
    private var allURLs: [URL] = []
    private var packs: [StickerPack] = []
    private var selectedPack = -1          // -1 = 전체
    /// The URLs currently shown, after the collection filter is applied.
    private var shown: [URL] = []
    /// Decoded animated images, cached by file URL so scrolling doesn't re-decode.
    private var imageCache: [URL: UIImage] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        buildBottomBar()
        buildChipBar()
        buildGrid()
        buildEmptyLabel()
        buildToast()

        NSLayoutConstraint.activate([
            chipBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            chipBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chipBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipBar.heightAnchor.constraint(equalToConstant: 34),

            chipStack.topAnchor.constraint(equalTo: chipBar.contentLayoutGuide.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: chipBar.contentLayoutGuide.bottomAnchor),
            chipStack.leadingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.leadingAnchor, constant: 10),
            chipStack.trailingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.trailingAnchor, constant: -10),
            chipStack.heightAnchor.constraint(equalTo: chipBar.frameLayoutGuide.heightAnchor),

            collectionView.topAnchor.constraint(equalTo: chipBar.bottomAnchor, constant: 2),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: nextKeyboardButton.topAnchor),

            nextKeyboardButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            nextKeyboardButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            nextKeyboardButton.heightAnchor.constraint(equalToConstant: 36),

            emptyLabel.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: nextKeyboardButton.topAnchor, constant: -10),
            toast.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()
        // The default custom-keyboard height is too short for a sticker grid —
        // pin a comfortable height once.
        if heightConstraint == nil {
            let h = view.heightAnchor.constraint(equalToConstant: 280)
            h.priority = .init(999)
            h.isActive = true
            heightConstraint = h
        }
    }

    override func viewWillLayoutSubviews() {
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
        super.viewWillLayoutSubviews()
    }

    // MARK: - Build UI

    private func buildBottomBar() {
        nextKeyboardButton = UIButton(type: .system)
        nextKeyboardButton.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboardButton.tintColor = .label
        nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false
        // The system handles switching keyboards on this control event.
        nextKeyboardButton.addTarget(self,
                                     action: #selector(handleInputModeList(from:with:)),
                                     for: .allTouchEvents)
        view.addSubview(nextKeyboardButton)
    }

    private func buildChipBar() {
        chipBar.showsHorizontalScrollIndicator = false
        chipBar.translatesAutoresizingMaskIntoConstraints = false
        chipStack.axis = .horizontal
        chipStack.spacing = 8
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipBar.addSubview(chipStack)
        view.addSubview(chipBar)
    }

    private func buildGrid() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.register(StickerCell.self, forCellWithReuseIdentifier: StickerCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    private func buildEmptyLabel() {
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)
    }

    private func buildToast() {
        toast.font = .systemFont(ofSize: 13, weight: .semibold)
        toast.textColor = .white
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        toast.textAlignment = .center
        toast.layer.cornerRadius = 15
        toast.clipsToBounds = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.alpha = 0
        view.addSubview(toast)
    }

    // MARK: - Data

    private func reload() {
        // Full Access gates BOTH the App Group container and the pasteboard, so
        // without it the keyboard can do nothing useful — say so plainly.
        guard hasFullAccess else {
            allURLs = []; packs = []; shown = []
            chipBar.isHidden = true
            collectionView.reloadData()
            emptyLabel.text = "스티커를 쓰려면 ‘전체 접근 허용’을 켜주세요.\n설정 ▸ 일반 ▸ 키보드 ▸ 펀칭 스티커 ▸ 전체 접근 허용"
            emptyLabel.isHidden = false
            return
        }
        allURLs = Self.loadStickerURLs()
        packs = Self.loadPacks()
        if selectedPack >= packs.count { selectedPack = -1 }
        rebuildChips()
        applySelection()
    }

    private static func loadStickerURLs() -> [URL] {
        guard let base = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return [] }
        let dir = base.appendingPathComponent("Stickers", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        // Match the app's order: stamps are filed by creation time, encoded as
        // the leading millisecond timestamp in the filename.
        func ms(_ u: URL) -> Double { Double(u.lastPathComponent.prefix { $0.isNumber }) ?? 0 }
        return urls.filter { ["gif", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { ms($0) > ms($1) }
    }

    private static func loadPacks() -> [StickerPack] {
        guard let base = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return [] }
        let url = base.appendingPathComponent("Stickers/collections.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: data) else { return [] }
        return manifest.collections
    }

    private func applySelection() {
        if selectedPack >= 0 {
            let names = Set(packs[selectedPack].files)
            shown = allURLs.filter { names.contains($0.lastPathComponent) }
        } else {
            shown = allURLs
        }
        if shown.isEmpty {
            emptyLabel.text = "앱에서 우표·스티커를 만들면\n여기에 나타나요."
        }
        emptyLabel.isHidden = !shown.isEmpty
        collectionView.reloadData()
    }

    // MARK: - Chips

    private func rebuildChips() {
        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chipBar.isHidden = packs.isEmpty
        guard !packs.isEmpty else { return }
        addChip(title: "전체", tag: -1)
        for (i, pack) in packs.enumerated() { addChip(title: pack.name, tag: i) }
        styleChips()
    }

    private func addChip(title: String, tag: Int) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        let button = UIButton(configuration: config)
        button.tag = tag
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
        chipStack.addArrangedSubview(button)
    }

    @objc private func chipTapped(_ sender: UIButton) {
        selectedPack = sender.tag
        styleChips()
        applySelection()
    }

    private func styleChips() {
        for case let button as UIButton in chipStack.arrangedSubviews {
            let on = button.tag == selectedPack
            button.configuration?.baseBackgroundColor = on
                ? UIColor(red: 0.95, green: 0.70, blue: 0.23, alpha: 1)
                : UIColor.secondarySystemFill
            button.configuration?.baseForegroundColor = on ? .black : .label
        }
    }

    // MARK: - Copy to pasteboard

    private func copySticker(at url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let isGIF = url.pathExtension.lowercased() == "gif"
        // Offer the animated GIF first; also attach a still PNG so paste targets
        // that don't take GIF still get an image.
        var item: [String: Any] = [:]
        if isGIF {
            item[UTType.gif.identifier] = data
            if let still = Self.firstFramePNG(from: data) { item[UTType.png.identifier] = still }
        } else {
            item[UTType.png.identifier] = data
        }
        UIPasteboard.general.setItems([item], options: [:])
        flashToast()
    }

    private func flashToast() {
        toast.text = "  복사됨 — 붙여넣기 하세요  "
        toast.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.15) { self.toast.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 1.1) { self.toast.alpha = 0 }
    }

    // MARK: - GIF decoding

    /// Decodes a GIF (or PNG) file into an animated UIImage for display.
    private func image(for url: URL) -> UIImage? {
        if let cached = imageCache[url] { return cached }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let img = Self.animatedImage(from: data) ?? UIImage(data: data)
        if let img { imageCache[url] = img }
        return img
    }

    /// Builds a looping UIImage from animated image data, honouring per-frame
    /// delays; returns nil for a single-frame (still) file.
    static func animatedImage(from data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return nil }
        var frames: [UIImage] = []
        var total: Double = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            total += frameDelay(src, i)
        }
        guard frames.count > 1 else { return nil }
        return UIImage.animatedImage(with: frames, duration: total > 0 ? total : Double(frames.count) * 0.1)
    }

    private static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
        if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let t = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, t > 0 { return t }
            if let t = gif[kCGImagePropertyGIFDelayTime] as? Double, t > 0 { return t }
        }
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           let t = png[kCGImagePropertyAPNGDelayTime] as? Double, t > 0 { return t }
        return 0.1
    }

    static func firstFramePNG(from data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return UIImage(cgImage: cg).pngData()
    }
}

// MARK: - Collection view

extension KeyboardViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        shown.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: StickerCell.reuseID, for: indexPath) as! StickerCell
        cell.imageView.image = image(for: shown[indexPath.item])
        return cell
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        // 4 per row, square.
        let columns: CGFloat = 4
        let insets: CGFloat = 10 + 10
        let gaps: CGFloat = 8 * (columns - 1)
        let side = max(40, ((cv.bounds.width - insets - gaps) / columns).rounded(.down))
        return CGSize(width: side, height: side)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        cv.deselectItem(at: indexPath, animated: false)
        copySticker(at: shown[indexPath.item])
    }
}

// MARK: - Cell

private final class StickerCell: UICollectionViewCell {
    static let reuseID = "StickerCell"
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
    }
}
