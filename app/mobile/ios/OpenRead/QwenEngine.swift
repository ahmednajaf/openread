import Foundation
import CryptoKit
import AVFoundation
import OpenReadQwen
import os

struct QwenAsset: Decodable, Sendable { let name: String; let url: URL; let sha256: String; let bytes: Int64; let pack: String }
struct QwenManifest: Decodable { let assets: [QwenAsset] }
struct PersonalVoice: Codable, Identifiable, Sendable { let id: String; let name: String; let transcript: String }

enum QwenFiles {
    static var root: URL { AppFiles.root.appendingPathComponent("QwenModels") }
    static let expressive = "qwen-talker-1.7b-customvoice-Q4_K_M.gguf"
    static let clone = "qwen-talker-0.6b-base-Q4_K_M.gguf"
    static let speakers = ["ryan", "aiden", "vivian", "serena", "dylan", "eric", "uncle_fu", "ono_anna", "sohee"]
    static var profiles: [PersonalVoice] {
        let folder = root.appendingPathComponent("Profiles")
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }.compactMap { try? JSONDecoder().decode(PersonalVoice.self, from: Data(contentsOf: $0)) }
            .filter { UUID(uuidString: $0.id) != nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func installed(_ pack: String) -> Bool {
        [pack == "clone" ? clone : expressive, "qwen-tokenizer-12hz-Q4_K_M.gguf"].allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
    static func label(_ voice: String) -> String {
        if voice.hasPrefix("qwen:clone:") { return profiles.first { $0.id == String(voice.dropFirst(11)) }?.name ?? "Personal voice" }
        return voice.hasPrefix("qwen:") ? "Qwen · " + voice.dropFirst(5).replacingOccurrences(of: "_", with: " ").capitalized : voice.capitalized
    }
}

enum QwenStreamEvent: Sendable {
    case audio(SpokenClip)
    // Passage-relative source ranges and audio times. These remain estimates,
    // not forced alignment: Qwen's native callback identifies coarse phrases.
    case timing([SpokenWord])
}

/// Native phrase spans repeat across many tiny PCM chunks. Estimate each phrase
/// once, when its duration is known, rather than replaying all its words per chunk.
struct QwenPhraseTiming {
    private let ranges: [NSRange]
    private var cursor = 0
    private var phraseEnd = 0
    private var phraseStart = 0.0
    private(set) var duration = 0.0
    private(set) var words: [SpokenWord] = []
    init(text: String) { ranges = ReadingText.words(in: text) }
    mutating func append(span: NSRange?, seconds: Double) -> [SpokenWord] {
        var added: [SpokenWord] = []
        if let span, NSMaxRange(span) > phraseEnd {
            if phraseEnd > 0 { added = close(through: phraseEnd, at: duration) }
            phraseEnd = NSMaxRange(span)
        }
        duration += seconds
        return added
    }
    mutating func finish() -> [SpokenWord] { close(through: Int.max, at: duration) }
    private mutating func close(through end: Int, at time: Double) -> [SpokenWord] {
        let start = cursor
        while cursor < ranges.count, NSMaxRange(ranges[cursor]) <= end { cursor += 1 }
        guard start < cursor else { return [] }
        let selected = ranges[start..<cursor]
        let weight = Double(selected.reduce(0) { $0 + max(1, $1.length) })
        var elapsed = phraseStart
        let added = selected.map { range -> SpokenWord in
            let until = elapsed + max(0, time - phraseStart) * Double(max(1, range.length)) / weight
            defer { elapsed = until }
            return SpokenWord(range: range, start: elapsed, end: until)
        }
        phraseStart = time; words.append(contentsOf: added)
        return added
    }
}

private final class QwenChunkSink {
    let text: String
    var timing: QwenPhraseTiming
    let send: (@Sendable (QwenStreamEvent) -> Void)?
    init(text: String, send: (@Sendable (QwenStreamEvent) -> Void)?) {
        self.text = text; self.timing = QwenPhraseTiming(text: text); self.send = send
    }
    func receive(_ chunk: qwen3_tts_audio_chunk_t) {
        guard chunk.sample_rate == 24_000, chunk.n_samples > 0, chunk.n_samples <= 24_000 * 5, let samples = chunk.samples else { return }
        let values = Array(UnsafeBufferPointer(start: samples, count: Int(chunk.n_samples)))
        guard values.allSatisfy(\.isFinite) else { return }
        let duration = Double(values.count) / 24_000
        let bytes = Array(text.utf8); let a = Int(chunk.start_text_byte); let b = Int(chunk.end_text_byte)
        var span: NSRange?
        if a >= 0, a < b, b <= bytes.count,
           let before = String(bytes: bytes[..<a], encoding: .utf8), let section = String(bytes: bytes[a..<b], encoding: .utf8) {
            span = NSRange(location: before.utf16.count, length: section.utf16.count)
        }
        let words = timing.append(span: span, seconds: duration)
        if !words.isEmpty { send?(.timing(words)) }
        send?(.audio(SpokenClip(wav: SpeechTokens.wav(values), words: [], duration: duration)))
    }
    func finish() { let words = timing.finish(); if !words.isEmpty { send?(.timing(words)) } }
}

/// Regenerable, device-local audio. This is not backed up or uploaded. The OS can
/// reclaim it; corrupt/missing entries are simply synthesized again.
struct QwenPreparedAudio {
    let root: URL
    let limit: Int
    init(root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenReadQwenAudio"), limit: Int = 512 * 1024 * 1024) {
        self.root = root; self.limit = limit
    }
    static func key(text: String, voice: String, instruction: String) -> String {
        func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        return hash(voice) + "-" + hash("qwen-phrase-v2\n" + text + "\n" + instruction)
    }
    func load(_ key: String, text: String) -> SpokenClip? {
        let file = root.appendingPathComponent(key + ".plist")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 6_000_000,
              let data = try? Data(contentsOf: file), let clip = try? PropertyListDecoder().decode(SpokenClip.self, from: data),
              clip.duration.isFinite, clip.duration > 0, clip.duration <= 90,
              clip.wav.count > 44, clip.wav.prefix(4) == Data("RIFF".utf8),
              clip.wav.subdata(in: 8..<16) == Data("WAVEfmt ".utf8), abs(Double(clip.wav.count - 44) / 48_000 - clip.duration) < 0.001,
              clip.words.map(\.range) == ReadingText.words(in: text),
              abs((clip.words.last?.end ?? 0) - clip.duration) < 0.001,
              clip.words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= clip.duration + 0.001 }),
              zip(clip.words, clip.words.dropFirst()).allSatisfy({ $0.end <= $1.start + 0.001 }) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return clip
    }
    @discardableResult func store(_ clip: SpokenClip, key: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let data = try encoder.encode(clip)
            guard data.count <= limit else { return false }
            try data.write(to: root.appendingPathComponent(key + ".plist"), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
                .filter { $0.pathExtension == "plist" }.compactMap { url -> (URL, Int, Date)? in
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                    return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
                }.sorted { $0.2 < $1.2 }
            var bytes = files.reduce(0) { $0 + $1.1 }
            for (url, size, _) in files where bytes > limit { try FileManager.default.removeItem(at: url); bytes -= size }
            return true
        } catch { return false }
    }
    func remove(voice: String) {
        let prefix = String(Self.key(text: "", voice: voice, instruction: "").prefix(64)) + "-"
        for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: file) }
    }
}

