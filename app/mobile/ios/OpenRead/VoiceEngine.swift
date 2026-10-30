import Foundation
import CryptoKit
#if !OPENREAD_SAFARI
import OpenReadKitten2
#endif

struct VoiceAsset: Codable, Sendable {
    let name: String; let url: URL; let sha256: String; var bytes: Int64? = nil
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
struct VoiceManifest: Codable, Sendable { let assets: [VoiceAsset]; let kokoroAssets: [VoiceAsset]?; let kitten2Assets: [VoiceAsset]? }

struct SpokenWord: Codable, Sendable { let range: NSRange; let start: Double; let end: Double }
struct SpokenClip: Codable, Sendable { let wav: Data; let words: [SpokenWord]; let duration: Double; var timingWarning: String? = nil }

actor VoiceEngine {
    struct Choice: Decodable {
        let id: String
        let name: String
        let detail: String
        let lang: String
        let embedding: String?
        let pack: String?
    }
    static var kittenVoices: [String] { choices.filter { $0.embedding != nil }.map { canonical($0.id) } }
    static let choices: [Choice] = {
        var names=["voices"]
        if #available(iOS 26, macOS 26, *) { names.append("kitten2-voices") }
        return names.flatMap { name -> [Choice] in
            guard let url=Bundle.main.url(forResource:name,withExtension:"json"),
                  let data=try? Data(contentsOf:url), let values=try? JSONDecoder().decode([Choice].self,from:data) else { return [] }
            return values
        }
    }()
    static var kitten2Voices: [String] { choices.filter { $0.pack == "kitten2" }.map(\.id) }
    static func isKitten2(_ voice: String) -> Bool { kitten2Voices.contains(voice) }
    static var kokoroVoices: [String] { choices.filter { !$0.id.contains(":") }.map(\.id) }
    static func canonical(_ voice: String) -> String { voice.hasPrefix("kitten:") ? String(voice.dropFirst(7)) : voice }
    static func isKokoro(_ voice: String) -> Bool { kokoroVoices.contains(voice) }
    static func language(_ voice: String) -> String { choices.first { canonical($0.id) == canonical(voice) }?.lang ?? "en-us" }
    static var voices: [String] {
        return kittenVoices + kokoroVoices + kitten2Voices
    }
    static func name(_ voice: String) -> String {
        if let choice = choices.first(where: { canonical($0.id) == canonical(voice) }) {
            return choice.name + " · " + (isKitten2(voice) ? "Kitten 2" : isKokoro(voice) ? choice.detail : "Kitten")
        }
        return voice.capitalized
    }
    private var engine: LocalVoiceInference?
    #if !OPENREAD_SAFARI
    private var kitten2: Any?
    #endif
    private var activeGPU = false
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
        if Self.isKitten2(voice) { return try manifest.kitten2Assets ?? [] }
        return try Self.isKokoro(voice) ? manifest.kokoroAssets ?? [] : manifest.assets
    }
    func isInstalled(voice: String = "kiki") -> Bool {
        guard let assets = try? assets(for: voice), !assets.isEmpty else { return false }
        return assets.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.name).path) }
    }
    func timingInstalled(language: String) async -> Bool {
        #if !OPENREAD_SAFARI
        if #available(iOS 26, macOS 26, *) { return await Kitten2WordAligner.canAnalyze(language: language) }
        #endif
        return false
    }
    func prepare(voice: String = "kiki", download: Bool, language: String? = nil, useGPU: Bool? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        let pack = Self.isKitten2(voice) ? "kitten2" : Self.isKokoro(voice) ? "kokoro" : "kitten"
        #if os(iOS)
        let gpu = useGPU == true
        #else
        let gpu = useGPU != false
        #endif
        if ready && activePack == pack && (pack != "kitten2" || activeGPU == gpu) {
            #if !OPENREAD_SAFARI
            if pack == "kitten2", #available(iOS 26, macOS 26, *) {
                if download {
                    try await Kitten2WordAligner.prepare(language: language ?? Self.language(voice), download: true)
                    cache.removeAll(); cacheOrder.removeAll()
                }
            }
            #endif
            return
        }
        guard !preparing else { throw ReadingError.missingModels }
        preparing = true; defer { preparing = false }
        let assets = try assets(for: voice)
        guard !assets.isEmpty else { throw ReadingError.missingModels }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var missing: [VoiceAsset] = []
        for asset in assets {
            try Task.checkCancellation()
            let file = root.appendingPathComponent(asset.name)
            if FileManager.default.fileExists(atPath: file.path), try VoiceAsset.digest(file) == asset.sha256 { continue }
            guard download else { throw ReadingError.missingModels }
            missing.append(asset)
        }
        #if !OPENREAD_SAFARI
        let aggregate = VoiceAssetProgress(missing)
        // Register every missing asset up front, so the OS can finish the whole
        // pack even if the app is subsequently suspended or relaunched.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, asset) in missing.enumerated() {
                group.addTask {
                    try await VoiceAssetDownloads.shared.download(asset) { fraction in
                        progress(aggregate.update(index, fraction) * (pack == "kitten2" ? 0.95 : 1))
                    }
                    progress(aggregate.update(index, 1) * (pack == "kitten2" ? 0.95 : 1))
                }
            }
            try await group.waitForAll()
        }
        #else
        guard missing.isEmpty else { throw ReadingError.missingModels }
        #endif
        engine = nil; ready = false
        #if !OPENREAD_SAFARI
        kitten2 = nil
        if pack == "kitten2" {
            if #available(iOS 26, macOS 26, *) {
                if download {
                    try await Kitten2WordAligner.prepare(language: language ?? Self.language(voice), download: true)
                    cache.removeAll(); cacheOrder.removeAll()
                }
                kitten2 = try Kitten2Inference(root:root,useGPU:gpu)
            } else { throw ReadingError.missingModels }
        } else { engine = try LocalVoiceInference(root:root,kokoro:pack == "kokoro") }
        #else
        guard pack != "kitten2" else { throw ReadingError.missingModels }
        engine = try LocalVoiceInference(root:root,kokoro:pack == "kokoro")
        #endif
        activePack = pack; activeGPU = gpu; ready = true; progress(1)
    }
    func generate(_ text: String, voice: String, onChunk: ((SpokenClip) -> Void)? = nil) async throws -> SpokenClip {
        let delivery=Self.isKitten2(voice) ? "\(UserDefaults.standard.bool(forKey:"kitten2-expressive")):\(UserDefaults.standard.string(forKey:"kitten2-emotion") ?? "natural")" : ""
        let key = voice + delivery + "\n" + text
        if let clip = cache[key] { onChunk?(clip); return clip }
        let clip:SpokenClip
        #if !OPENREAD_SAFARI
        if Self.isKitten2(voice), #available(iOS 26, macOS 26, *), let kitten2=kitten2 as? Kitten2Inference {
            clip=try await kitten2.generate(text,voice:String(voice.dropFirst(8)),fallbackLanguage:Self.language(voice),onChunk:onChunk)
        } else {
            guard let engine else { throw ReadingError.missingModels }
            clip=try engine.generate(text,voice:Self.canonical(voice),onChunk:onChunk)
        }
        #else
        guard let engine else { throw ReadingError.missingModels }
        clip=try engine.generate(text,voice:Self.canonical(voice),onChunk:onChunk)
        #endif
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

}

