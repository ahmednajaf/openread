// Kitten's model vocabulary and duration formula follow KittenML/KittenTTS
// (Apache-2.0). See shared/NOTICES.txt. Neural inference stays on this device.
import Foundation
import OnnxRuntimeBindings
import ZIPFoundation
import OpenReadSpeech
import OpenReadInference

private final class MappedInference {
    private let session: UnsafeMutableRawPointer
    init(_ model: URL) throws {
        guard let value = openread_inference_create(model.path) else { throw ReadingError.missingModels }
        session = value
    }
    deinit { openread_inference_destroy(session) }
    func run(_ tokens: [Int64], style: [Float]) throws -> ([Float], [Int64]) {
        var samples: UnsafeMutablePointer<Float>?, frames: UnsafeMutablePointer<Int64>?
        var sampleCount = 0, frameCount = 0
        let ok = tokens.withUnsafeBufferPointer { input in style.withUnsafeBufferPointer { voice in
            openread_inference_run(session, input.baseAddress, input.count, voice.baseAddress, voice.count, &samples, &sampleCount, &frames, &frameCount)
        } }
        defer { openread_inference_free(samples); openread_inference_free(frames) }
        guard ok == 1, let samples, let frames else { throw ReadingError.noText }
        return (Array(UnsafeBufferPointer(start: samples, count: sampleCount)), Array(UnsafeBufferPointer(start: frames, count: frameCount)))
    }
}

struct EnglishPronunciation {
    static func phonemes(_ text: String) throws -> String {
        guard let parent = Bundle.main.resourceURL,
              let result = openread_speech_phonemize(parent.path, text) else { throw ReadingError.missingModels }
        defer { openread_speech_free(result) }
        let value = String(cString: result).replacingOccurrences(of: "\n", with: " ")
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { throw ReadingError.noText }
        return value
    }
}

enum SpeechTokens {
    static let alphabet = "$;:,.!?¡¿—…\"«»“” ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘’̩‘ᵻ"
    static let vocabulary = Dictionary(uniqueKeysWithValues: alphabet.unicodeScalars.enumerated().map { ($0.element, Int64($0.offset)) })
    static func body(_ text: String) -> [Int64] {
        // Match the model author's basic_english_tokenize, including stress and
        // punctuation separators. The native SDK previously skipped this step.
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}_]+|[^\\p{L}\\p{N}_\\s]")
        let source = text as NSString
        let prepared = regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }.joined(separator: " ")
        return prepared.unicodeScalars.compactMap { vocabulary[$0] }
    }
    // Split at real word boundaries, preferring clause/sentence endings. Never
    // hand half a word to the model, even when a source sentence is very long.
    static func chunks(_ phonemes: String, limit: Int = 397) throws -> [String] {
        let words = phonemes.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var result: [String] = []; var pending = ""
        for word in words {
            guard body(word).count <= limit else { throw ReadingError.speechTooComplex }
            let next = pending.isEmpty ? word : pending + " " + word
            if body(next).count > limit { result.append(pending); pending = word }
            else { pending = next }
            if let last = word.last, ".!?;:".contains(last), body(pending).count >= 40 { result.append(pending); pending = "" }
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }
    // Preserve speech and punctuation pauses. Only discard a bounded run of
    // genuinely silent trailing samples; the old fixed 5,000 cut clipped words.
    static func trimSilence(_ samples: [Float]) -> [Float] {
        guard let last = samples.lastIndex(where: { abs($0) > 0.0001 }) else { return samples }
        let keep = max(samples.count - 4_800, min(samples.count, last + 1 + 2_400))
        return Array(samples.prefix(keep))
    }
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + samples.count * 2)); ascii("WAVEfmt "); u32(16); u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16); ascii("data"); u32(UInt32(samples.count * 2))
        for sample in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32_767))) }
        return data
    }
}

