import Foundation
import NaturalLanguage
import OpenReadKitten2
import OpenReadInference

@available(iOS 26, macOS 26, *)
actor Kitten2Inference {
    private struct Conditioning: Decodable {
        let prompt_token: [[Int64]]
        let prompt_feat: [[[Float]]]
        let embedding: [[Float]]
    }
    private let model: Kitten2LanguageModel
    private let decoder: UnsafeMutableRawPointer
    private let aligner=Kitten2WordAligner()
    private var cachedVoice: (String,Conditioning)?
    init(root: URL, useGPU: Bool? = nil) throws {
        model=try Kitten2LanguageModel(model:root.appendingPathComponent("kitten2-lm-q4.gguf"),conditioning:root.appendingPathComponent("kitten2-voices.sqlite"),useGPU:useGPU)
        guard let value=openread_kitten2_decoder_create(root.appendingPathComponent("kitten2-decoder.ort").path) else {
            throw Kitten2RuntimeError(message:"Kitten TTS 2’s audio decoder could not load. Prepare the voice pack again.")
        }
        decoder=value
    }
    deinit { openread_inference_destroy(decoder) }
    private func decode(_ tokens: [Int64], voice: Conditioning) throws -> [Float] {
        let prompt=voice.prompt_token.flatMap { $0 }, features=voice.prompt_feat.flatMap { $0.flatMap { $0 } }, embedding=voice.embedding.flatMap { $0 }
        var samples:UnsafeMutablePointer<Float>?, count=0
        let ok=tokens.withUnsafeBufferPointer { ids in prompt.withUnsafeBufferPointer { reference in
            features.withUnsafeBufferPointer { features in embedding.withUnsafeBufferPointer { embedding in
                openread_kitten2_decoder_run(decoder,ids.baseAddress,ids.count,reference.baseAddress,reference.count,
                    features.baseAddress,features.count,embedding.baseAddress,embedding.count,.random(in:0...UInt32.max),&samples,&count)
            } }
        } }
        defer { openread_inference_free(samples) }
        guard ok==1, let samples else { throw Kitten2RuntimeError(message:"The voice’s audio could not be decoded.") }
        return Array(UnsafeBufferPointer(start:samples,count:count))
    }
    private func conditioning(_ voice: String) throws -> Conditioning {
        if let cachedVoice, cachedVoice.0==voice { return cachedVoice.1 }
        let result=try JSONDecoder().decode(Conditioning.self,from:model.conditioning(voice:voice))
        cachedVoice=(voice,result);return result
    }
    static func language(text: String, fallback: String) -> String {
        guard text.count>=20, let language=NLLanguageRecognizer.dominantLanguage(for:text)?.rawValue else { return fallback }
        return language
    }
    private func chunks(_ text: String) throws -> [(String,NSRange)] {
        let source=text as NSString
        guard source.length>0 else { return [] }
        let sentences=NLTokenizer(unit:.sentence);sentences.string=text
        var ends:[Int]=[]
        sentences.enumerateTokens(in:text.startIndex..<text.endIndex) { range,_ in ends.append(NSMaxRange(NSRange(range,in:text)));return true }
        if ends.last != source.length { ends.append(source.length) }
        var result:[(String,NSRange)]=[], start=0
        for end in ends {
            let candidate=source.substring(with:NSRange(location:start,length:end-start))
            if try model.tokenCount(candidate)<=128 { continue }
            let preceding=ends.last { $0>start && $0<end }
            if let preceding {
                result.append((source.substring(with:NSRange(location:start,length:preceding-start)),NSRange(location:start,length:preceding-start)))
                start=preceding
            }
            while try model.tokenCount(source.substring(with:NSRange(location:start,length:end-start)))>128 {
                let segment=source.substring(with:NSRange(location:start,length:end-start))
                let words=NLTokenizer(unit:.word);words.string=segment
                var split:Int?
                words.enumerateTokens(in:segment.startIndex..<segment.endIndex) { range,_ in
                    let edge=NSMaxRange(NSRange(range,in:segment))
                    if let count=try? model.tokenCount(source.substring(with:NSRange(location:start,length:edge))), count<=128 { split=start+edge;return true }
                    return false
                }
                guard let split, split>start else { throw ReadingError.speechTooComplex }
                result.append((source.substring(with:NSRange(location:start,length:split-start)),NSRange(location:start,length:split-start)))
                start=split
            }
        }
        if start<source.length { result.append((source.substring(from:start),NSRange(location:start,length:source.length-start))) }
        return result
    }
    func generate(_ text: String, voice: String, fallbackLanguage: String,
                  onChunk: ((SpokenClip)->Void)?) async throws -> SpokenClip {
        try await withTaskCancellationHandler {
            try await generateSpeech(text,voice:voice,fallbackLanguage:fallbackLanguage,onChunk:onChunk)
        } onCancel: { [model] in model.cancel() }
    }
    private func generateSpeech(_ text: String, voice: String, fallbackLanguage: String,
                               onChunk: ((SpokenClip)->Void)?) async throws -> SpokenClip {
        let selected=try conditioning(voice)
        let language=Self.language(text:text,fallback:fallbackLanguage)
        var alignWords = await Kitten2WordAligner.canAnalyze(language: language)
        var timingWarning: String? = alignWords ? nil : "Word highlighting is unavailable for this language on this device."
        var complete:[Float]=[], allWords:[SpokenWord]=[]
        let expressive=UserDefaults.standard.bool(forKey:"kitten2-expressive")
        let emotion=UserDefaults.standard.string(forKey:"kitten2-emotion") ?? "natural"
        let emotions=Set(["mundane","nervous","tender","angry","excited","stern","sad","contemplative","surprised","joyful"])
        for (part,range) in try chunks(text) {
            let directed=emotions.contains(emotion) ? "[\(emotion)] " + part : part
            let hasExpression=directed.range(of:"\\[(?:mundane|nervous|tender|angry|excited|stern|sad|contemplative|surprised|joyful)\\]|<(?:pause|sigh|gasp|laugh|giggle|sob|scoff|growl|um|gulp)>|\\(\\(\\(",options:.regularExpression) != nil
            var written=0, cursor=0, tail:[Float]=[]
            for try await batch in model.tokens(text:directed,voice:voice,expressive:expressive,hasExpression:hasExpression) {
                try Task.checkCancellation()
                while batch.finished ? written<batch.ids.count : batch.ids.count-written >= (written==0 ? 64:96)+8 {
                    let amount=min(written==0 ? 64:96,batch.ids.count-written)
                    let final=batch.finished && written+amount==batch.ids.count
                    let lower=max(0,written-24), upper=min(batch.ids.count,written+amount+8)
                    var ids=batch.ids[lower..<upper].map(Int64.init)
                    if final { ids += [4299,4299,4299] }
                    let waveform=try decode(ids,voice:selected)
                    try Task.checkCancellation()
                    let begin=(written-lower)*960-(written==0 ? 0:240)
                    let finish=(written+amount-lower)*960+(final ? 2880:-240)
                    guard begin>=0, finish>begin, finish<=waveform.count else { throw ReadingError.noText }
                    var audio=Array(waveform[begin..<finish])
                    if !tail.isEmpty {
                        for index in 0..<min(tail.count,audio.count) {
                            let mix=Float(index)/Float(tail.count)
                            audio[index]=tail[index]*(1-mix)+audio[index]*mix
                        }
                    }
                    tail=final ? []:Array(waveform[((written+amount-lower)*960-240)..<((written+amount-lower)*960)])
                    let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
                    defer { try? FileManager.default.removeItem(at:file) }
                    try SpeechTokens.wav(waveform).write(to:file,options:.atomic)
                    var recognized: [Kitten2RecognizedSpan] = []
                    if alignWords {
                        do { recognized = try await aligner.recognize(file: file, language: language, context: part) }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            try Task.checkCancellation()
                            alignWords = false
                            timingWarning = "Word highlighting could not continue. Audio playback is still available."
                        }
                    }
                    try Task.checkCancellation()
                    let found=Kitten2SourceAlignment.words(text:part,recognized:recognized,startingAt:cursor)
                    let start=Double(begin)/24_000, end=Double(finish)/24_000
                    let timing=found.compactMap { word -> SpokenWord? in
                        guard word.end>start, word.start<end else { return nil }
                        return SpokenWord(range:NSRange(location:range.location+word.range.location,length:word.range.length),
                            start:max(0,word.start-start),end:min(end-start,word.end-start))
                    }
                    if let last=timing.last {
                        let before=(part as NSString).substring(to:max(0,last.range.location-range.location))
                        let words=NLTokenizer(unit:.word);words.string=before
                        let ranges=words.tokens(for:before.startIndex..<before.endIndex)
                        cursor=ranges.suffix(2).first.map { NSRange($0,in:before).location } ?? 0
                    }
                    SpeechSourceTiming.append(timing,offset:Double(complete.count)/24_000,to:&allWords)
                    complete.append(contentsOf:audio)
                    onChunk?(SpokenClip(wav:SpeechTokens.wav(audio),words:timing,duration:Double(audio.count)/24_000,timingWarning:timingWarning))
                    written+=amount
                }
            }
        }
        guard !complete.isEmpty else { throw ReadingError.noText }
        return SpokenClip(wav:SpeechTokens.wav(complete),words:allWords,duration:Double(complete.count)/24_000,timingWarning:timingWarning)
    }
}