extension SpokenClip {
    /// Synthesize the original sentence for pronunciation/prosody, then seek
    /// using model word times. Source ranges remain relative to that sentence.
    func starting(atSourceOffset offset: Int) throws -> SpokenClip? {
        guard offset > 0 else { return self }
        // Without a usable timing engine, retain audible passage playback.
        // Dropping every untimed chunk would silently skip the selected passage.
        if words.isEmpty, timingWarning != nil { return self }
        let remaining = words.filter { NSMaxRange($0.range) > offset }
        guard let first = remaining.first else { return nil }
        // Native speech has a fixed mono 24 kHz PCM16 WAV contract.
        guard wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8),
              wav[8..<12] == Data("WAVE".utf8), wav[36..<40] == Data("data".utf8),
              wav[20..<24] == Data([1, 0, 1, 0]), wav[24..<28] == Data([192, 93, 0, 0]),
              wav[34..<36] == Data([16, 0]) else { throw ReadingError.noText }
        let frames = (wav.count - 44) / 2
        let start = min(frames, max(0, Int((first.start - 0.025) * 24_000)))
        let skipped = Double(start) / 24_000
        var data = Data(wav.prefix(44))
        data.append(wav.dropFirst(44 + start * 2))
        func littleEndian(_ size: Int) -> Data {
            var value = UInt32(size).littleEndian
            return Swift.withUnsafeBytes(of: &value) { Data($0) }
        }
        data.replaceSubrange(4..<8, with: littleEndian(data.count - 8))
        data.replaceSubrange(40..<44, with: littleEndian(data.count - 44))
        let duration = Double(frames - start) / 24_000
        return SpokenClip(wav: data, words: remaining.map {
            SpokenWord(range: $0.range, start: max(0, $0.start - skipped), end: min(duration, max(0, $0.end - skipped)))
        }, duration: duration, timingWarning: timingWarning)
    }
}
