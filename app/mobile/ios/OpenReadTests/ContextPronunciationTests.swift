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
