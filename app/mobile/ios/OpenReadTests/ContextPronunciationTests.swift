import XCTest
import AVFoundation
@testable import OpenRead

final class ContextPronunciationTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Tokens: Decodable { let text: String; let ids: [Int64] }
        struct Decision: Decodable { let text: String; let replacements: String }
        let tokenization: [Tokens]; let decisions: [Decision]
    }
    func testSharedTokenizationAndRealModelDecisions() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pronunciation", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let model = try XCTUnwrap(ContextPronunciation.shared)
        for row in fixture.tokenization { XCTAssertEqual(model.tokenIDs(row.text), row.ids, row.text) }
        for row in fixture.decisions { XCTAssertEqual(try model.replacements(row.text), row.replacements, row.text) }
        let past = try EnglishPronunciation.phonemes("Yesterday, I read the book from cover to cover.")
        XCTAssertTrue(past.contains("ˈɹɛd"), past)
        let present = try EnglishPronunciation.phonemes("I read the book every morning.")
        XCTAssertTrue(present.contains("ɹˈiːd"), present)
        let punctuation = try EnglishPronunciation.phonemes("Please close the door; the shop is close by.")
        XCTAssertTrue(punctuation.contains("ˈkloʊz")); XCTAssertTrue(punctuation.contains(";")); XCTAssertTrue(punctuation.hasSuffix("."))
    }
    func testAppleAnswersMustIncludeQuotesFromTheActualPassage() {
        XCTAssertEqual(AppleReadingTools.grounded("Invented", supported: false, quotes: [], source: "The source."), "That isn't stated in this passage.")
        XCTAssertEqual(AppleReadingTools.grounded("Invented", supported: true, quotes: ["A different source."], source: "The source."), "That isn't stated in this passage.")
        XCTAssertTrue(AppleReadingTools.grounded("The source", supported: true, quotes: ["The source."], source: "The source.").contains("Source:"))
    }
    func testAppleToolsBoundPassageAndQuestionInput() throws {
        XCTAssertNoThrow(try AppleReadingTools.validate("A complete passage.", question: "What does this mean?"))
        XCTAssertThrowsError(try AppleReadingTools.validate("   ", question: ""))
        XCTAssertThrowsError(try AppleReadingTools.validate(String(repeating: "a", count: 1_601), question: ""))
        XCTAssertThrowsError(try AppleReadingTools.validate("A passage.", question: String(repeating: "q", count: 501)))
    }
}


