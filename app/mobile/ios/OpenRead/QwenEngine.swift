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

actor QwenEngine {
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
        guard let next = qwen3_tts_init() else { throw ReadingError.missingModels }
        guard qwen3_tts_load_models_with_name(next, QwenFiles.root.path, model) != 0 else { qwen3_tts_free(next); throw ImportFailure(message: "Qwen could not load. Reinstall its voice pack in Settings.") }
        context = next; loaded = model; return next
    }
    func generate(_ text: String, voice: String, instruction: String) throws -> SpokenClip {
        try Task.checkCancellation()
        guard text.utf16.count <= 1600, instruction.count <= 500 else { throw ReadingError.speechTooComplex }
        let clone = voice.hasPrefix("qwen:clone:")
        let key = String(voice.dropFirst(clone ? 11 : 5))
        guard clone ? UUID(uuidString: key) != nil : QwenFiles.speakers.contains(key) else { throw ReadingError.invalidReading }
        let cacheKey = voice + "\n" + instruction + "\n" + text
        if let clip = clips[cacheKey] { return clip }
        let context = try load(clone)
        let result = (clone ? "" : instruction).withCString { direction in key.withCString { speaker in
            let parameters = qwen3_tts_params_t(max_audio_tokens: 720, temperature: 0.7, top_p: 0.9, top_k: 40, n_threads: 4, print_progress: 0, print_timing: 0, repetition_penalty: 1.1, language_id: 2050, instruction: direction, speaker: clone ? nil : speaker, vocoder_left_context_sec: 1)
            let streaming = qwen3_tts_streaming_params_t(generation: parameters, chunk_sec: 1.5, left_context_sec: 1, collect_audio: 1)
            let callback: qwen3_tts_audio_chunk_callback = { _, _ in Task<Never, Never>.isCancelled ? 0 : 1 }
            if clone {
                let quick = QwenFiles.profiles.first { $0.id == key }?.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false
                let file = QwenFiles.root.appendingPathComponent("Profiles/\(key)" + (quick ? ".speaker.json" : ".icl")).path
                return quick ? qwen3_tts_synthesize_with_speaker_embedding_streaming(context, text, file, streaming, callback, nil) : qwen3_tts_synthesize_with_icl_prompt_streaming(context, text, file, streaming, callback, nil)
            }
            return qwen3_tts_synthesize_streaming(context, text, streaming, callback, nil)
        } }
        defer { qwen3_tts_free_result(result) }
        try Task.checkCancellation()
        guard result.success != 0, result.sample_rate == 24_000, result.audio_len > 240, result.audio_len <= 24_000 * 90, let pointer = result.audio else { throw ImportFailure(message: "Qwen could not finish this passage. Try again or choose another voice.") }
        let samples = Array(UnsafeBufferPointer(start: pointer, count: Int(result.audio_len)))
        guard samples.allSatisfy(\.isFinite) else { throw ReadingError.noText }
        let duration = Double(samples.count) / 24_000
        let words = ReadingText.estimatedWords(text, duration: duration).map { SpokenWord(range: $0.range, start: $0.start, end: $0.end) }
        let clip = SpokenClip(wav: SpeechTokens.wav(samples), words: words, duration: duration)
        clips[cacheKey] = clip; clipOrder.append(cacheKey)
        while clipOrder.count > 3 { clips.removeValue(forKey: clipOrder.removeFirst()) }
        return clip
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
        clips.removeAll(); clipOrder.removeAll()
        for suffix in ["json", "icl", "speaker.json"] { let url = QwenFiles.root.appendingPathComponent("Profiles/\(id).\(suffix)"); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
    }
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; var hash = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
