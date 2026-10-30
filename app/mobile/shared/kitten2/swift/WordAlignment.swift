import Foundation
import NaturalLanguage
import Speech
import AVFoundation

public struct Kitten2RecognizedSpan: Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public init(text: String, start: Double, end: Double) { self.text=text; self.start=start; self.end=end }
}
public struct Kitten2AlignedWord: Sendable {
    public let range: NSRange
    public let start: Double
    public let end: Double
}

public enum Kitten2SourceAlignment {
    private struct Source { let range: NSRange; let normalized: String }
    private struct Step { var cost: Int; var source: Int; var recognized: Int; var matched: Bool }
    private static func normalized(_ value: String) -> String {
        String(value.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive,.diacriticInsensitive,.widthInsensitive], locale: nil)
            .decomposedStringWithCanonicalMapping.unicodeScalars.filter {
                !CharacterSet.nonBaseCharacters.contains($0) &&
                (CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0))
            })
    }
    /// Match real recognition intervals to exact source ranges. Unrecognized words
    /// remain unhighlighted; no duration is distributed across guessed words.
    public static func words(text: String, recognized: [Kitten2RecognizedSpan], startingAt offset: Int = 0) -> [Kitten2AlignedWord] {
        let tokenizer=NLTokenizer(unit:.word); tokenizer.string=text
        var source:[Source]=[]
        tokenizer.enumerateTokens(in:text.startIndex..<text.endIndex) { range,_ in
            let span=NSRange(range,in:text), value=normalized(String(text[range]))
            if NSMaxRange(span)>offset, !value.isEmpty { source.append(Source(range:span,normalized:value)) }
            return true
        }
        let heard=recognized.filter { $0.start.isFinite && $0.end.isFinite && $0.start>=0 && $0.end>$0.start && !normalized($0.text).isEmpty }
        guard !source.isEmpty, !heard.isEmpty, source.count<=512, heard.count<=512 else { return [] }
        let rows=source.count+1, columns=heard.count+1
        var table=Array(repeating:Step(cost:Int.max/4,source:0,recognized:0,matched:false),count:rows*columns)
        func key(_ i:Int,_ j:Int)->Int { i*columns+j }
        table[0].cost=0
        for i in 1..<rows { table[key(i,0)]=Step(cost:i,source:1,recognized:0,matched:false) }
        for j in 1..<columns { table[key(0,j)]=Step(cost:j,source:0,recognized:1,matched:false) }
        for i in 1..<rows {
            for j in 1..<columns {
                var best=Step(cost:table[key(i-1,j)].cost+1,source:1,recognized:0,matched:false)
                let inserted=table[key(i,j-1)].cost+1
                if inserted<best.cost { best=Step(cost:inserted,source:0,recognized:1,matched:false) }
                let target=normalized(heard[j-1].text)
                var combined=""
                for length in 1...min(8,i) {
                    combined=source[i-length].normalized+combined
                    if combined==target {
                        let cost=table[key(i-length,j-1)].cost
                        if cost<=best.cost { best=Step(cost:cost,source:length,recognized:1,matched:true) }
                    }
                    if combined.count>target.count { break }
                }
                table[key(i,j)]=best
            }
        }
        // A streaming window can end before the source passage does.
        var i=(0..<rows).min { table[key($0,heard.count)].cost<table[key($1,heard.count)].cost } ?? 0
        var j=heard.count, result:[Kitten2AlignedWord]=[]
        while i>0 || j>0 {
            let step=table[key(i,j)]
            guard step.source>0 || step.recognized>0 else { break }
            if step.matched {
                let first=source[i-step.source].range, last=source[i-1].range, spoken=heard[j-1]
                result.append(Kitten2AlignedWord(range:NSRange(location:first.location,length:NSMaxRange(last)-first.location),start:spoken.start,end:spoken.end))
            }
            i-=step.source; j-=step.recognized
        }
        return result.reversed()
    }
}

