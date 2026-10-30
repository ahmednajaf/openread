import XCTest
import AVFoundation
import UIKit
@testable import OpenRead

final class ImportTests: XCTestCase {
    func testSafariMappedModelProducesSpeechWithoutASecondWeightCopy() async throws {
        let engine = VoiceEngine()
        guard await engine.isInstalled() else { throw XCTSkip("Install the voice pack in the test app first.") }
        try await engine.prepare(download: false) { _ in }
        let mapped = try LocalVoiceInference(root: AppFiles.models, forSafari: true)
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
    func testIncompleteEPUBGivesAnActionableErrorWithoutChangingTheSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = folder.appendingPathComponent("unfinished.epub")
        let data = Data(try Data(contentsOf: fixture("ordered", "epub")).dropLast(22))
        try data.write(to: book)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("OpenRead-import-") })
        do { _ = try await DocumentImporter().file(book); XCTFail("A truncated EPUB cannot be imported") }
        catch {
            XCTAssertTrue(error is ImportFailure)
            XCTAssertTrue(error.localizedDescription.contains("Download it again"))
            XCTAssertFalse(error.localizedDescription.contains("ArchiveError"))
        }
        XCTAssertEqual(try Data(contentsOf: book), data)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("OpenRead-import-") })
        XCTAssertEqual(after, before, "Failed imports must remove their temporary copies")
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


final class LocalVoiceTimingTests: XCTestCase {
    private let passages = [
        "en-us": "Yesterday I read the book. Today I read it again; don't rush the ending!",
        "en-gb": "Yesterday I read the book. Today I read it again; don't rush the ending!",
        "es": "La lectura nos permite descubrir historias. Escucha con calma y disfruta de cada palabra.",
        "fr-fr": "La lecture nous permet de découvrir des histoires. Écoutez tranquillement et profitez de chaque mot.",
        "hi": "पढ़ना हमें नई कहानियाँ खोजने देता है। आराम से सुनिए और हर शब्द का आनंद लीजिए।",
        "it": "La lettura ci permette di scoprire nuove storie. Ascolta con calma e goditi ogni parola.",
        "pt-br": "A leitura permite descobrir novas histórias. Escute com calma e aproveite cada palavra."
    ]
    private func installedEngine() async throws -> VoiceEngine {
        let engine = VoiceEngine()
        guard await engine.isInstalled(), await engine.isInstalled(voice: "af_heart") else {
            throw XCTSkip("Install both optional voice packs to run real native inference checks.")
        }
        return engine
    }
    func testEveryStableVoiceProducesOrderedSourceTimings() async throws {
        let engine = try await installedEngine()

        for voice in VoiceEngine.kittenVoices + VoiceEngine.kokoroVoices {
            let text = try XCTUnwrap(passages[VoiceEngine.language(voice)])
            let installed = await engine.isInstalled(voice: voice)
            XCTAssertTrue(installed, "Missing fixture: \(voice)")
            try await engine.prepare(voice: voice, download: false) { _ in }
            let start = Date()
            let clip = try await engine.generate(text, voice: voice)
            if ["kiki", "af_heart", "bf_emma", "ef_dora", "ff_siwis", "hf_alpha", "if_sara", "pf_dora"].contains(voice) {
                let folder = AppFiles.root.appendingPathComponent("VoiceChecks")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try clip.wav.write(to: folder.appendingPathComponent(voice + ".wav"))
                try JSONEncoder().encode(clip.words).write(to: folder.appendingPathComponent(voice + ".json"))
            }
            print("VOICE_BENCH \(voice) generated=\(Date().timeIntervalSince(start)) audio=\(clip.duration)")
            XCTAssertEqual(clip.words.map(\.range), ReadingText.words(in: text), voice)
            XCTAssertTrue(clip.words.allSatisfy { $0.start >= 0 && $0.end > $0.start && $0.end <= clip.duration }, voice)
            for (a,b) in zip(clip.words, clip.words.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 0.001, voice) }
        }
    }
    func testSafariMappedRuntimeSupportsEveryLanguage() async throws {
        _ = try await installedEngine()
        let mapped = try LocalVoiceInference(root: AppFiles.models, kokoro: true, forSafari: true)
        for voice in ["af_heart", "bf_emma", "ef_dora", "ff_siwis", "hf_alpha", "if_sara", "pf_dora"] {
            let text = try XCTUnwrap(passages[VoiceEngine.language(voice)])
            let clip = try mapped.generate(text, voice: voice)
            XCTAssertEqual(clip.words.map(\.range), ReadingText.words(in: text), voice)
            XCTAssertTrue(clip.words.allSatisfy { $0.start >= 0 && $0.end > $0.start && $0.end <= clip.duration }, voice)
        }
    }
    func testLongContextChunksKeepEveryOriginalWordIncludingRepeatedWords() async throws {
        let engine = try await installedEngine()
        let text = String(repeating: "The Nymph waited by the sea, and Odysseus read the letter again. ", count: 12)
        for voice in ["kiki", "af_heart", "bf_emma"] {
            try await engine.prepare(voice: voice, download: false) { _ in }
            var chunks: [SpokenClip] = []
            for try await clip in await engine.stream(text, voice: voice) { chunks.append(clip) }
            XCTAssertGreaterThan(chunks.count, 1, voice)
            var words: [SpokenWord] = []; var duration = 0.0
            for chunk in chunks { SpeechSourceTiming.append(chunk.words, offset: duration, to: &words); duration += chunk.duration }
            XCTAssertEqual(words.map(\.range), ReadingText.words(in: text), voice)
            for (a,b) in zip(words, words.dropFirst()) {
                XCTAssertLessThan(a.range.location, b.range.location, voice)
                XCTAssertLessThanOrEqual(a.end, b.start + 0.001, voice)
            }
            let mapped = try LocalVoiceInference(root: AppFiles.models, kokoro: VoiceEngine.isKokoro(voice), forSafari: true)
            let safari = try mapped.generate("Don't rush. Read the last word!", voice: voice)
            XCTAssertEqual(safari.words.map(\.range), ReadingText.words(in: "Don't rush. Read the last word!"), voice)
        }
    }
    func testUnicodeAndSpokenNumbersRetainSourceRanges() async throws {
        let engine = try await installedEngine()
        let text = "Café costs £12.50 today. I've read 2024 pages—really! Next, read chapter 3."
        for voice in ["kiki", "af_heart"] {
            try await engine.prepare(voice: voice, download: false) { _ in }
            let clip = try await engine.generate(text, voice: voice)
            XCTAssertEqual(clip.words.map(\.range), ReadingText.words(in: text), voice)
        }
    }
}
