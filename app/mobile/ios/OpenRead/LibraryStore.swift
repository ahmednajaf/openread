import Foundation
import Combine

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
        try? url.setResourceValues(values)
        return base
    }
    static var inbox: URL {
        let url = root.appendingPathComponent("Inbox")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var models: URL { root.appendingPathComponent("Models") }
}

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var readings: [Reading] = []
    @Published var error: String?
    private let url = AppFiles.root.appendingPathComponent("library.json")
    init() {
        do {
            if FileManager.default.fileExists(atPath: url.path) { readings = try ReadingBackup.decode(Data(contentsOf: url)).documents }
        } catch { self.error = "Your library could not be opened. Its file has been kept for recovery." }
    }
    func save(_ reading: Reading) throws {
        let valid = try reading.validated
        var next = readings
        if let index = next.firstIndex(where: { $0.id == valid.id }) { next[index] = valid }
        else { guard next.count < 200 else { throw ReadingError.invalidReading }; next.insert(valid, at: 0) }
        try write(next)
    }
    func remove(_ id: String) throws { try write(readings.filter { $0.id != id }) }
    func restore(_ data: Data) throws {
        let backup = try ReadingBackup.decode(data)
        var next = readings
        for reading in backup.documents {
            if let index = next.firstIndex(where: { $0.id == reading.id }) { next[index] = reading }
            else { next.append(reading) }
        }
        guard next.count <= 200 else { throw ReadingError.invalidReading }
        try write(next)
    }
    func backup() throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("OpenRead-library.json")
        try JSONEncoder().encode(ReadingBackup(documents: readings)).write(to: destination, options: .atomic)
        return destination
    }
    private func write(_ next: [Reading]) throws {
        let data = try JSONEncoder().encode(ReadingBackup(documents: next))
        guard data.count <= 25 * 1024 * 1024 else { throw ReadingError.invalidReading }
        try data.write(to: url, options: .atomic)
        readings = next
    }
}
