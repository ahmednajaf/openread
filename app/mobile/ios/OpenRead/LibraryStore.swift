import Foundation
import Combine
import CryptoKit
import ZIPFoundation

enum AppFiles {
    static let group = Bundle.main.object(forInfoDictionaryKey: "OpenReadAppGroup") as? String ?? "group.dev.openread.mobile"
    static var sharingHint: String {
        #if OPENREAD_PERSONAL
        return "Paste text or import a document to start listening."
        #else
        return "Paste text, import a document or share something into OpenRead."
        #endif
    }
    static var root: URL {
        let local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenRead")
        #if OPENREAD_PERSONAL
        let base = local
        #else
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) ?? local
        #endif
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var url = base; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values); return base
    }
    static var inbox: URL { let url = root.appendingPathComponent("Inbox"); try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
    static var models: URL { root.appendingPathComponent("Models") }
}

// Shelf entries contain metadata only. One active book is loaded on demand;
// progress updates never rewrite its text or decode the rest of the library.
@MainActor final class LibraryStore: ObservableObject {
    private struct Entry: Codable {
        var reading: Reading
        var folder: String
        var chunks: Int
        var digest: String
    }
    @Published private(set) var readings: [Reading] = []
    @Published var error: String?
    private let root: URL
    private var entries: [Entry] = []
    private var indexURL: URL { root.appendingPathComponent("library-v2.json") }
    init(root: URL = AppFiles.root) {
        self.root = root
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                guard let size = try indexURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 10 * 1024 * 1024 else { throw ReadingError.invalidReading }
                entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: indexURL))
                guard entries.count <= 200, Set(entries.map { $0.reading.id }).count == entries.count,
                      entries.allSatisfy({ UUID(uuidString: $0.folder) != nil && (1...1000).contains($0.chunks) && $0.reading.text.isEmpty && $0.reading.textLength <= 20_000_000 }) else { throw ReadingError.invalidReading }
            } else {
                let legacy = root.appendingPathComponent("library.json")
                if FileManager.default.fileExists(atPath: legacy.path) {
                    let documents = try ReadingBackup.decode(Data(contentsOf: legacy)).documents
                    let migrated = try documents.map { try store($0) }; try publish(migrated)
                    // Keep the original library file for recovery after migration.
                }
            }
            readings = entries.map(\.reading)
        } catch { self.error = "Your library could not be opened. Its files have been kept for recovery." }
    }
    func load(_ id: String) throws -> Reading {
        guard let entry = entries.first(where: { $0.reading.id == id }) else { throw ReadingError.invalidReading }
        var reading = entry.reading; var text = ""
        for index in 0..<entry.chunks {
            let file = root.appendingPathComponent("Books/\(entry.folder)/\(index).txt")
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 300_000 else { throw ReadingError.invalidReading }
            text += try String(contentsOf: file, encoding: .utf8)
            guard text.utf16.count <= 20_000_000 else { throw ReadingError.invalidReading }
        }
        reading.text = text
        guard hash(text) == entry.digest, text.utf16.count == reading.textLength else { throw ReadingError.invalidReading }
        return try reading.validated
    }
    func save(_ reading: Reading) throws {
        guard error == nil else { throw ReadingError.invalidReading }
        var next = entries
        let existing = next.firstIndex(where: { $0.reading.id == reading.id })
        let entry: Entry
        if let existing, reading.text.isEmpty || hash(reading.text) == next[existing].digest {
            var update = next[existing]
            guard reading.position >= 0, reading.position <= update.reading.textLength, reading.bookmarks.count <= 200, reading.bookmarks.allSatisfy({ $0.offset >= 0 && $0.offset <= update.reading.textLength && $0.label.count <= 160 }) else { throw ReadingError.invalidReading }
            update.reading.position = reading.position; update.reading.bookmarks = reading.bookmarks; entry = update
        } else { entry = try store(reading) }
        defer { if !entries.contains(where: { $0.folder == entry.folder }) { try? FileManager.default.removeItem(at: root.appendingPathComponent("Books/\(entry.folder)")) } }
        if let existing { next[existing] = entry } else { guard next.count < 200 else { throw ReadingError.invalidReading }; next.insert(entry, at: 0) }
        try publish(next)
    }
    func position(_ id: String, _ offset: Int) throws {
        guard var reading = entries.first(where: { $0.reading.id == id })?.reading, reading.position != offset else { return }
        reading.position = offset; try save(reading)
    }
    func remove(_ id: String) throws {
        let removed = entries.filter { $0.reading.id == id }; try publish(entries.filter { $0.reading.id != id })
        for entry in removed { try? FileManager.default.removeItem(at: root.appendingPathComponent("Books/\(entry.folder)")) }
    }
    func restore(_ data: Data) throws {
        guard data.count <= 500 * 1024 * 1024 else { throw ReadingError.fileTooLarge }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".backup")
        try data.write(to: file); defer { try? FileManager.default.removeItem(at: file) }; try restore(file)
    }
    func restore(_ file: URL) throws {
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= 500 * 1024 * 1024 else { throw ReadingError.fileTooLarge }
        let handle = try FileHandle(forReadingFrom: file); let prefix = try handle.read(upToCount: 4) ?? Data(); try handle.close()
        var incoming: [Entry] = []; var ids = Set<String>()
        defer { for entry in incoming where !entries.contains(where: { $0.folder == entry.folder }) { try? FileManager.default.removeItem(at: root.appendingPathComponent("Books/\(entry.folder)")) } }
        func accept(_ reading: Reading) throws {
            guard ids.insert(reading.id).inserted, ids.count <= 200 else { throw ReadingError.invalidReading }
            incoming.append(try store(reading))
        }
        if prefix.starts(with: [0x50, 0x4b]) {
            let archive = try Archive(url: file, accessMode: .read); let members = Array(archive)
            guard members.count <= 200 else { throw ReadingError.invalidReading }; var expanded: UInt64 = 0
            for entry in members {
                guard entry.path.hasPrefix("readings/"), entry.path.hasSuffix(".json"), entry.uncompressedSize <= 100 * 1024 * 1024,
                      entry.uncompressedSize <= 500 * 1024 * 1024 - expanded else { throw ReadingError.invalidReading }
                expanded += entry.uncompressedSize
                var body = Data(); _ = try archive.extract(entry) { chunk in
                    guard body.count + chunk.count <= 100 * 1024 * 1024 else { throw ReadingError.fileTooLarge }; body.append(chunk)
                }
                try accept(JSONDecoder().decode(Reading.self, from: body).validated)
            }
        } else {
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= 25 * 1024 * 1024 else { throw ReadingError.fileTooLarge }
            for reading in try ReadingBackup.decode(Data(contentsOf: file)).documents { try accept(reading) }
        }
        var next = entries
        for entry in incoming { if let index = next.firstIndex(where: { $0.reading.id == entry.reading.id }) { next[index] = entry } else { next.append(entry) } }
        guard next.count <= 200 else { throw ReadingError.invalidReading }; try publish(next)
    }
    func backup() throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("OpenRead-library-\(UUID().uuidString).zip")
        let archive = try Archive(url: destination, accessMode: .create)
        var total = 0
        for (index, entry) in entries.enumerated() {
            let data = try JSONEncoder().encode(load(entry.reading.id)); total += data.count
            guard total <= 500 * 1024 * 1024 else { throw ReadingError.fileTooLarge }
            try archive.addEntry(with: "readings/\(index).json", type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in data.subdata(in: Int(position)..<min(data.count, Int(position) + size)) }
        }
        return destination
    }
    private func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func store(_ source: Reading) throws -> Entry {
        var reading = try source.validated
        let folder = UUID().uuidString; let directory = root.appendingPathComponent("Books/\(folder)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        let text = reading.text as NSString; var offset = 0; var count = 0
        while offset < text.length {
            var end = min(text.length, offset + 64_000)
            if end < text.length, (0xD800...0xDBFF).contains(text.character(at: end - 1)) { end -= 1 }
            try text.substring(with: NSRange(location: offset, length: end - offset)).write(to: directory.appendingPathComponent("\(count).txt"), atomically: true, encoding: .utf8)
            count += 1; offset = end
        }
        let digest = hash(reading.text)
        reading.cachedWordCount = reading.wordCount; reading.cachedTextLength = text.length; reading.text = ""
        complete = true
        return Entry(reading: reading, folder: folder, chunks: count, digest: digest)
    }
    private func publish(_ next: [Entry]) throws {
        let body = try JSONEncoder().encode(next); guard body.count <= 10 * 1024 * 1024 else { throw ReadingError.invalidReading }
        try body.write(to: indexURL, options: .atomic)
        let obsolete = entries.filter { old in !next.contains(where: { $0.folder == old.folder }) }
        entries = next; readings = next.map(\.reading)
        for entry in obsolete { try? FileManager.default.removeItem(at: root.appendingPathComponent("Books/\(entry.folder)")) }
    }
}
