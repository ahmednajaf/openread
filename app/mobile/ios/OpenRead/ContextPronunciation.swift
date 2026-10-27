import Foundation
import OpenReadInference

/// Identical WordPiece inputs and bundled inference assets on every platform.
final class ContextPronunciation {
    private struct Entry: Decodable { let id: Int; let ipa: String?; let tags: [Int] }
    private struct Lexicon: Decodable { let words: [String: [Entry]]; let confidence: Double; let grammar_confidence: Double }
    private struct Candidate { let owner: Int; let word: String; let tokens: [Int64] }
    private let vocabulary: [String: Int64]
    private let lexicon: Lexicon
    private let folder: URL
    private var session: UnsafeMutableRawPointer?
    private let lock = NSLock()
    private static let punctuation = CharacterSet(charactersIn: ";:,.!?\"'“”‘’()[]{}«»—…")
    static let shared: ContextPronunciation? = { guard let root = Bundle.main.resourceURL else { return nil }; return try? ContextPronunciation(root.appendingPathComponent("pronunciation")) }()
    init(_ folder: URL) throws {
        self.folder = folder
        let words = try String(contentsOf: folder.appendingPathComponent("vocab.txt"), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        vocabulary = Dictionary(uniqueKeysWithValues: words.enumerated().map { (String($0.element), Int64($0.offset)) })
        lexicon = try JSONDecoder().decode(Lexicon.self, from: Data(contentsOf: folder.appendingPathComponent("lexicon.json")))
    }
    deinit { if let session { openread_inference_destroy(session) } }
    private func encode(_ text: String) -> [Int64] {
        let normalized = text.lowercased().decomposedStringWithCanonicalMapping
        var basic: [String] = []; var word = ""
        func flush() { if !word.isEmpty { basic.append(word); word = "" } }
        for char in normalized.unicodeScalars {
            if char.properties.generalCategory == .nonspacingMark || char.properties.generalCategory == .format { continue }
            if CharacterSet.whitespacesAndNewlines.contains(char) { flush(); continue }
            if char.properties.generalCategory == .control { continue }
            let code = char.value
            let punctuation = (33...47).contains(code) || (58...64).contains(code) || (91...96).contains(code) || (123...126).contains(code) || CharacterSet.punctuationCharacters.contains(char)
            let chinese = [(0x4e00,0x9fff),(0x3400,0x4dbf),(0x20000,0x2a6df),(0x2a700,0x2b73f),(0x2b740,0x2b81f),(0x2b820,0x2ceaf),(0xf900,0xfaff),(0x2f800,0x2fa1f)].contains { UInt32($0.0) <= code && code <= UInt32($0.1) }
            if punctuation || chinese { flush(); basic.append(String(char)) } else { word.unicodeScalars.append(char) }
        }
        flush(); var result: [Int64] = []
        for word in basic {
            let chars = Array(word.unicodeScalars)
            if chars.count > 100 { result.append(100); continue }
            var start = 0; var pieces: [Int64] = []
            while start < chars.count {
                var end = chars.count; var found: Int64?
                while end > start {
                    let piece = (start == 0 ? "" : "##") + String(String.UnicodeScalarView(chars[start..<end]))
                    if let id = vocabulary[piece] { found = id; break }; end -= 1
                }
                guard let found else { pieces = [100]; break }
                pieces.append(found); start = end
            }
            result.append(contentsOf: pieces)
        }
        return result
    }
    // Exposed internally for cross-platform token parity fixtures.
    func tokenIDs(_ text: String) -> [Int64] { encode(text) }
    func replacements(_ text: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let source = text as NSString
        let matches = try NSRegularExpression(pattern: "\\S+").matches(in: text, range: NSRange(location: 0, length: source.length))
        var candidates: [Candidate] = []
        for (owner, match) in matches.enumerated() {
            let token = source.substring(with: match.range); let trimmed = token.trimmingCharacters(in: Self.punctuation); let word = trimmed.lowercased()
            guard lexicon.words[word] != nil else { continue }
            let local = (token as NSString).range(of: trimmed); let a = match.range.location + local.location; let b = a + (trimmed as NSString).length
            let tokens = [Int64(101)] + Array(encode(source.substring(to: a)).suffix(55)) + [1] + encode(source.substring(with: NSRange(location: a, length: b-a))) + [2] + Array(encode(source.substring(from: b)).prefix(55)) + [102]
            candidates.append(.init(owner: owner, word: word, tokens: tokens))
            if candidates.count == 64 { break }
        }
        if candidates.isEmpty { return "" }
        if session == nil { session = openread_inference_create(folder.appendingPathComponent("context.ort").path) }
        guard let session else { throw ReadingError.pronunciationUnavailable }
        defer { if Bundle.main.bundleURL.pathExtension == "appex" { openread_inference_destroy(session); self.session = nil } }
        var choices: [Int: String] = [:]
        for start in stride(from: 0, to: candidates.count, by: 8) {
            let batch = Array(candidates[start..<min(start+8,candidates.count)]); let width = batch.map { $0.tokens.count }.max()!
            var ids = [Int64](repeating: 0, count: batch.count * width)
            for (i,candidate) in batch.enumerated() { ids.replaceSubrange(i*width..<i*width+candidate.tokens.count, with: candidate.tokens) }
            let mask = ids.map { $0 == 0 ? Int64(0) : 1 }
            var scores: UnsafeMutablePointer<Float>?, grammar: UnsafeMutablePointer<Float>?; var scoreCount = 0; var grammarCount = 0
            let ok = ids.withUnsafeBufferPointer { input in mask.withUnsafeBufferPointer { attention in openread_context_inference_run(session,input.baseAddress,attention.baseAddress,batch.count,width,&scores,&scoreCount,&grammar,&grammarCount) } }
            defer { openread_inference_free(scores); openread_inference_free(grammar) }
            guard ok == 1, let scores, let grammar, scoreCount % batch.count == 0, grammarCount % batch.count == 0 else { throw ReadingError.noText }
            let classes = scoreCount / batch.count; let tagCount = grammarCount / batch.count
            for (i,candidate) in batch.enumerated() {
                let entries = lexicon.words[candidate.word]!
                guard entries.allSatisfy({ $0.id >= 0 && $0.id < classes && $0.tags.allSatisfy { $0 >= 0 && $0 < tagCount } }) else { continue }
                var values = entries.map { Double(scores[i*classes+$0.id]) }
                var mass = [Double](repeating: 1, count: entries.count)
                if entries.allSatisfy({ !$0.tags.isEmpty }) {
                    let raw = (0..<tagCount).map { Double(grammar[i*tagCount+$0]) }; let peak = raw.max()!; let exp = raw.map { Foundation.exp($0-peak) }; let total = exp.reduce(0,+)
                    for k in entries.indices { mass[k] = entries[k].tags.reduce(0) { $0 + exp[$1] / total }; values[k] += log(max(0.01,mass[k])) }
                }
                let peak = values.max()!; let probabilities = values.map { exp($0-peak) }; let total = probabilities.reduce(0,+)
                guard let selected = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }) else { continue }
                if probabilities[selected] / total >= lexicon.confidence, mass[selected] >= lexicon.grammar_confidence, let ipa = entries[selected].ipa {
                    choices[candidate.owner] = ipa
                }
            }
        }
        return choices.keys.sorted().map { "\($0)\t\(choices[$0]!)" }.joined(separator: "\n")
    }
}
