import XCTest
import OpenReadKitten2
import OpenReadInference
import Speech
@testable import OpenRead

final class Kitten2NativeTests: XCTestCase {
    private func model() throws -> Kitten2LanguageModel {
        let root=AppFiles.models
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent("kitten2-lm-q4.gguf").path),
              FileManager.default.fileExists(atPath:root.appendingPathComponent("kitten2-voices.sqlite").path) else {
            throw XCTSkip("Install the optional Kitten TTS 2 test pack; tests never download its weights.")
        }
        return try Kitten2LanguageModel(model:root.appendingPathComponent("kitten2-lm-q4.gguf"),conditioning:root.appendingPathComponent("kitten2-voices.sqlite"))
    }
    func testAllVoicesHaveNativeSpeakerAndDecoderConditioning() throws {
        let model=try model()
        XCTAssertEqual(VoiceEngine.kitten2Voices.count,115)
        XCTAssertTrue(VoiceEngine.kitten2Voices.contains("kitten2:Arabic"))
        XCTAssertTrue(VoiceEngine.kitten2Voices.contains("kitten2:ArabicFalconer"))
        for voice in VoiceEngine.kitten2Voices {
            let data=try model.conditioning(voice:String(voice.dropFirst(8)))
            let value=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            XCTAssertEqual((value["speaker"] as? [Double])?.count,2048,voice)
            XCTAssertEqual((value["embedding"] as? [[Double]])?.first?.count,192,voice)
            let tokens=try XCTUnwrap((value["prompt_token"] as? [[Int]])?.first)
            let features=try XCTUnwrap((value["prompt_feat"] as? [[[Double]]])?.first)
            XCTAssertTrue((tokens.count*2...tokens.count*2+1).contains(features.count),voice)
            XCTAssertTrue(tokens.allSatisfy { (0..<6561).contains($0) },voice)
            XCTAssertTrue(features.allSatisfy { $0.count==80 && $0.allSatisfy(\.isFinite) },voice)
        }
    }
    func testArabicAndFalconerGenerateNativeAudio() async throws {
        let model=try model(), root=AppFiles.models
        let decoderURL=root.appendingPathComponent("kitten2-decoder.ort")
        guard FileManager.default.fileExists(atPath:decoderURL.path) else { throw XCTSkip("Prepare the pinned native Kitten TTS 2 decoder.") }
        let decoder=try XCTUnwrap(openread_kitten2_decoder_create(decoderURL.path),"The prepared decoder must load in native ONNX Runtime.")
        defer { openread_inference_destroy(decoder) }
        for voice in ["Arabic","ArabicFalconer","French"] {
            var generated:[Int32]=[]
            let text = voice == "French" ? "Quand nous lisons, nous apprenons quelque chose." : "حين نقرأ، نتعلم شيئاً جديداً."
            for try await batch in model.tokens(text:text,voice:voice,expressive:false,hasExpression:false,seed:1234) {
                if batch.finished { generated=batch.ids }
            }
            XCTAssertGreaterThan(generated.count,10,voice)
            XCTAssertLessThan(generated.count,1000,voice)
            let value=try XCTUnwrap(JSONSerialization.jsonObject(with:model.conditioning(voice:voice)) as? [String:Any])
            let prompt=try XCTUnwrap((value["prompt_token"] as? [[Int64]])?.first)
            let features=try XCTUnwrap((value["prompt_feat"] as? [[[Double]]])?.first).flatMap { $0.map(Float.init) }
            let embedding=try XCTUnwrap((value["embedding"] as? [[Double]])?.first).map(Float.init)
            let tokens=generated.prefix(100).map(Int64.init)+[4299,4299,4299]
            var audio:UnsafeMutablePointer<Float>?, count=0
            let ok=tokens.withUnsafeBufferPointer { ids in prompt.withUnsafeBufferPointer { prompt in
                features.withUnsafeBufferPointer { features in embedding.withUnsafeBufferPointer { embedding in
                    openread_kitten2_decoder_run(decoder,ids.baseAddress,ids.count,prompt.baseAddress,prompt.count,features.baseAddress,features.count,embedding.baseAddress,embedding.count,1234,&audio,&count)
                } }
            } }
            defer { openread_inference_free(audio) }
            XCTAssertEqual(ok,1,voice)
            if let audio {
                let samples=Array(UnsafeBufferPointer(start:audio,count:count))
                XCTAssertEqual(samples.count,tokens.count*960)
                XCTAssertTrue(samples.allSatisfy(\.isFinite))
                XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0,0.01,voice)
            }
        }
    }
    func testArabicSpeechAssetsExposeAUsableAudioFormat() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("On-device timing requires iOS 26.") }
        let supported = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ar"))
        let locale = try XCTUnwrap(supported)
        let module = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
        let status = await AssetInventory.status(forModules: [module])
        let formats = await module.availableCompatibleAudioFormats
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        print("ARABIC TIMING DIAGNOSTIC locale=\(locale.identifier) installed=\(await DictationTranscriber.installedLocales) status=\(status) formats=\(formats) best=\(String(describing: best))")
        #if targetEnvironment(simulator)
        if best == nil { throw XCTSkip("This simulator reports an installed Arabic asset but exposes no usable DictationTranscriber format. Validate word alignment on TestFlight hardware.") }
        #endif
        XCTAssertNotNil(best, "An installed language must expose a usable input format before synthesis.")
    }
    func testArabicStreamingUsesRealTimingsAcrossDecoderWindows() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("On-device timing requires iOS 26.") }
        let root = AppFiles.models
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("kitten2-lm-q4.gguf").path) else {
            throw XCTSkip("Prepare the optional local voice test pack first.")
        }
        let mayInstall = ProcessInfo.processInfo.environment["OPENREAD_PREPARE_TEST_LANGUAGE"] == "1"
        if !mayInstall, !(await Kitten2WordAligner.isInstalled(language: "ar")) {
            throw XCTSkip("Prepare Apple's Arabic timing asset explicitly before this integration test.")
        }
        try await Kitten2WordAligner.prepare(language: "ar", download: mayInstall)
        #if targetEnvironment(simulator)
        if !(await Kitten2WordAligner.canAnalyze(language: "ar")) {
            throw XCTSkip("Apple's Arabic timing engine is unavailable in this simulator; synthesis and source mapping have separate native tests.")
        }
        #endif
        let text = "حين نقرأ، لا نبحث عن الكلمات وحدها، بل عن المعنى الذي يجمعها. خذ وقتك، واستمع بهدوء؛ فلكل قصة إيقاعها الخاص."
        let inference = try Kitten2Inference(root: root)
        let started = Date()
        var chunks: [SpokenClip] = [], arrivals: [Double] = []
        let result = try await inference.generate(text, voice: "ArabicFalconer", fallbackLanguage: "ar") { clip in
            chunks.append(clip); arrivals.append(Date().timeIntervalSince(started))
        }
        XCTAssertGreaterThan(chunks.count, 1, "Exercise actual codec boundaries, not only one complete WAV.")
        XCTAssertGreaterThan(result.words.count, 8, "The source needs actual recognized word intervals.")
        XCTAssertEqual(chunks.reduce(0, { $0 + $1.wav.count - 44 }), result.wav.count - 44)
        XCTAssertEqual(chunks.reduce(0, { $0 + $1.duration }), result.duration, accuracy: 0.0001)
        for (index, word) in result.words.enumerated() {
            XCTAssertGreaterThan(word.range.length, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(word.range), text.utf16.count)
            XCTAssertGreaterThanOrEqual(word.start, 0)
            XCTAssertGreaterThan(word.end, word.start)
            XCTAssertLessThanOrEqual(word.end, result.duration)
            if index > 0 {
                XCTAssertGreaterThanOrEqual(word.range.location, result.words[index - 1].range.location, "Highlighting must not jump to earlier words at a codec boundary.")
                XCTAssertGreaterThanOrEqual(word.start, result.words[index - 1].start)
            }
        }
        let words = result.words.map { word in
            ["text": (text as NSString).substring(with: word.range), "offset": word.range.location,
             "length": word.range.length, "start": word.start, "end": word.end] as [String: Any]
        }
        let report: [String: Any] = ["voice": "ArabicFalconer", "chunkArrivals": arrivals,
            "chunkDurations": chunks.map(\.duration), "duration": result.duration, "words": words]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Arabic native streaming and source timing"; attachment.lifetime = .keepAlways; add(attachment)
        let audio = XCTAttachment(data: result.wav, uniformTypeIdentifier: "com.microsoft.waveform-audio")
        audio.name = "Arabic Falconer native stream"; audio.lifetime = .keepAlways; add(audio)
    }
    func testUnavailableTimingDoesNotBlockArabicStreamingAudio() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("The optional native pack requires iOS 26.") }
        guard FileManager.default.fileExists(atPath: AppFiles.models.appendingPathComponent("kitten2-lm-q4.gguf").path) else {
            throw XCTSkip("Prepare the optional local voice test pack first.")
        }
        if await Kitten2WordAligner.canAnalyze(language: "ar") { throw XCTSkip("This device has usable Arabic word timing; use the aligned-stream integration test.") }
        let inference = try Kitten2Inference(root: AppFiles.models)
        let started = Date()
        var chunks: [SpokenClip] = [], arrivals: [Double] = []
        let result = try await inference.generate("حين نقرأ، نبحث عن المعنى. خذ وقتك واستمع بهدوء.", voice: "ArabicFalconer", fallbackLanguage: "ar") {
            chunks.append($0); arrivals.append(Date().timeIntervalSince(started))
        }
        let report: [String: Any] = ["environment": "native test host; not a physical iPhone benchmark", "firstAudioSeconds": arrivals.first ?? -1,
            "chunkArrivals": arrivals, "chunkDurations": chunks.map(\.duration), "audioSeconds": result.duration]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Native Arabic stream without timing"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertGreaterThan(result.duration, 2)
        XCTAssertTrue(result.words.isEmpty, "Never invent word times when the recognizer is unavailable.")
        XCTAssertNotNil(result.timingWarning)
        XCTAssertEqual(chunks.reduce(0, { $0 + $1.wav.count - 44 }), result.wav.count - 44)
        XCTAssertEqual(chunks.reduce(0, { $0 + $1.duration }), result.duration, accuracy: 0.0001)
    }
    func testSourceMatchingKeepsRepeatedArabicWordsDistinct() {
        let text="🌊 حِينَ نقرأ، نتعلم. نقرأ مرة أخرى."
        let spans:[Kitten2RecognizedSpan]=[
            .init(text:"حين",start:0.1,end:0.3),.init(text:"نقرأ",start:0.3,end:0.6),
            .init(text:"نتعلم",start:0.8,end:1.1),.init(text:"نقرأ",start:1.3,end:1.6),
            .init(text:"مرة",start:1.6,end:1.9),.init(text:"أخرى",start:1.9,end:2.2)]
        let result=Kitten2SourceAlignment.words(text:text,recognized:spans)
        XCTAssertEqual(result.count,6)
        XCTAssertEqual(result.map { (text as NSString).substring(with:$0.range) },["حِينَ","نقرأ","نتعلم","نقرأ","مرة","أخرى"])
        XCTAssertLessThan(result[1].range.location,result[3].range.location)
        XCTAssertEqual(result.map(\.start),spans.map(\.start))
    }
    func testRecognitionGapsAndInsertedSoundsDoNotGetInventedTimings() {
        let text="A quiet blue sea, then a quiet shore."
        let spans:[Kitten2RecognizedSpan]=[.init(text:"quiet",start:0.4,end:0.8),.init(text:"blue",start:0.8,end:1),
            .init(text:"um",start:1,end:1.2),.init(text:"sea",start:1.3,end:1.5)]
        let result=Kitten2SourceAlignment.words(text:text,recognized:spans)
        XCTAssertEqual(result.map { (text as NSString).substring(with:$0.range) },["quiet","blue","sea"])
        XCTAssertEqual(result.map(\.start),[0.4,0.8,1.3])
        XCTAssertFalse(result.contains { (text as NSString).substring(with:$0.range)=="shore" })
    }
    func testGroupedRecognitionKeepsItsRealPhraseInterval() {
        let text="你好，世界。"
        let result=Kitten2SourceAlignment.words(text:text,recognized:[.init(text:"你好世界",start:0.2,end:1.4)])
        XCTAssertEqual(result.count,1)
        XCTAssertEqual(result.first?.start,0.2)
        XCTAssertEqual(result.first?.end,1.4)
    }
}
