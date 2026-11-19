//
//  StickerArchive.swift
//  StampCamera
//
//  스티커를 '내 파일'로 — 사진 앱 스티커가 백업 복원 · iCloud 동기화에서 사라지는 문제의 반대편.
//
//  `.kkuk` 파일 하나에 스티커(그림 · 원본 사진 · 움직임 · 한 마디 · 메타)를 통째로 담는다.
//  - 전체 백업: 수집함 전부 + albums.json. 파일 앱 · iCloud Drive · AirDrop 어디로든 옮긴다.
//  - 수집함 보내기: 수집함 하나만. 받은 사람이 열면 같은 이름의 수집함으로 들어온다.
//  둘 다 같은 형식이라 가져오기는 하나뿐이고, 언제나 '더하기'만 한다 (이미 있는 스티커는 건너뛴다).
//
//  형식: Apple Archive(lzfse). 받는 파일은 남이 만든 것일 수 있으므로 압축을 그대로 풀지 않고
//  항목을 하나씩 읽어, 정해진 이름 꼴의 일반 파일만 받아들인다 (경로 탈출 · 링크 · 과대 파일 차단).
//

import Foundation
import AppleArchive
import System
import UniformTypeIdentifiers
import UIKit

extension UTType {
    /// 펀칭 스티커 묶음(.kkuk). Info.plist 의 UTExportedTypeDeclarations 와 짝.
    static let punchingStickers = UTType(exportedAs: "com.devkoan.StampCamera.stickers", conformingTo: .data)
}

enum StickerArchive {
    static let fileExtension = "kkuk"
    static let manifestName = "manifest.json"

    struct Manifest: Codable {
        enum Kind: String, Codable { case backup, pack }
        var version = 1
        var kind: Kind
        /// pack 일 때 수집함 이름
        var album: String?
        var count: Int
        var created = Date()
    }

    enum Failure: LocalizedError {
        case unreadable, notOurs, tooLarge
        var errorDescription: String? {
            switch self {
            case .unreadable: return String(localized: "파일을 읽을 수 없어요.")
            case .notOurs: return String(localized: "펀칭에서 만든 스티커 파일이 아니에요.")
            case .tooLarge: return String(localized: "파일이 너무 커서 열 수 없어요.")
            }
        }
    }

    // 받아들이는 이름 꼴 — 스티커 id 는 "<epoch_ms>.png"
    private static let allowed: [NSRegularExpression] = [
        #"^\d{1,16}\.png$"#,
        #"^\d{1,16}\.png\.(txt|grp|json|orig\.jpg|live\.png)$"#,
        #"^\d{1,16}\.png\.frames/\d{1,4}\.jpg$"#,
        #"^albums\.json$"#,
        #"^manifest\.json$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func isAllowed(_ path: String) -> Bool {
        let range = NSRange(path.startIndex..., in: path)
        return allowed.contains { $0.firstMatch(in: path, range: range) != nil }
    }

    private static let perFileLimit: UInt64 = 200 << 20      // 200MB
    private static let totalLimit: UInt64 = 8 << 30          // 8GB
    private static let entryLimit = 200_000

    private static let typKey = ArchiveHeader.FieldKey("TYP")
    private static let patKey = ArchiveHeader.FieldKey("PAT")
    private static let datKey = ArchiveHeader.FieldKey("DAT")

    /// `files`(묶음 안 경로, 원본 파일)를 `url` 에 쓴다. 무거우므로 메인 스레드 밖에서 부른다.
    static func write(files: [(path: String, source: URL)], manifest: Manifest, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let file = ArchiveByteStream.fileStream(path: FilePath(url.path), mode: .writeOnly,
                                                      options: [.create, .truncate],
                                                      permissions: FilePermissions(rawValue: 0o644)),
              let compress = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file),
              let encode = ArchiveStream.encodeStream(writingTo: compress)
        else { throw Failure.unreadable }

        func put(_ path: String, _ data: Data) throws {
            let header = ArchiveHeader()
            header.append(.uint(key: typKey, value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
            header.append(.string(key: patKey, value: path))
            header.append(.blob(key: datKey, size: UInt64(data.count)))
            try encode.writeHeader(header)
            try data.withUnsafeBytes { try encode.writeBlob(key: datKey, from: $0) }
        }

        var failure: Error?
        do {
            try put(manifestName, try JSONEncoder().encode(manifest))
            for f in files {
                // 사이에 지워진 파일은 조용히 건너뛴다
                guard let data = try? Data(contentsOf: f.source, options: .mappedIfSafe) else { continue }
                try put(f.path, data)
            }
        } catch { failure = error }
        // 닫는 순서: 안쪽부터
        try? encode.close()
        try? compress.close()
        try? file.close()
        if let failure {
            try? FileManager.default.removeItem(at: url)
            throw failure
        }
    }

    /// 묶음을 `dest`(빈 폴더)에 풀고 manifest 를 돌려준다. 허용된 일반 파일만 쓴다.
    static func read(_ url: URL, into dest: URL) throws -> Manifest {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(url.path), mode: .readOnly,
                                                      options: [],
                                                      permissions: FilePermissions(rawValue: 0o644)),
              let decompress = ArchiveByteStream.decompressionStream(readingFrom: file),
              let decode = ArchiveStream.decodeStream(readingFrom: decompress)
        else { throw Failure.unreadable }
        defer {
            try? decode.close()
            try? decompress.close()
            try? file.close()
        }

        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var manifest: Manifest?
        var total: UInt64 = 0
        var entries = 0

        while true {
            let header: ArchiveHeader?
            do { header = try decode.readHeader() } catch { throw Failure.unreadable }
            guard let header else { break }
            entries += 1
            guard entries <= entryLimit else { throw Failure.tooLarge }

            var path: String?
            var size: UInt64 = 0
            var isFile = false
            if case let .string(_, value)? = header.field(forKey: patKey) { path = value }
            if case let .blob(_, s, _)? = header.field(forKey: datKey) { size = s }
            if case let .uint(_, value)? = header.field(forKey: typKey) {
                isFile = value == UInt64(ArchiveHeader.EntryType.regularFile.rawValue)
            }
            // 데이터가 있는 항목은 읽든 버리든 반드시 소비해야 다음 헤더로 간다
            guard size <= perFileLimit else { throw Failure.tooLarge }
            total += size
            guard total <= totalLimit else { throw Failure.tooLarge }
            var data = Data(count: Int(size))
            if size > 0 {
                do { try data.withUnsafeMutableBytes { try decode.readBlob(key: datKey, into: $0) } }
                catch { throw Failure.unreadable }
            }
            guard isFile, let path, isAllowed(path) else { continue }

            if path == manifestName {
                manifest = try? JSONDecoder().decode(Manifest.self, from: data)
                continue
            }
            let out = dest.appendingPathComponent(path)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: out)
        }
        guard let manifest else { throw Failure.notOurs }
        return manifest
    }

    /// 파일 이름에 못 쓰는 글자를 바꾼다.
    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Stickers" : String(cleaned.prefix(60))
    }
}

/// 가져오기 결과 — 몇 장이 들어왔고, 몇 장은 이미 있어 건너뛰었는지.
struct StickerImportResult: Identifiable {
    let id = UUID()
    let added: Int
    let skipped: Int
    let albums: [String]
}
