//
//  TestSupport.swift
//  StampCameraTests
//
//  Shared helpers: isolated stores backed by temp directories, and tiny images.
//

import Foundation
import UIKit
@testable import StampCamera

enum TestSupport {
    /// A small solid-colour image to stand in for stamp / original payloads.
    static func image(_ color: UIColor = .red, size: CGSize = CGSize(width: 12, height: 12)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}

/// Wraps a `CollectionStore` pointed at a throwaway temp directory so each test
/// is fully isolated and can be re-opened to check persistence.
final class Harness {
    let dir: URL
    let store: CollectionStore

    init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SCTests-\(UUID().uuidString)", isDirectory: true)
        store = CollectionStore(directory: dir)
    }

    /// Re-open the same directory in a fresh store (to verify what was persisted).
    func reopen() -> CollectionStore { CollectionStore(directory: dir) }

    /// Add a stamp; sleeps briefly so the next add gets a distinct millisecond id.
    @discardableResult
    func add(_ color: UIColor = .red,
             original: UIImage? = nil,
             cropNorm: CGRect? = nil,
             mirrored: Bool = false) -> String {
        let id = store.add(TestSupport.image(color), original: original,
                           cropNorm: cropNorm, mirrored: mirrored)
        Thread.sleep(forTimeInterval: 0.002)
        return id
    }

    func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}
