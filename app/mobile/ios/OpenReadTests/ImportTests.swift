import XCTest
import AVFoundation
import UIKit
@testable import OpenRead

final class ImportTests: XCTestCase {
    func testSafariMappedModelProducesSpeechWithoutASecondWeightCopy() async throws {
        let engine = VoiceEngine()
        guard await engine.isInstalled() else { throw XCTSkip("Install the voice pack in the test app first.") }
        try await engine.prepare(download: false) { _ in }
        let mapped = try KittenInference(root: AppFiles.models, forSafari: true)
        let text = "Tell me, Muse, the story of that resourceful man."
        let clip = try mapped.generate(text, voice: "kiki")
        XCTAssertGreaterThan(clip.duration, 0.1)
        XCTAssertTrue(clip.wav.dropFirst(44).contains(where: { $0 != 0 }))
        XCTAssertEqual(clip.words.count, ReadingText.words(in: text).count)
        XCTAssertTrue(clip.words.allSatisfy { $0.end > $0.start && $0.end <= clip.duration })
    }
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }
    func testArticleKeepsLinkWordsAndListOrderButRemovesChrome() async throws {
        let reading = try await DocumentImporter().file(fixture("article", "html"))
        XCTAssertTrue(reading.text.contains("linked words"))
        XCTAssertFalse(reading.text.contains("4 minutes")); XCTAssertFalse(reading.text.contains("Skip navigation")); XCTAssertFalse(reading.text.contains("Subscribe now"))
        XCTAssertTrue(reading.text.range(of: "First point.")!.lowerBound < reading.text.range(of: "Second point.")!.lowerBound)
    }
    func testEPUBUsesSpineRatherThanZipOrManifestOrder() async throws {
        let reading = try await DocumentImporter().file(fixture("ordered", "epub"))
        XCTAssertTrue(reading.text.range(of: "first chapter")!.lowerBound < reading.text.range(of: "second chapter")!.lowerBound)
    }
    func testDOCXParagraphsRemainSeparate() async throws {
        let reading = try await DocumentImporter().file(fixture("paragraphs", "docx"))
        XCTAssertTrue(reading.text.contains("The first paragraph.\n\nThe second paragraph."))
    }
    func testDocumentsCannotResolveExternalEntities() async throws {
        do { _ = try await DocumentImporter().file(fixture("external", "docx")); XCTFail("External entities must be rejected") }
        catch { XCTAssertTrue(error is ReadingError) }
    }
    @MainActor func testPlaybackAdvancesAndPauseClearsHighlight() async throws {
        guard await VoiceEngine().isInstalled() else { throw XCTSkip("Install the voice pack in the test app first.") }
        let player = PlaybackController()
        player.open(Reading(title: "Playback check", text: "Tell me, Muse, the story of that resourceful man who wandered far and wide."))
        player.play()
        let deadline = Date().addingTimeInterval(12)
        var seen = Set<Int>()
        while Date() < deadline, seen.count < 3 {
            try await Task.sleep(for: .milliseconds(50))
            if let range = player.highlighted { seen.insert(range.location) }
            if player.error != nil { break }
        }
        XCTAssertNil(player.error); XCTAssertGreaterThanOrEqual(seen.count, 3)
        player.pause(); XCTAssertFalse(player.isPlaying); XCTAssertNil(player.highlighted)
        player.stop()
    }
    @MainActor func testExportedAudioHasAValidPlayableHeader() async throws {
        guard await VoiceEngine().isInstalled() else { throw XCTSkip("Install the voice pack in the test app first.") }
        let player = PlaybackController()
        player.open(Reading(title: "Audio export check", text: String(repeating: "Read these words slowly. ", count: 20)))
        let url = try await player.exportAudio { _, _ in }
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        let decoder = try AVFoundation.AVAudioPlayer(data: data)
        XCTAssertGreaterThan(decoder.duration, 1)
        let size = data[40..<44].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        XCTAssertEqual(Int(size), data.count - 44)
    }
    @MainActor func testImageOCRWorksOffline() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 300), format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 1200, height: 300))
            ("Read these words clearly." as NSString).draw(at: CGPoint(x: 50, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 66), .foregroundColor: UIColor.black])
        }
        let reading = try await DocumentImporter().image(XCTUnwrap(image.pngData()))
        XCTAssertTrue(reading.text.localizedCaseInsensitiveContains("Read these words"))
    }
    func testLocalKittenProducesAudibleAudioAndValidSourceRanges() async throws {
        let engine = VoiceEngine()
        guard await engine.isInstalled() else { throw XCTSkip("Install the voice pack in the test app to run offline inference checks.") }
        try await engine.prepare(download: false) { _ in }
        for (voice, text) in [("kiki", "Tell me, Muse, the story of that resourceful man."), ("rosie", "I"), ("jasper", "Read these words. Read these words.")] {
            let clip = try await engine.generate(text, voice: voice)
            XCTAssertGreaterThan(clip.duration, 0.02); XCTAssertGreaterThan(clip.wav.count, 44)
            XCTAssertEqual(clip.words.count, ReadingText.words(in: text).count)
            XCTAssertTrue(clip.words.allSatisfy { $0.start >= 0 && $0.end > $0.start && $0.end <= clip.duration && NSMaxRange($0.range) <= text.utf16.count })
        }
    }
}
