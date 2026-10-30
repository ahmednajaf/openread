import XCTest
@testable import OpenRead

final class SpeechTests: XCTestCase {
    @MainActor func testPlaybackSpeedDoesNotReenterItsPublishedSetter() async {
        let player = PlaybackController()
        let original = player.rate
        defer { player.rate = original; player.stop() }
        player.rate = 1.5
        XCTAssertEqual(player.rate, 1.5)
        player.rate = 10
        XCTAssertEqual(player.rate, 2)
        player.rate = -.infinity
        XCTAssertEqual(player.rate, 1)
    }
    func testBritishVoicesAlsoUseTheContextualPronunciationModel() throws {
        let past = try EnglishPronunciation.phonemes("Yesterday I read the book.", language: "en-gb")
        let present = try EnglishPronunciation.phonemes("I read the book every morning.", language: "en-gb")
        XCTAssertTrue(past.contains("ɹɛd"), past)
        XCTAssertTrue(present.contains("iːd"), present)
    }
    func testClausePunctuationReachesTheVoice() throws {
        let ipa = try EnglishPronunciation.phonemes("Hello, world! Are you ready? Yes; let's begin.")
        XCTAssertEqual(ipa.filter { ",!?;.".contains($0) }, ",!?;.")
        XCTAssertTrue(ipa.contains("ˈ"))
        XCTAssertFalse(ipa.contains("Hello"))
    }
    func testEnglishDictionaryHandlesContractionsAndOdysseyNames() throws {
        let ipa = try EnglishPronunciation.phonemes("Don't rush. Tell me, Muse, the story of Odysseus and the Nymph.")
        XCTAssertTrue(ipa.contains("dˈoʊnt"))
        XCTAssertTrue(ipa.contains("ɑːdˈɪsɪəs"))
        XCTAssertTrue(ipa.contains("nˈɪmf"))
        XCTAssertEqual(ipa.filter { $0 == "," }.count, 2)
    }
    func testTokenChunksNeverBisectAWordOrLosePunctuation() throws {
        let ipa = String(repeating: "həlˈoʊ wˈɜːld! ", count: 80)
        let chunks = try SpeechTokens.chunks(ipa)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { SpeechTokens.body($0).count <= 397 })
        XCTAssertEqual(chunks.joined(separator: " ").split(separator: " "), ipa.split(separator: " "))
        XCTAssertThrowsError(try SpeechTokens.chunks(String(repeating: "ɑ", count: 398)))
    }
    func testRepeatedNamesAndQuotedSoundsKeepTheirSourceWordSpans() throws {
        let text = "Nora turned the toy’s head and leaned to the right. It banked sharply. Nora fitted a motor that went “Br-r-r” and made sounds like “Powie” and “Sh-sh-shshsh.”"
        let phonemes = try EnglishPronunciation.phonemes(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let spans = try SpeechSourceTiming.spans(text, phonemes: phonemes)
        let expected = ReadingText.words(in: text)
        let found = Set(spans.map { "\($0.offset):\($0.length)" })
        for range in expected {
            XCTAssertTrue(found.contains("\(range.location):\(range.length)"), "Missing timing for \((text as NSString).substring(with: range))")
        }
        XCTAssertEqual(spans.map(\.offset), spans.map(\.offset).sorted())
    }
    func testTailTrimmingCannotCutAnAudibleEnding() {
        let audible = [Float](repeating: 0.2, count: 7200)
        XCTAssertEqual(SpeechTokens.trimSilence(audible), audible)
        let padded = audible + [Float](repeating: 0, count: 9000)
        let trimmed = SpeechTokens.trimSilence(padded)
        XCTAssertEqual(Array(trimmed.prefix(audible.count)), audible)
        XCTAssertGreaterThanOrEqual(trimmed.count, audible.count + 2400)
        XCTAssertGreaterThanOrEqual(trimmed.count, padded.count - 4800)
    }
}


final class StableReadingPlaybackTests: XCTestCase {
    @MainActor func testKittenAndKokoroCrossPassagesAtDoubleSpeedWithoutHighlightResets() async throws {
        let voices = VoiceEngine()
        guard await voices.isInstalled(), await voices.isInstalled(voice: "af_heart") else {
            throw XCTSkip("Install Kitten and Kokoro to run real streaming playback checks.")
        }
        let player = PlaybackController()
        let originalVoice = player.voice, originalRate = player.rate
        defer { player.stop(); player.voice = originalVoice; player.rate = originalRate }
        let text = String(repeating: "Tell me the story of that resourceful man who wandered far and wide. He saw many cities and learnt their ways. ", count: 5)
        for voice in ["kiki", "af_heart"] {
            player.voice = voice; player.rate = 2
            player.open(Reading(title: "Streaming test", text: text))
            XCTAssertGreaterThan(player.passageCount, 1)
            player.play()
            var positions: [Int] = [], paused = false
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline, player.status != "Finished", player.error == nil {
                try await Task.sleep(for: .milliseconds(30))
                if let range = player.highlighted, positions.last != range.location {
                    positions.append(range.location)
                    if positions.count >= 5, !paused {
                        paused = true; player.pause()
                        XCTAssertNil(player.highlighted)
                        try await Task.sleep(for: .milliseconds(150))
                        XCTAssertNil(player.highlighted)
                        player.play()
                    }
                }
            }
            XCTAssertNil(player.error, voice)
            XCTAssertEqual(player.status, "Finished", voice)
            XCTAssertNil(player.highlighted, voice)
            XCTAssertGreaterThan(player.index, 0, voice)
            XCTAssertGreaterThan(positions.count, 20, voice)
            XCTAssertEqual(positions, positions.sorted(), "Highlights went backwards for \(voice)")
            player.stop()
        }
    }
}