actor QwenEngine {
    private let prepared = QwenPreparedAudio()
    private var downloading = false
    private var context: OpaquePointer?
    private var clips: [String: SpokenClip] = [:]
    private var clipOrder: [String] = []
    private var loaded: String?
    deinit { if let context { qwen3_tts_free(context) } }
    func unload() { if let context { qwen3_tts_free(context) }; context = nil; loaded = nil; clips.removeAll(); clipOrder.removeAll() }
    func download(_ pack: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !downloading else { throw ImportFailure(message: "A Qwen download is already running.") }; downloading = true; defer { downloading = false }
        guard ["expressive", "clone"].contains(pack), let resource = Bundle.main.url(forResource: "qwen-models", withExtension: "json") else { throw ReadingError.missingModels }
        let assets = try JSONDecoder().decode(QwenManifest.self, from: Data(contentsOf: resource)).assets.filter { $0.pack == pack || $0.pack == "shared" }
        let total = assets.reduce(Int64(0)) { $0 + $1.bytes }; var done: Int64 = 0
        try FileManager.default.createDirectory(at: QwenFiles.root, withIntermediateDirectories: true)
        for asset in assets {
            try Task.checkCancellation()
            let destination = QwenFiles.root.appendingPathComponent(asset.name)
            if FileManager.default.fileExists(atPath: destination.path), try digest(destination) == asset.sha256 { done += asset.bytes; continue }
            let before = done
            let delegate = VoiceDownloadProgress { value in progress((Double(before) + value * Double(asset.bytes)) / Double(total)) }
            let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: asset.url), delegate: delegate)
            guard (response as? HTTPURLResponse)?.statusCode == 200, try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(asset.bytes), try digest(temporary) == asset.sha256 else { throw ReadingError.checksumFailed }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination); done += asset.bytes
        }
        progress(1)
    }
    private func load(_ clone: Bool) throws -> OpaquePointer {
        let model = clone ? QwenFiles.clone : QwenFiles.expressive
        if loaded == model, let context { return context }
        unload()
        guard QwenFiles.installed(clone ? "clone" : "expressive") else { throw ImportFailure(message: "Download this optional Qwen pack in Settings first.") }
        #if os(iOS) && !targetEnvironment(simulator)
        guard os_proc_available_memory() >= 1_900_000_000 else { throw ImportFailure(message: "There is not enough memory available for Qwen right now. Close other apps or choose a Kitten voice.") }
        #endif
        openread_qwen_configure_apple_backend()
        guard let next = qwen3_tts_init() else { throw ReadingError.missingModels }
        guard qwen3_tts_load_models_with_name(next, QwenFiles.root.path, model) != 0 else { qwen3_tts_free(next); throw ImportFailure(message: "Qwen could not load. Reinstall its voice pack in Settings.") }
        context = next; loaded = model; return next
    }
    nonisolated func stream(_ text: String, voice: String, instruction: String) -> AsyncThrowingStream<QwenStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { _ = try await self.generate(text, voice: voice, instruction: instruction, onChunk: { continuation.yield($0) }); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func generate(_ text: String, voice: String, instruction: String, onChunk: (@Sendable (QwenStreamEvent) -> Void)? = nil) throws -> SpokenClip {
        try Task.checkCancellation()
        guard text.utf16.count <= 1600, instruction.count <= 500 else { throw ReadingError.speechTooComplex }
        let clone = voice.hasPrefix("qwen:clone:")
        let key = String(voice.dropFirst(clone ? 11 : 5))
        guard clone ? UUID(uuidString: key) != nil : QwenFiles.speakers.contains(key) else { throw ReadingError.invalidReading }
        let cacheKey = voice + "\n" + instruction + "\n" + text
        let diskKey = QwenPreparedAudio.key(text: text, voice: voice, instruction: instruction)
        if let clip = clips[cacheKey] { prepared.store(clip, key: diskKey); onChunk?(.timing(clip.words)); onChunk?(.audio(clip)); return clip }
        if let clip = prepared.load(diskKey, text: text) { onChunk?(.timing(clip.words)); onChunk?(.audio(clip)); return clip }
        let context = try load(clone)
        let synthesisStarted = ProcessInfo.processInfo.systemUptime
        let sink = QwenChunkSink(text: text, send: onChunk)
        let user = Unmanaged.passUnretained(sink).toOpaque()
        let result = (clone ? "" : instruction).withCString { direction in key.withCString { speaker in
            let parameters = qwen3_tts_params_t(max_audio_tokens: 720, temperature: 0.7, top_p: 0.9, top_k: 40, n_threads: 4, print_progress: 0, print_timing: 0, repetition_penalty: 1.1, language_id: 2050, instruction: direction, speaker: clone ? nil : speaker, vocoder_left_context_sec: 1)
            let streaming = qwen3_tts_streaming_params_t(generation: parameters, chunk_sec: 0.32, left_context_sec: 1, collect_audio: 1)
            let callback: qwen3_tts_audio_chunk_callback = { chunk, user in
                if Task<Never, Never>.isCancelled { return 0 }
                if let chunk, let user { Unmanaged<QwenChunkSink>.fromOpaque(user).takeUnretainedValue().receive(chunk.pointee) }
                return 1
            }
            if clone {
                let quick = QwenFiles.profiles.first { $0.id == key }?.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false
                let file = QwenFiles.root.appendingPathComponent("Profiles/\(key)" + (quick ? ".speaker.json" : ".icl")).path
                return quick ? qwen3_tts_synthesize_with_speaker_embedding_streaming(context, text, file, streaming, callback, user) : qwen3_tts_synthesize_with_icl_prompt_streaming(context, text, file, streaming, callback, user)
            }
            return qwen3_tts_synthesize_streaming(context, text, streaming, callback, user)
        } }
        withExtendedLifetime(sink) {}
        defer { qwen3_tts_free_result(result) }
        try Task.checkCancellation()
        guard result.success != 0, result.sample_rate == 24_000, result.audio_len > 240, result.audio_len <= 24_000 * 90, let pointer = result.audio else { throw ImportFailure(message: "Qwen could not finish this passage. Try again or choose another voice.") }
        let samples = Array(UnsafeBufferPointer(start: pointer, count: Int(result.audio_len)))
        guard samples.allSatisfy(\.isFinite) else { throw ReadingError.noText }
        let duration = Double(samples.count) / 24_000
        let elapsed = ProcessInfo.processInfo.systemUptime - synthesisStarted
        Logger(subsystem: "app.getopenread.reader", category: "QwenPerformance").info("Generated \(duration, privacy: .public) seconds of audio in \(elapsed, privacy: .public) seconds; audio per second \(duration / max(0.001, elapsed), privacy: .public)")
        sink.finish()
        let words = sink.timing.words
        let clip = SpokenClip(wav: SpeechTokens.wav(samples), words: words, duration: duration)
        prepared.store(clip, key: diskKey)
        clips[cacheKey] = clip; clipOrder.append(cacheKey)
        while clipOrder.count > 3 { clips.removeValue(forKey: clipOrder.removeFirst()) }
        return clip
    }
    func isPrepared(_ text: String, voice: String, instruction: String) -> Bool {
        prepared.load(QwenPreparedAudio.key(text: text, voice: voice, instruction: instruction), text: text) != nil
    }
    func clone(name: String, transcript: String, sample: URL, permission: Bool) throws -> PersonalVoice {
        guard permission, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80, transcript.count <= 2000 else { throw ImportFailure(message: "Add a voice name and permission confirmation. A transcript is optional.") }
        let granted = sample.startAccessingSecurityScopedResource(); defer { if granted { sample.stopAccessingSecurityScopedResource() } }
        guard (try sample.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= 20 * 1024 * 1024 else { throw ReadingError.fileTooLarge }
        let input = try AVAudioFile(forReading: sample); let seconds = Double(input.length) / input.processingFormat.sampleRate
        guard seconds >= 3, seconds <= 30, let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false), let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 24_000 + 100)) else { throw ImportFailure(message: "Choose a clear voice sample between 3 and 30 seconds.") }
        try input.read(into: source); var supplied = false; var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }; supplied = true; status.pointee = .haveData; return source
        }
        if let conversionError { throw conversionError }
        guard let channel = output.floatChannelData?[0], output.frameLength >= 72_000 else { throw ReadingError.noText }
        let folder = QwenFiles.root.appendingPathComponent("Profiles"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let voice = PersonalVoice(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), transcript: transcript)
        let temporary = folder.appendingPathComponent(voice.id + ".wav"); let prompt = folder.appendingPathComponent(voice.id + (transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ".speaker.json" : ".icl"))
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        guard samples.allSatisfy(\.isFinite), samples.contains(where: { abs($0) > 0.001 }) else { throw ImportFailure(message: "The sample contains no usable speech. Choose clear, audible speech.") }
        try SpeechTokens.wav(samples).write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: prompt) } }
        try Task.checkCancellation()
        let context = try load(true)
        let prepared = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? qwen3_tts_extract_speaker_embedding(context, temporary.path, prompt.path) : qwen3_tts_extract_icl_prompt(context, temporary.path, transcript, prompt.path)
        guard prepared != 0 else { try? FileManager.default.removeItem(at: prompt); throw ImportFailure(message: "This sample could not be prepared. Try clear speech without music.") }
        try Task.checkCancellation()
        try JSONEncoder().encode(voice).write(to: folder.appendingPathComponent(voice.id + ".json"), options: .atomic)
        complete = true
        return voice
    }
    func removeProfile(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw ReadingError.invalidReading }
        clips.removeAll(); clipOrder.removeAll(); prepared.remove(voice: "qwen:clone:" + id)
        for suffix in ["json", "icl", "speaker.json"] { let url = QwenFiles.root.appendingPathComponent("Profiles/\(id).\(suffix)"); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
    }
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; var hash = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
