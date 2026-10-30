import Foundation

/// Small App Group messages; large voice models stay in the containing app.
struct SafariListeningSession {
    struct Request: Codable {
        let id: String
        let tab: Int
        let created: Double
        let title: String
        let source: String
        let voice: String
        let rate: Float
        let items: [String]
        let index: Int
        var offsets: [Int] {
            var offset = 0
            return items.map { text in defer { offset += text.utf16.count + 2 }; return offset }
        }
        var reading: Reading { Reading(id: "safari:" + id, title: title, text: items.joined(separator: "\n\n"), source: source, position: offsets[index]) }
        func validate() throws {
            guard UUID(uuidString: id)?.uuidString == id, tab >= 0,
                  created <= Date().timeIntervalSince1970 + 60, created > Date().timeIntervalSince1970 - 86_400,
                  !title.isEmpty, title.count <= 240, source.count <= 1000,
                  ["https", "http"].contains(URL(string: source)?.scheme ?? ""),
                  voice.hasPrefix("kitten2:"), VoiceEngine.isKitten2(voice),
                  rate.isFinite, (0.5...2).contains(rate), !items.isEmpty, items.count <= 5000,
                  items.indices.contains(index), items.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  items.reduce(0, { $0 + $1.utf16.count + 2 }) <= 250_000 else { throw ReadingError.invalidReading }
        }
    }
    struct Word: Codable, Equatable {
        let location: Int
        let length: Int
        init(_ range: NSRange) { location = range.location; length = range.length }
    }
    struct State: Codable, Equatable {
        let status: String
        let index: Int
        let rate: Float
        let word: Word?
        let error: String?
        var notice: String? = nil
    }
    struct Command: Codable {
        let id: String
        let created: Double
        let action: String
        let index: Int?
        let rate: Float?
        let autoplay: Bool?
    }
    let root: URL
    init(root: URL = AppFiles.root.appendingPathComponent("SafariListening")) { self.root = root }
    private func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id)?.uuidString == id else { throw ReadingError.invalidReading }
        return root.appendingPathComponent(id, isDirectory: true)
    }
    private func read<T: Decodable>(_ type: T.Type, from url: URL, limit: Int = 2_000_000) throws -> T {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= limit else { throw ReadingError.invalidReading }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    func create(tab: Int, title: String, source: String, voice: String, rate: Float, items: [String], index: Int) throws -> Request {
        let request = Request(id: UUID().uuidString, tab: tab, created: Date().timeIntervalSince1970, title: title, source: source, voice: voice, rate: rate, items: items, index: index)
        try request.validate()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        for url in existing {
            if let state = try? read(State.self, from: url.appendingPathComponent("state.json"), limit: 8000), state.status == "ended" {
                try? FileManager.default.removeItem(at: url); continue
            }
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date.timeIntervalSinceNow < -86_400 { try? FileManager.default.removeItem(at: url) }
        }
        guard (try FileManager.default.contentsOfDirectory(atPath: root.path)).count < 8 else { throw ReadingError.invalidReading }
        let folder = try directory(request.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
        try write(State(status: "loading", index: index, rate: rate, word: nil, error: nil), id: request.id)
        return request
    }
    func request(_ id: String, tab: Int? = nil) throws -> Request {
        let value = try read(Request.self, from: directory(id).appendingPathComponent("request.json"))
        try value.validate()
        guard value.id == id, tab == nil || value.tab == tab else { throw ReadingError.invalidReading }
        return value
    }
    func state(_ id: String, tab: Int) throws -> State {
        _ = try request(id, tab: tab)
        return try read(State.self, from: directory(id).appendingPathComponent("state.json"), limit: 8000)
    }
    func write(_ state: State, id: String) throws {
        try JSONEncoder().encode(state).write(to: directory(id).appendingPathComponent("state.json"), options: .atomic)
    }
    func command(_ id: String, tab: Int, action: String, index: Int?, rate: Float?, autoplay: Bool?) throws {
        let request = try request(id, tab: tab)
        guard ["play", "pause", "stop", "seek", "rate"].contains(action),
              index == nil || request.items.indices.contains(index!),
              rate == nil || (rate!.isFinite && (0.5...2).contains(rate!)) else { throw ReadingError.invalidReading }
        let folder = try directory(id).appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try FileManager.default.contentsOfDirectory(atPath: folder.path)).count < 32 else { throw ReadingError.invalidReading }
        let value = Command(id: UUID().uuidString, created: Date().timeIntervalSince1970, action: action, index: index, rate: rate, autoplay: autoplay)
        try JSONEncoder().encode(value).write(to: folder.appendingPathComponent(value.id + ".json"), options: .atomic)
    }
    func takeCommands(_ id: String) throws -> [Command] {
        let folder = try directory(id).appendingPathComponent("commands")
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        guard files.count <= 32 else { throw ReadingError.invalidReading }
        return files.compactMap { file in
            defer { try? FileManager.default.removeItem(at: file) }
            guard file.pathExtension == "json", let value = try? read(Command.self, from: file, limit: 4000),
                  UUID(uuidString: value.id)?.uuidString == value.id, file.lastPathComponent == value.id + ".json",
                  abs(Date().timeIntervalSince1970 - value.created) < 30 else { return nil }
            return value
        }.sorted { $0.created < $1.created }
    }
    func remove(_ id: String) { if let folder = try? directory(id) { try? FileManager.default.removeItem(at: folder) } }
}
