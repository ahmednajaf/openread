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
    static func phonemes(_ text: String, language: String = "en-us") throws -> String {
        guard let parent = Bundle.main.resourceURL else { throw ReadingError.missingModels }
        let replacements = language.hasPrefix("en") ? (try? ContextPronunciation.shared?.replacements(text)) ?? "" : ""
        guard let result = replacements.isEmpty ? openread_speech_phonemize_language(parent.path, text, language) : openread_speech_phonemize_context_language(parent.path, text, replacements, language) else { throw ReadingError.missingModels }
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

/// Source matching never alters the contextual phonemes sent to the voice.
/// Duration edges below come from the model, including all generated chunks.
enum SpeechSourceTiming {
    struct Span: Decodable { let offset: Int; let length: Int; let begin: Int; let end: Int }
    static func spans(_ text: String, phonemes: String, language: String = "en-us", spoken: String? = nil) throws -> [Span] {
        guard let root = Bundle.main.resourceURL,
              let value = openread_speech_word_spans(root.path, spoken ?? text, phonemes, language) else { throw ReadingError.noText }
        defer { openread_speech_free(value) }
        let result = try JSONDecoder().decode([Span].self, from: Data(String(cString: value).utf8))
        guard let spoken, spoken != text else { return result }
        let original = ReadingText.words(in: text), expanded = ReadingText.words(in: spoken)
        guard original.count == expanded.count else { throw ReadingError.noText }
        return result.compactMap { span in
            guard let index = expanded.firstIndex(where: { $0.location == span.offset }) else { return nil }
            return Span(offset: original[index].location, length: original[index].length, begin: span.begin, end: span.end)
        }
    }
    static func indexed(_ text: String, vocabulary: [Unicode.Scalar: Int64], kitten: Bool) -> [(id: Int64, scalar: Int?)] {
        if !kitten { return text.unicodeScalars.enumerated().compactMap { index, scalar in vocabulary[scalar].map { ($0, index) } } }
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}_]+|[^\\p{L}\\p{N}_\\s]")
        var result: [(Int64, Int?)] = []
        for (index, match) in regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).enumerated() {
            if index > 0, let space = vocabulary[" "] { result.append((space, nil)) }
            guard let range = Range(match.range, in: text) else { continue }
            let base = text[..<range.lowerBound].unicodeScalars.count
            for (offset, scalar) in text[range].unicodeScalars.enumerated() { if let id = vocabulary[scalar] { result.append((id, base + offset)) } }
        }
        return result
    }
    static func words(_ spans: [Span], tokens: [(id: Int64, scalar: Int?)], scalarBase: Int, frames: [Int64], rawSamples: Int, keptSamples: Int) throws -> [SpokenWord] {
        guard frames.count >= tokens.count + 2, frames.allSatisfy({ $0 >= 0 && $0 < 100_000 }) else { throw ReadingError.noText }
        let total = frames.reduce(Int64(0), +)
        guard total > 0 else { throw ReadingError.noText }
        // Use actual sample edges, not a hard-coded frame rate or a guessed
        // word-length distribution. Trailing silence trimming never rescales speech.
        let scale = Double(rawSamples) / Double(total) / 24_000
        var edges = [0.0]; for frame in frames { edges.append(edges.last! + Double(frame) * scale) }
        let duration = Double(keptSamples) / 24_000
        return spans.compactMap { span in
            let indices = tokens.indices.filter { index in
                guard let scalar = tokens[index].scalar else { return false }
                return scalar + scalarBase >= span.begin && scalar + scalarBase < span.end
            }
            guard let first = indices.first, let last = indices.last else { return nil }
            let start = min(duration, edges[first + 1]), end = min(duration, edges[last + 2])
            guard end > start else { return nil }
            return SpokenWord(range: NSRange(location: span.offset, length: span.length), start: start, end: end)
        }
    }
    static func append(_ words: [SpokenWord], offset: Double, to result: inout [SpokenWord]) {
        for word in words {
            let next = SpokenWord(range: word.range, start: word.start + offset, end: word.end + offset)
            if let last = result.last, last.range == next.range {
                result[result.count - 1] = SpokenWord(range: last.range, start: last.start, end: next.end)
            } else { result.append(next) }
        }
    }
}

