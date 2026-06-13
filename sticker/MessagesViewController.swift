//
//  MessagesViewController.swift
//  sticker — StampCamera's iMessage sticker tray
//
//  Shows the stamps collected in the main app (written into the shared App
//  Group container) as real iMessage stickers you can peel onto messages.
//  A chip bar up top filters by the user's curated collections, so each
//  컬렉션 doubles as a sticker pack.
//

import UIKit
import Messages

private let appGroupID = "group.com.devkoan.StampCamera"

/// One curated collection exported by the main app (Stickers/collections.json).
private struct StickerPack: Decodable {
    let name: String
    let files: [String]
}
private struct PackManifest: Decodable {
    let collections: [StickerPack]
}

class MessagesViewController: MSMessagesAppViewController {

    private let browser = StampStickerBrowserViewController(stickerSize: .small)
    private let chipBar = UIScrollView()
    private let chipStack = UIStackView()
    private let emptyLabel = UILabel()
    private var packs: [StickerPack] = []
    private var selectedPack: Int = -1   // -1 = 전체

    override func viewDidLoad() {
        super.viewDidLoad()

        chipBar.showsHorizontalScrollIndicator = false
        chipBar.translatesAutoresizingMaskIntoConstraints = false
        chipStack.axis = .horizontal
        chipStack.spacing = 8
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipBar.addSubview(chipStack)
        view.addSubview(chipBar)

        addChild(browser)
        browser.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browser.view)
        browser.didMove(toParent: self)

        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        NSLayoutConstraint.activate([
            chipBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            chipBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chipBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipBar.heightAnchor.constraint(equalToConstant: 36),

            chipStack.topAnchor.constraint(equalTo: chipBar.contentLayoutGuide.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: chipBar.contentLayoutGuide.bottomAnchor),
            chipStack.leadingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.leadingAnchor, constant: 12),
            chipStack.trailingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.trailingAnchor, constant: -12),
            chipStack.heightAnchor.constraint(equalTo: chipBar.frameLayoutGuide.heightAnchor),

            browser.view.topAnchor.constraint(equalTo: chipBar.bottomAnchor, constant: 2),
            browser.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browser.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browser.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        reloadEverything()
    }

    private func reloadEverything() {
        packs = Self.loadPacks()
        if selectedPack >= packs.count { selectedPack = -1 }
        rebuildChips()
        browser.reload()
        applySelection()
        updateEmptyState()
    }

    /// Tells the user WHY the tray is empty: a missing App Group (the shared
    /// folder couldn't be reached — a signing/provisioning issue) vs. simply
    /// having made no stamps yet.
    private func updateEmptyState() {
        let hasContainer = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
        if !hasContainer {
            emptyLabel.text = "스티커를 공유하려면 ‘App Group’ 설정이 필요해요.\n(앱·확장 프로그램 서명 설정 확인)"
            emptyLabel.isHidden = false
        } else if browser.stickerCount == 0 {
            emptyLabel.text = "앱에서 우표·스티커를 만들면\n여기에 나타나요."
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    private static func loadPacks() -> [StickerPack] {
        guard let base = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return [] }
        let url = base.appendingPathComponent("Stickers/collections.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: data) else { return [] }
        return manifest.collections
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
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
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

    private func applySelection() {
        browser.filterFiles = selectedPack >= 0 ? packs[selectedPack].files : nil
    }
}

/// Loads the stamp PNGs from the shared App Group folder; `filterFiles`
/// narrows the tray to one collection (in its curated order).
final class StampStickerBrowserViewController: MSStickerBrowserViewController {
    private var all: [MSSticker] = []
    private var stickers: [MSSticker] = []

    /// How many stickers are currently shown (for the host's empty-state hint).
    var stickerCount: Int { stickers.count }

    var filterFiles: [String]? {
        didSet { applyFilter() }
    }

    func reload() {
        all = Self.loadStickers()
        applyFilter()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func applyFilter() {
        if let files = filterFiles {
            let byName = Dictionary(all.map { ($0.imageFileURL.lastPathComponent, $0) },
                                    uniquingKeysWith: { a, _ in a })
            stickers = files.compactMap { byName[$0] }
        } else {
            stickers = all
        }
        stickerBrowserView.reloadData()
    }

    private static func loadStickers() -> [MSSticker] {
        guard let base = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return [] }
        let dir = base.appendingPathComponent("Stickers", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        // Match the app's order: stamps are filed by creation time, encoded as
        // the leading millisecond timestamp in the filename ("<ms>.png.s6.png").
        // (Sorting by file modification date instead put them in regeneration
        // order, which didn't match the album.)
        func ms(_ u: URL) -> Double {
            Double(u.lastPathComponent.prefix { $0.isNumber }) ?? 0
        }
        let pngs = urls.filter { $0.pathExtension.lowercased() == "png" }
            .sorted { ms($0) > ms($1) }   // newest → oldest (most recent first)
        return pngs.compactMap { try? MSSticker(contentsOfFileURL: $0, localizedDescription: "컬렉션") }
    }

    override func numberOfStickers(in stickerBrowserView: MSStickerBrowserView) -> Int {
        stickers.count
    }
    override func stickerBrowserView(_ stickerBrowserView: MSStickerBrowserView,
                                     stickerAt index: Int) -> MSSticker {
        stickers[index]
    }
}
