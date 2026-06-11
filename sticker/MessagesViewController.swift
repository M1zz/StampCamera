//
//  MessagesViewController.swift
//  sticker — StampCamera's iMessage sticker tray
//
//  Shows the stamps collected in the main app (written into the shared App Group
//  container) as real iMessage stickers you can peel onto messages.
//

import UIKit
import Messages

private let appGroupID = "group.com.devkoan.StampCamera"

class MessagesViewController: MSMessagesAppViewController {

    private let browser = StampStickerBrowserViewController(stickerSize: .regular)

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(browser)
        browser.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browser.view)
        NSLayoutConstraint.activate([
            browser.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browser.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browser.view.topAnchor.constraint(equalTo: view.topAnchor),
            browser.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        browser.didMove(toParent: self)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        browser.reload()   // pick up any newly collected stamps
    }
}

/// Loads the stamp PNGs from the shared App Group folder, newest first.
final class StampStickerBrowserViewController: MSStickerBrowserViewController {
    private var stickers: [MSSticker] = []

    func reload() {
        stickers = Self.loadStickers()
        stickerBrowserView.reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private static func loadStickers() -> [MSSticker] {
        guard let base = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return [] }
        let dir = base.appendingPathComponent("Stickers", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let pngs = urls.filter { $0.pathExtension.lowercased() == "png" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b   // newest first
            }
        return pngs.compactMap { try? MSSticker(contentsOfFileURL: $0, localizedDescription: "우표") }
    }

    override func numberOfStickers(in stickerBrowserView: MSStickerBrowserView) -> Int {
        stickers.count
    }
    override func stickerBrowserView(_ stickerBrowserView: MSStickerBrowserView,
                                     stickerAt index: Int) -> MSSticker {
        stickers[index]
    }
}