@available(iOS 26, macOS 26, *)
public actor Kitten2WordAligner {
    public init() {}
    private static func module(language: String) async throws -> DictationTranscriber {
        guard let locale=await DictationTranscriber.supportedLocale(equivalentTo:Locale(identifier:language)) else {
            throw Kitten2RuntimeError(message:"On-device word timing is unavailable for this language.")
        }
        return DictationTranscriber(locale:locale,contentHints:[],transcriptionOptions:[],reportingOptions:[],attributeOptions:[.audioTimeRange,.transcriptionConfidence])
    }
    public static func isInstalled(language: String) async -> Bool {
        guard let module=try? await module(language:language) else { return false }
        return await AssetInventory.status(forModules:[module]) == .installed
    }
    public static func canAnalyze(language: String) async -> Bool {
        guard let module = try? await module(language: language), await AssetInventory.status(forModules: [module]) == .installed else { return false }
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) != nil
    }
    public static func prepare(language: String, download: Bool) async throws {
        let module=try await module(language:language)
        guard await AssetInventory.status(forModules:[module]) != .installed else { return }
        guard download else { throw Kitten2RuntimeError(message:"Open voice settings and prepare this language’s one-time Apple download for word highlighting.") }
        if let request=try await AssetInventory.assetInstallationRequest(supporting:[module]) {
            try await request.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules:[module]) == .installed else {
            throw Kitten2RuntimeError(message:"The language download could not finish. Try preparing this voice again.")
        }
    }
    private func audio(file: URL, module: DictationTranscriber) async throws -> AVAudioPCMBuffer {
        let source = try AVAudioFile(forReading: file)
        guard source.length > 0, Double(source.length) / source.processingFormat.sampleRate <= 30,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: source.processingFormat),
              let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)) else {
            throw Kitten2RuntimeError(message: "The voice audio could not be prepared for word highlighting.")
        }
        try source.read(into: input)
        if source.processingFormat.isEqual(format) { return input }
        guard let converter = AVAudioConverter(from: source.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / source.processingFormat.sampleRate)) + 64) else {
            throw Kitten2RuntimeError(message: "This device could not convert the voice audio for word highlighting.")
        }
        // Keep recognition time aligned with the original audio clock, without
        // adding resampler priming silence or assuming a device's sample rate.
        converter.primeMethod = .none
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard status != .error, output.frameLength > 0 else {
            throw Kitten2RuntimeError(message: "The voice audio could not be converted for word highlighting.")
        }
        return output
    }
    public func recognize(file: URL, language: String, context: String) async throws -> [Kitten2RecognizedSpan] {
        let module=try await Self.module(language:language)
        guard await AssetInventory.status(forModules:[module]) == .installed else {
            throw Kitten2RuntimeError(message:"Prepare this voice’s language in Settings before listening.")
        }
        let analyzer=SpeechAnalyzer(modules:[module],options:.init(priority:.userInitiated,modelRetention:.lingering))
        let hints=AnalysisContext(); hints.contextualStrings=[.general:[context]]
        try await analyzer.setContext(hints)
        return try await withTaskCancellationHandler {
            let output=Task { () throws -> [Kitten2RecognizedSpan] in
                var spans:[Kitten2RecognizedSpan]=[]
                for try await result in module.results {
                    for run in result.text.runs {
                        guard let time=run.audioTimeRange, (run.transcriptionConfidence ?? 1)>=0.25 else { continue }
                        spans.append(.init(text:String(result.text[run.range].characters),start:time.start.seconds,end:CMTimeRangeGetEnd(time).seconds))
                    }
                }
                return spans
            }
            do {
                let buffer = try await audio(file: file, module: module)
                try await analyzer.prepareToAnalyze(in: buffer.format)
                let input = AsyncStream<AnalyzerInput> { continuation in
                    continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: .zero)); continuation.finish()
                }
                if let end=try await analyzer.analyzeSequence(input) { try await analyzer.finalizeAndFinish(through:end) }
                else { await analyzer.cancelAndFinishNow() }
                return try await output.value
            } catch {
                await analyzer.cancelAndFinishNow(); output.cancel(); throw error
            }
        } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
    }
}
