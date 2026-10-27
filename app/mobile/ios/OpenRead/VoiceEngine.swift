import Foundation
import CryptoKit

struct VoiceAsset: Codable, Sendable {
    let name: String; let url: URL; let sha256: String
}
struct VoiceManifest: Codable, Sendable { let assets: [VoiceAsset] }

final class VoiceDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Double) -> Void
    init(_ update: @escaping @Sendable (Double) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { update(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
}

struct SpokenWord: Sendable { let range: NSRange; let start: Double; let end: Double }
struct SpokenClip: Sendable { let wav: Data; let words: [SpokenWord]; let duration: Double }

actor VoiceEngine {
    static let kittenVoices = ["kiki", "rosie", "jasper", "luna", "bruno", "hugo", "leo", "bella"]
    static var voices: [String] {
        #if OPENREAD_QWEN
        return kittenVoices + QwenFiles.speakers.map { "qwen:" + $0 } + QwenFiles.profiles.map { "qwen:clone:" + $0.id }
        #else
        return kittenVoices
        #endif
    }
    static func name(_ voice: String) -> String {
        #if OPENREAD_QWEN
        return QwenFiles.label(voice)
        #else
        return voice.capitalized
        #endif
    }
    #if OPENREAD_QWEN
    let qwen = QwenEngine()
    #endif
    private var engine: KittenInference?
    private var cache: [String: SpokenClip] = [:]
    private var cacheOrder: [String] = []
    private var ready = false
    private var preparing = false
    private let root = AppFiles.models
    private var manifest: VoiceManifest {
        get throws { try JSONDecoder().decode(VoiceManifest.self, from: Data(contentsOf: Bundle.main.url(forResource: "models", withExtension: "json")!)) }
    }
    func isInstalled(voice: String = "kiki") -> Bool {
        #if OPENREAD_QWEN
        if voice.hasPrefix("qwen:") { return QwenFiles.installed(voice.hasPrefix("qwen:clone:") ? "clone" : "expressive") }
        #endif
        guard let assets = try? manifest.assets else { return false }
        return assets.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.name).path) }
    }
    func prepare(voice: String = "kiki", download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        #if OPENREAD_QWEN
        if voice.hasPrefix("qwen:") {
            if engine != nil { engine = nil; ready = false; cache.removeAll(); cacheOrder.removeAll() }
            let pack = voice.hasPrefix("qwen:clone:") ? "clone" : "expressive"
            if download { try await qwen.download(pack, progress: progress) }
            guard QwenFiles.installed(pack) else { throw ReadingError.missingModels }; return
        }
        await qwen.unload()
        #endif
        if ready { return }
        guard !preparing else { throw ReadingError.missingModels }
        preparing = true; defer { preparing = false }
        let assets = try manifest.assets
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
        engine = try KittenInference(root: root)
        ready = true; progress(1)
    }
    func generate(_ text: String, voice: String, instruction: String = "") async throws -> SpokenClip {
        let key = voice + "\n" + instruction + "\n" + text
        if let clip = cache[key] { return clip }
        let clip: SpokenClip
        #if OPENREAD_QWEN
        if voice.hasPrefix("qwen:") { clip = try await qwen.generate(text, voice: voice, instruction: instruction) }
        else { guard let engine else { throw ReadingError.missingModels }; clip = try engine.generate(text, voice: voice) }
        #else
        guard let engine else { throw ReadingError.missingModels }; clip = try engine.generate(text, voice: voice)
        #endif
        try Task.checkCancellation()
        cache[key] = clip; cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
        while cacheOrder.count > 3 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        return clip
    }
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
