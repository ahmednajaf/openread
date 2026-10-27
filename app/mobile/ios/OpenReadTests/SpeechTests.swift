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