final class ContinuousSpeechPlayerTests: XCTestCase {
    @MainActor func testThreeChunksRenderOnOneUnbrokenTimeline() throws {
        let output = ContinuousSpeechPlayer()
        defer { output.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let samples = Array(repeating: Float(0.25), count: 24_000)
        let clip = SpokenClip(wav: SpeechTokens.wav(samples), words: [], duration: 1)
        try output.append(clip); XCTAssertFalse(output.isPlaying, "Build a small lead before starting")
        try output.append(clip); XCTAssertTrue(output.isPlaying)
        try output.append(clip); try output.finish()
        XCTAssertTrue(output.isPlaying)
        XCTAssertEqual(output.duration, 3, accuracy: 0.00001)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var rendered: [Float] = []
        while rendered.count < 72_000 {
            let count = AVAudioFrameCount(min(512, 72_000 - rendered.count))
            let status = try output.engine.renderOffline(count, to: buffer)
            XCTAssertEqual(status, .success)
            guard status == .success else { break }
            rendered.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        XCTAssertEqual(rendered.count, 72_000)
        // A constant waveform exposes even one inserted zero at either boundary.
        let expected = Float(Int16(0.25 * 32767)) / 32768
        XCTAssertTrue(rendered.allSatisfy { abs($0 - expected) < 0.0001 }, "Chunk boundaries inserted silence or changed samples")
        XCTAssertEqual(output.underruns, 0)
    }
    @MainActor func testShortFinalClipStartsWithoutWaitingForThreeSeconds() throws {
        let output = ContinuousSpeechPlayer(); defer { output.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let clip = SpokenClip(wav: SpeechTokens.wav(Array(repeating: Float(0.1), count: 4_800)), words: [], duration: 0.2)
        try output.append(clip); XCTAssertFalse(output.isPlaying)
        try output.finish(); XCTAssertTrue(output.isPlaying)
        output.stop(); XCTAssertFalse(output.isPlaying)
        try output.append(clip)
        XCTAssertEqual(output.duration, 0.2, accuracy: 0.00001, "Stopped streams must reject late chunks")
    }
    @MainActor func testSlowGenerationBuildsLeadAndPauseKeepsQueuedAudio() throws {
        var now = 0.0
        let output = ContinuousSpeechPlayer(clock: { now })
        defer { output.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let clip = SpokenClip(wav: SpeechTokens.wav(Array(repeating: Float(0.1), count: 24_000)), words: [], duration: 1)
        try output.append(clip); XCTAssertFalse(output.isPlaying)
        now = 20; try output.append(clip)
        XCTAssertTrue(output.isPlaying, "A slow producer must not make startup wait for the whole passage")
        try output.append(clip)
        output.pause(); try output.finish()
        XCTAssertFalse(output.isPlaying, "Finishing synthesis must not override the user's pause")
        XCTAssertEqual(output.duration, 3)
        try output.resume(); XCTAssertTrue(output.isPlaying)
        output.pause(); XCTAssertFalse(output.isPlaying)
        try output.resume(); XCTAssertTrue(output.isPlaying)
        XCTAssertEqual(output.duration, 3, "Resume must retain the same audio rather than restart synthesis")
    }
    @MainActor func testRealPlaybackDrainsAndRebuffersOnlyOnceWhenProducerFallsBehind() async throws {
        let output = ContinuousSpeechPlayer(); defer { output.stop() }
        let buffering = expectation(description: "The generated lead has played")
        let completed = expectation(description: "Final audio actually played")
        output.onStateChange = { playing in if !playing { buffering.fulfill() } }
        output.onFinished = { completed.fulfill() }
        let clip = SpokenClip(wav: SpeechTokens.wav(Array(repeating: Float(0.01), count: 24_000)), words: [], duration: 1)
        try output.append(clip); try output.append(clip); try output.append(clip)
        await fulfillment(of: [buffering], timeout: 8)
        XCTAssertEqual(output.underruns, 1)
        XCTAssertFalse(output.isPlaying)
        XCTAssertEqual(output.currentTime, 3, accuracy: 0.01)
        try output.append(clip); try output.append(clip)
        XCTAssertFalse(output.isPlaying, "Rebuild a lead instead of restarting every chunk")
        try output.append(clip); XCTAssertTrue(output.isPlaying)
        try output.finish()
        await fulfillment(of: [completed], timeout: 8)
        XCTAssertEqual(output.currentTime, 6, accuracy: 0.01)
        XCTAssertEqual(output.underruns, 1)
    }
    @MainActor func testStartupDeadlinePlaysAvailableAudioWithoutWaitingForAnotherChunk() async throws {
        let output = ContinuousSpeechPlayer(); defer { output.stop() }
        let started = expectation(description: "Start with available audio at the buffering deadline")
        output.onStateChange = { playing in if playing { started.fulfill() } }
        let clip = SpokenClip(wav: SpeechTokens.wav(Array(repeating: Float(0.01), count: 4_800)), words: [], duration: 0.2)
        try output.append(clip); XCTAssertFalse(output.isPlaying)
        await fulfillment(of: [started], timeout: 6)
        XCTAssertEqual(output.duration, 0.2, accuracy: 0.001)
    }
    @MainActor func testRejectsMalformedAudioBeforeScheduling() throws {
        let output = ContinuousSpeechPlayer(); defer { output.stop() }
        XCTAssertThrowsError(try output.append(SpokenClip(wav: Data(repeating: 0, count: 50), words: [], duration: 1)))
        XCTAssertEqual(output.duration, 0)
    }
}


final class QwenPhraseTimingTests: XCTestCase {
    func testRepeatedChunkSpansDoNotReplayWordsAndTailIsNotDropped() {
        let text = "Tell me, Muse, the story. Then follow the sea home."
        let first = (text as NSString).range(of: "Tell me, Muse, the story.")
        let second = (text as NSString).range(of: "Then follow")
        var timing = QwenPhraseTiming(text: text)
        for _ in 0..<8 { XCTAssertTrue(timing.append(span: first, seconds: 0.32).isEmpty) }
        let added = timing.append(span: second, seconds: 0.32)
        XCTAssertEqual(added.map(\.range), ReadingText.words(in: String(text.prefix(first.length))))
        for _ in 0..<7 { XCTAssertTrue(timing.append(span: second, seconds: 0.32).isEmpty) }
        _ = timing.finish()
        XCTAssertEqual(timing.words.map(\.range), ReadingText.words(in: text), "Every source word appears exactly once, including the unreported tail")
        XCTAssertEqual(timing.words.first?.start, 0)
        XCTAssertEqual(timing.words.last!.end, 5.12, accuracy: 0.0001)
        for pair in zip(timing.words, timing.words.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(pair.0.range), pair.1.range.location)
            XCTAssertEqual(pair.0.end, pair.1.start, accuracy: 0.0001)
        }
    }
    func testMissingStaleAndUnicodeSpansKeepWholeOriginalWords() {
        let text = "Athene’s 🌊 story. Café by the sea."
        var timing = QwenPhraseTiming(text: text)
        XCTAssertTrue(timing.append(span: nil, seconds: 0.32).isEmpty)
        XCTAssertTrue(timing.append(span: NSRange(location: 0, length: 8), seconds: 0.32).isEmpty)
        // A byte-sized partial span must never highlight part of a UTF-16 word.
        _ = timing.append(span: NSRange(location: 8, length: 9), seconds: 0.32)
        XCTAssertTrue(timing.append(span: NSRange(location: 0, length: 8), seconds: 0.32).isEmpty)
        _ = timing.finish()
        XCTAssertEqual(timing.words.map(\.range), ReadingText.words(in: text))
        XCTAssertEqual(timing.words.last!.end, 1.28, accuracy: 0.0001)
        XCTAssertTrue(timing.words.allSatisfy { $0.end > $0.start })
    }
}

extension ContinuousSpeechPlayerTests {
    @MainActor func testSpeedIncreaseKeepsSourceClockAndQueuedFollowingPassage() async throws {
        for speed: Float in [1.5, 2] {
            let output = ContinuousSpeechPlayer(); defer { output.stop() }
            let completed = expectation(description: "Both passages play at \(speed)x")
            output.onFinished = { completed.fulfill() }
            let clip = SpokenClip(wav: SpeechTokens.wav(Array(repeating: Float(0.01), count: 48_000)), words: [], duration: 2)
            try output.append(clip)
            try await Task.sleep(nanoseconds: 350_000_000)
            let before = output.currentTime
            XCTAssertGreaterThan(before, 0)
            output.rate = speed
            XCTAssertGreaterThanOrEqual(output.currentTime, before, "Changing speed must not reset the source clock")
            // A second logical passage is queued on the same engine while the
            // first is audible. It must not finish/reset at the passage boundary.
            try output.append(clip); try output.finish()
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertGreaterThan(output.currentTime - before, 0.5, "The source clock must advance faster at the higher rate")
            XCTAssertEqual(output.duration, 4, "Rate never changes source timing or skips audio")
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertEqual(output.currentTime, 4, accuracy: 0.01)
            XCTAssertEqual(output.underruns, 0)
        }
    }
    @MainActor func testSpeedChangeWhilePreparingRecalculatesLead() throws {
        let output = ContinuousSpeechPlayer(); defer { output.stop() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        try output.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let clip = SpokenClip(wav: SpeechTokens.wav(Array(repeating: Float(0.1), count: 24_000)), words: [], duration: 1)
        output.rate = 2
        try output.append(clip); try output.append(clip)
        XCTAssertFalse(output.isPlaying, "2x needs twice the source-audio lead")
        output.rate = 1
        XCTAssertTrue(output.isPlaying, "Lowering speed should use the existing sufficient lead immediately")
        XCTAssertEqual(output.duration, 2)
    }
}


final class QwenPreparedAudioTests: XCTestCase {
    func testDiskRoundTripRetainsAudioAndSourceTimingAcrossInstances() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "Athene’s sea."
        let words = ReadingText.estimatedWords(text, duration: 1).map { SpokenWord(range: $0.range, start: $0.start, end: $0.end) }
        let clip = SpokenClip(wav: SpeechTokens.wav(Array(repeating: Float(0.1), count: 24_000)), words: words, duration: 1)
        let key = QwenPreparedAudio.key(text: text, voice: "qwen:sohee", instruction: "")
        XCTAssertTrue(QwenPreparedAudio(root: root).store(clip, key: key))
        let loaded = try XCTUnwrap(QwenPreparedAudio(root: root).load(key, text: text))
        XCTAssertEqual(loaded.wav, clip.wav); XCTAssertEqual(loaded.words.map(\.range), words.map(\.range))
        XCTAssertNil(QwenPreparedAudio(root: root).load(key, text: "Different source."))
        XCTAssertNotEqual(key, QwenPreparedAudio.key(text: text, voice: "qwen:ryan", instruction: ""))
        XCTAssertNotEqual(key, QwenPreparedAudio.key(text: text, voice: "qwen:sohee", instruction: "Whisper"))
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(key + ".plist"))
        XCTAssertNil(QwenPreparedAudio(root: root).load(key, text: text))
    }
    func testBoundedCacheEvictsOldAudioAndRemovingVoiceKeepsOtherVoices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "Sea."
        let clip = SpokenClip(wav: SpeechTokens.wav(Array(repeating: Float(0.1), count: 24_000)), words: [SpokenWord(range: NSRange(location: 0, length: 4), start: 0, end: 1)], duration: 1)
        let first = QwenPreparedAudio.key(text: text, voice: "qwen:clone:test", instruction: "")
        let second = QwenPreparedAudio.key(text: text, voice: "qwen:sohee", instruction: "")
        let cache = QwenPreparedAudio(root: root, limit: 60_000)
        XCTAssertTrue(cache.store(clip, key: first))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: root.appendingPathComponent(first + ".plist").path)
        XCTAssertTrue(cache.store(clip, key: second))
        XCTAssertNil(cache.load(first, text: text)); XCTAssertNotNil(cache.load(second, text: text))
        let large = QwenPreparedAudio(root: root)
        XCTAssertTrue(large.store(clip, key: first))
        large.remove(voice: "qwen:clone:test")
        XCTAssertNil(large.load(first, text: text)); XCTAssertNotNil(large.load(second, text: text))
        XCTAssertFalse(QwenPreparedAudio(root: root, limit: 10).store(clip, key: first))
    }
}