final class KittenInference {
    private let environment: ORTEnv
    private let session: ORTSession?
    private let mappedSession: MappedInference?
    private let embeddings: [String: Embedding]
    static let voiceIDs = ["kiki": "expr-voice-5-f", "rosie": "expr-voice-4-f", "jasper": "expr-voice-2-m", "luna": "expr-voice-3-f", "bruno": "expr-voice-3-m", "hugo": "expr-voice-4-m", "leo": "expr-voice-5-m", "bella": "expr-voice-2-f"]
    // The flatbuffer cache avoids reparsing an 80 MB protobuf in Safari's
    // memory-limited native process. Its name pins both weights and ORT ABI.
    static func preparedModel(in root: URL) -> URL { root.appendingPathComponent("kitten-0f5bbae4-ort-1.24.2.ort") }
    init(root: URL, forSafari: Bool = Bundle.main.bundleURL.pathExtension == "appex") throws {
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions(); try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.basic)
        try options.addConfigEntry(withKey: "session.disable_prepacking", value: "1")
        let prepared = Self.preparedModel(in: root)
        let nativeExtension = forSafari
        if nativeExtension {
            mappedSession = try MappedInference(prepared)
            session = nil
        } else if FileManager.default.fileExists(atPath: prepared.path) {
            mappedSession = nil
            session = try ORTSession(env: environment, modelPath: prepared.path, sessionOptions: options)
        } else {
            mappedSession = nil
            // Only the containing app may compile the cache. Loading protobuf
            // inside the extension can exceed iOS's per-extension memory cap.
            guard !nativeExtension else { throw ReadingError.missingModels }
            let temporary = root.appendingPathComponent(UUID().uuidString + ".ort")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try options.addConfigEntry(withKey: "session.save_model_format", value: "ORT")
            try options.setOptimizedModelFilePath(temporary.path)
            session = try ORTSession(env: environment, modelPath: root.appendingPathComponent("kitten_tts_mini_v0_8.onnx").path, sessionOptions: options)
            do { try FileManager.default.moveItem(at: temporary, to: prepared) }
            catch {
                // Two app scenes may prepare the same pinned cache at once.
                // A successfully published peer cache is equally valid.
                guard FileManager.default.fileExists(atPath: prepared.path) else { throw error }
            }
        }
        embeddings = try Self.load(root.appendingPathComponent("voices.npz"))
    }
    func generate(_ text: String, voice: String) throws -> SpokenClip {
        let phonemes = try EnglishPronunciation.phonemes(text)
        let chunks = try SpeechTokens.chunks(phonemes)
        guard let embedding = embeddings[Self.voiceIDs[voice] ?? "expr-voice-5-f"] else { throw ReadingError.missingModels }
        var samples: [Float] = []; var frames: [Int64] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let tokens = [Int64(0)] + SpeechTokens.body(chunk) + [10, 0]
            let row = embedding.row(max(1, text.unicodeScalars.count * chunk.unicodeScalars.count / max(1, phonemes.unicodeScalars.count)))
            let (audio, predictedFrames) = try predict(tokens, style: row)
            guard audio.allSatisfy(\.isFinite) else { throw ReadingError.noText }
            samples += SpeechTokens.trimSilence(audio)
            if chunks.count == 1 { frames = predictedFrames }
        }
        let duration = Double(samples.count) / 24_000
        guard duration > 0.02, samples.contains(where: { abs($0) > 0.00001 }) else { throw ReadingError.noText }
        let words = timings(text, phonemes: phonemes, frames: frames, duration: duration)
            ?? ReadingText.estimatedWords(text, duration: duration).map { SpokenWord(range: $0.range, start: $0.start, end: $0.end) }
        return SpokenClip(wav: SpeechTokens.wav(samples), words: words, duration: duration)
    }
    private func predict(_ tokens: [Int64], style row: [Float]) throws -> ([Float], [Int64]) {
        if let mappedSession { return try mappedSession.run(tokens, style: row) }
        guard let session else { throw ReadingError.missingModels }
        let input = try tensor(tokens, type: .int64, shape: [1, NSNumber(value: tokens.count)])
        let style = try tensor(row, type: .float, shape: [1, NSNumber(value: row.count)])
        let speed = try tensor([Float(1)], type: .float, shape: [1])
        let outputs = try session.run(withInputs: ["input_ids": input, "style": style, "speed": speed], outputNames: ["waveform", "duration"], runOptions: nil)
        guard let waveform = outputs["waveform"], let duration = outputs["duration"] else { throw ReadingError.noText }
        let audio = (try waveform.tensorData() as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let frames = (try duration.tensorData() as Data).withUnsafeBytes { Array($0.bindMemory(to: Int64.self)) }
        return (audio, frames)
    }
    private func timings(_ text: String, phonemes: String, frames: [Int64], duration: Double) -> [SpokenWord]? {
        let source = ReadingText.words(in: text); let groups = phonemes.split(whereSeparator: \.isWhitespace)
        guard source.count == groups.count, frames.count == SpeechTokens.body(phonemes).count + 3, frames.allSatisfy({ $0 >= 0 }) else { return nil }
        var left = Double(max(0, frames[0] - 3)) * 2; var right = left; var token = 1
        var result: [SpokenWord] = []
        for (i, group) in groups.enumerated() {
            let length = SpeechTokens.body(String(group)).count
            guard token + length < frames.count else { return nil }
            let start = max(0, min(duration, left / 80))
            let space = i < groups.count - 1 ? frames[token + length] : 0
            left = right + 2 * Double(frames[token..<(token + length)].reduce(0, +)) + Double(space)
            let end = max(start, min(duration, left / 80)); right = left + Double(space)
            guard end > start else { return nil }
            result.append(.init(range: source[i], start: start, end: end)); token += length + (i < groups.count - 1 ? 1 : 0)
        }
        return result
    }
    private func tensor<T>(_ values: [T], type: ORTTensorElementDataType, shape: [NSNumber]) throws -> ORTValue {
        try values.withUnsafeBytes { try ORTValue(tensorData: NSMutableData(bytes: $0.baseAddress!, length: $0.count), elementType: type, shape: shape) }
    }
    private struct Embedding {
        let values: [Float]; let rows: Int; let width: Int
        func row(_ length: Int) -> [Float] { let start = min(rows - 1, max(0, length)) * width; return Array(values[start..<(start + width)]) }
    }
    private static func load(_ url: URL) throws -> [String: Embedding] {
        let archive = try Archive(url: url, accessMode: .read)
        var result: [String: Embedding] = [:]
        for key in Set(voiceIDs.values) {
            guard let entry = archive[key + ".npy"], entry.uncompressedSize <= 20_000_000 else { throw ReadingError.missingModels }
            var data = Data(); _ = try archive.extract(entry) { data.append($0) }
            guard data.count >= 12, Array(data.prefix(6)) == [0x93, 78, 85, 77, 80, 89] else { throw ReadingError.missingModels }
            let base = data[6] == 1 ? 10 : 12
            let length = data[8..<base].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            guard length > 0, length < 4096, base + length <= data.count,
                  let header = String(data: data[base..<(base + length)], encoding: .ascii), header.contains("'<f4'"), header.contains("False"),
                  let match = header.range(of: "(?<='shape': \\()[^)]*", options: .regularExpression) else { throw ReadingError.missingModels }
            let shape = header[match].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard (2...3).contains(shape.count), shape.allSatisfy({ $0 > 0 && $0 <= 100_000 }) else { throw ReadingError.missingModels }
            let width = shape.dropFirst().reduce(1, *); let count = shape[0] * width
            guard count <= 5_000_000, data.count - base - length == count * 4 else { throw ReadingError.missingModels }
            let values = data.dropFirst(base + length).withUnsafeBytes { bytes in (0..<count).map { Float(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian) } }
            result[key] = Embedding(values: values, rows: shape[0], width: width)
        }
        return result
    }
}
