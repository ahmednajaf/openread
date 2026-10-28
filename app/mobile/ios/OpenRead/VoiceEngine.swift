import Foundation
import CryptoKit

struct VoiceAsset: Codable, Sendable {
    let name: String; let url: URL; let sha256: String
}
struct VoiceManifest: Codable, Sendable { let assets: [VoiceAsset]; let kokoroAssets: [VoiceAsset]? }

final class VoiceDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Double) -> Void
    init(_ update: @escaping @Sendable (Double) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { update(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
}

struct SpokenWord: Codable, Sendable { let range: NSRange; let start: Double; let end: Double }
struct SpokenClip: Codable, Sendable { let wav: Data; let words: [SpokenWord]; let duration: Double }

actor VoiceEngine {
    struct Choice: Decodable {
        let id: String
        let name: String
        let detail: String
        let lang: String
        let embedding: String?
    }
    static var kittenVoices: [String] { choices.filter { $0.embedding != nil }.map { canonical($0.id) } }
    static let choices: [Choice] = {
        guard let url = Bundle.main.url(forResource: "voices", withExtension: "json"),
              let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([Choice].self, from: data) else { return [] }
        return values
    }()
    static var kokoroVoices: [String] { choices.filter { !$0.id.contains(":") }.map(\.id) }
    static func canonical(_ voice: String) -> String { voice.hasPrefix("kitten:") ? String(voice.dropFirst(7)) : voice }
    static func isKokoro(_ voice: String) -> Bool { kokoroVoices.contains(voice) }
    static func language(_ voice: String) -> String { choices.first { canonical($0.id) == canonical(voice) }?.lang ?? "en-us" }
    static var voices: [String] {
        return kittenVoices + kokoroVoices
    }
    static func name(_ voice: String) -> String {
        if let choice = choices.first(where: { canonical($0.id) == canonical(voice) }) {
            return choice.name + " · " + (isKokoro(voice) ? choice.detail : "Kitten")
        }
        return voice.capitalized
    }
    private var engine: LocalVoiceInference?
    private var activePack: String?
    private var cache: [String: SpokenClip] = [:]
    private var cacheOrder: [String] = []
    private var ready = false
    private var preparing = false
    private let root = AppFiles.models
    private var manifest: VoiceManifest {
        get throws { try JSONDecoder().decode(VoiceManifest.self, from: Data(contentsOf: Bundle.main.url(forResource: "models", withExtension: "json")!)) }
    }
    private func assets(for voice: String) throws -> [VoiceAsset] {
        guard Self.voices.contains(voice) || Self.choices.contains(where: { Self.canonical($0.id) == Self.canonical(voice) }) else { throw ReadingError.missingModels }
        return try Self.isKokoro(voice) ? manifest.kokoroAssets ?? [] : manifest.assets
    }
    func isInstalled(voice: String = "kiki") -> Bool {
        guard let assets = try? assets(for: voice), !assets.isEmpty else { return false }
        return assets.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.name).path) }
    }
    func prepare(voice: String = "kiki", download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        let pack = Self.isKokoro(voice) ? "kokoro" : "kitten"
        if ready && activePack == pack { return }
        guard !preparing else { throw ReadingError.missingModels }
        preparing = true; defer { preparing = false }
        let assets = try assets(for: voice)
        guard !assets.isEmpty else { throw ReadingError.missingModels }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()
            let destination = root.appendingPathComponent(asset.name)
            if FileManager.default.fileExists(atPath: destination.path), try digest(destination) == asset.sha256 { continue }
            guard download else { throw ReadingError.missingModels }
            let delegate = VoiceDownloadProgress { fraction in progress((Double(index) + fraction) / Double(assets.count)) }
            let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: asset.url), delegate: delegate)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ReadingError.downloadFailed }
            guard try digest(temporary) == asset.sha256 else { try? FileManager.default.removeItem(at: temporary); throw ReadingError.checksumFailed }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        engine = nil; ready = false
        engine = try LocalVoiceInference(root: root, kokoro: pack == "kokoro")
        activePack = pack; ready = true; progress(1)
    }
    func generate(_ text: String, voice: String, onChunk: ((SpokenClip) -> Void)? = nil) async throws -> SpokenClip {
        let key = voice + "\n" + text
        if let clip = cache[key] { onChunk?(clip); return clip }
        guard let engine else { throw ReadingError.missingModels }
        let clip = try engine.generate(text, voice: Self.canonical(voice), onChunk: onChunk)
        try Task.checkCancellation()
        cache[key] = clip; cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
        while cacheOrder.count > 3 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        return clip
    }
    func stream(_ text: String, voice: String) -> AsyncThrowingStream<SpokenClip, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    _ = try await generate(text, voice: voice) { continuation.yield($0) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