extension QwenPreparedAudioTests {
    @MainActor func testPreparedReadingPlaysAcrossChaptersAtDoubleSpeedWithOrderedHighlights() async throws {
        guard QwenFiles.installed("expressive") else { throw XCTSkip("Install the public Qwen test pack first.") }
        let player = PlaybackController()
        let oldVoice = player.voice, oldRate = player.rate
        defer { player.stop(); player.voice = oldVoice; player.rate = oldRate }
        player.voice = "qwen:ryan"; player.rate = 2
        let first = "The sea carries Athene’s story."
        let second = "The voyage continues towards home."
        let text = first + "\n\n" + second
        let reading = Reading(title: "Prepared timeline fixture", text: text, chapters: [
            ReadingChapter(id: "one", title: "One", offset: 0),
            ReadingChapter(id: "two", title: "Two", offset: first.utf16.count + 2)
        ])
        let cache = QwenPreparedAudio()
        for part in ReadingText.passages(reading) {
            let words = ReadingText.estimatedWords(part.text, duration: 2).map { SpokenWord(range: $0.range, start: $0.start, end: $0.end) }
            let clip = SpokenClip(wav: SpeechTokens.wav(Array(repeating: Float(0.01), count: 48_000)), words: words, duration: 2)
            XCTAssertTrue(cache.store(clip, key: QwenPreparedAudio.key(text: part.text, voice: player.voice, instruction: player.direction)))
        }
        player.open(reading); player.prepareAudioAhead()
        let preparationDeadline = Date().addingTimeInterval(8)
        while player.isPreparing, Date() < preparationDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(player.error); XCTAssertEqual(player.status, "Audio ready · tap Play")
        player.play()
        var seen: [Int] = []; var chapters = Set<Int>()
        let deadline = Date().addingTimeInterval(6)
        while player.status != "Finished", Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            if player.isPlaying { chapters.insert(player.index) }
            if let range = player.highlighted, seen.last != range.location { seen.append(range.location) }
            if player.error != nil { break }
        }
        XCTAssertNil(player.error); XCTAssertEqual(player.status, "Finished")
        XCTAssertEqual(chapters, [0, 1]); XCTAssertGreaterThan(seen.count, 4)
        XCTAssertEqual(seen, seen.sorted(), "Cross-chapter highlights never jump back to earlier words")
        XCTAssertTrue(seen.contains { $0 >= first.utf16.count + 2 }, "Second-chapter ranges refer to the original whole book")
    }
    @MainActor func testCancellingPreparationCannotStartLatePlayback() async {
        let player = PlaybackController(); let oldVoice = player.voice
        defer { player.stop(); player.voice = oldVoice }
        player.voice = "qwen:sohee"
        player.open(Reading(title: "Cancellation", text: "A sea voyage."))
        player.prepareAudioAhead(); XCTAssertTrue(player.preparingAhead)
        player.pause()
        await Task.yield()
        XCTAssertFalse(player.preparingAhead); XCTAssertFalse(player.isPreparing); XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.status, "Paused")
    }
}