final class LocalVoiceInference {
    private let environment: ORTEnv
    private let session: ORTSession?
    private let mappedSession: MappedInference?
    private let root: URL
    private let kokoro: Bool
    private let vocabulary: [Unicode.Scalar: Int64]
    private var loadedVoice: (id: String, embedding: Embedding)?
    // The flatbuffer cache avoids reparsing an 80 MB protobuf in Safari's
    // memory-limited native process. Its name pins both weights and ORT ABI.
    static func preparedModel(in root: URL, kokoro: Bool = false) -> URL {
        root.appendingPathComponent(kokoro ? "kokoro-f3a290d3-ort-1.24.2.ort" : "kitten-0f5bbae4-ort-1.24.2.ort")
    }
    init(root: URL, kokoro: Bool = false, forSafari: Bool = Bundle.main.bundleURL.pathExtension == "appex") throws {
        self.root = root; self.kokoro = kokoro
        if kokoro {
            guard let url = Bundle.main.url(forResource: "kokoro-vocab", withExtension: "json") else { throw ReadingError.missingModels }
            let values = try JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: url))
            vocabulary = Dictionary(uniqueKeysWithValues: values.compactMap { key, value in key.unicodeScalars.count == 1 ? (key.unicodeScalars.first!, value) : nil })
        } else { vocabulary = SpeechTokens.vocabulary }
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions(); try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.basic)
        try options.addConfigEntry(withKey: "session.disable_prepacking", value: "1")
        let prepared = Self.preparedModel(in: root, kokoro: kokoro)
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
            session = try ORTSession(env: environment, modelPath: root.appendingPathComponent(kokoro ? "kokoro-v1.0.fp16.onnx" : "kitten_tts_mini_v0_8.onnx").path, sessionOptions: options)
            do { try FileManager.default.moveItem(at: temporary, to: prepared) }
            catch {
                // Two app scenes may prepare the same pinned cache at once.
                // A successfully published peer cache is equally valid.
                guard FileManager.default.fileExists(atPath: prepared.path) else { throw error }
            }
        }
    }
    func generate(_ text: String, voice: String, onChunk: ((SpokenClip) -> Void)? = nil) throws -> SpokenClip {
        let language = VoiceEngine.language(voice)
        let raw = try EnglishPronunciation.phonemes(text, language: language)
        let phonemes = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let chunks = try SpeechTokens.chunks(phonemes)
        let spans = try SpeechSourceTiming.spans(text, phonemes: phonemes, language: language)
        guard let key = kokoro ? voice : VoiceEngine.choices.first(where: { VoiceEngine.canonical($0.id) == voice })?.embedding else { throw ReadingError.missingModels }
        if loadedVoice?.id != key {
            let archive = root.appendingPathComponent(kokoro ? "voices-v1.0.bin" : "voices.npz")
            loadedVoice = (key, try Self.load(archive, key: key))
        }
        guard let embedding = loadedVoice?.embedding else { throw ReadingError.missingModels }
        var samples: [Float] = []; var words: [SpokenWord] = []; var cursor = phonemes.startIndex
        for chunk in chunks {
            try Task.checkCancellation()
            guard let range = phonemes.range(of: chunk, range: cursor..<phonemes.endIndex) else { throw ReadingError.noText }
            cursor = range.upperBound
            let indexed = SpeechSourceTiming.indexed(chunk, vocabulary: vocabulary, kitten: !kokoro)
            guard !indexed.isEmpty else { continue }
            let tokens = [Int64(0)] + indexed.map(\.id) + (kokoro ? [0] : [10, 0])
            let rowIndex = kokoro ? indexed.count - 1 : max(1, text.unicodeScalars.count * chunk.unicodeScalars.count / max(1, phonemes.unicodeScalars.count))
            let (audio, frames) = try predict(tokens, style: embedding.row(rowIndex))
            guard audio.allSatisfy(\.isFinite) else { throw ReadingError.noText }
            let kept = SpeechTokens.trimSilence(audio)
            let timing = try SpeechSourceTiming.words(spans, tokens: indexed, scalarBase: phonemes[..<range.lowerBound].unicodeScalars.count,
                                                    frames: frames, rawSamples: audio.count, keptSamples: kept.count)
            SpeechSourceTiming.append(timing, offset: Double(samples.count) / 24_000, to: &words)
            samples += kept
            onChunk?(SpokenClip(wav: SpeechTokens.wav(kept), words: timing, duration: Double(kept.count) / 24_000))
        }
        let duration = Double(samples.count) / 24_000
        guard duration > 0.02, samples.contains(where: { abs($0) > 0.00001 }) else { throw ReadingError.noText }
        return SpokenClip(wav: SpeechTokens.wav(samples), words: words.map { SpokenWord(range: $0.range, start: min(duration, $0.start), end: min(duration, $0.end)) }, duration: duration)
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
    private func tensor<T>(_ values: [T], type: ORTTensorElementDataType, shape: [NSNumber]) throws -> ORTValue {
        try values.withUnsafeBytes { try ORTValue(tensorData: NSMutableData(bytes: $0.baseAddress!, length: $0.count), elementType: type, shape: shape) }
    }
    private struct Embedding {
        let values: [Float]; let rows: Int; let width: Int
        func row(_ length: Int) -> [Float] { let start = min(rows - 1, max(0, length)) * width; return Array(values[start..<(start + width)]) }
    }
    private static func load(_ url: URL, key: String) throws -> Embedding {
        let archive = try Archive(url: url, accessMode: .read)
        do {
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
            return Embedding(values: values, rows: shape[0], width: width)
        }
    }
}
