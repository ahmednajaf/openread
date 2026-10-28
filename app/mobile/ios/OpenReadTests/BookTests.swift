import XCTest
import ZIPFoundation
@testable import OpenRead

final class BookTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL { try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "epub")) }
    func testContentsLinksWithinOneSpineFileKeepExactUnicodeLocations() async throws {
        let book = try await DocumentImporter().file(fixture("chapters"))
        XCTAssertEqual(book.chapterList.map(\.title), ["First & foremost", "Second chapter", "Final chapter"])
        XCTAssertEqual(book.author, "Fixture Author")
        let source = book.text as NSString
        XCTAssertTrue(source.substring(from: book.chapterList[1].offset).hasPrefix("Second heading"))
        XCTAssertFalse(book.text.contains("Do not speak the metadata")); XCTAssertFalse(book.text.contains("supplementary"))
    }
    @MainActor func testWholeBookShelfAndZipBackupRoundTrip() async throws {
        var book = try await DocumentImporter().file(fixture("full-book"))
        XCTAssertGreaterThan(book.text.utf16.count, 2_000_000)
        XCTAssertEqual(book.chapterList.count, 24)
        XCTAssertTrue(book.text.contains("linked words")); XCTAssertTrue(book.text.contains("First point."))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        try library.save(book)
        XCTAssertEqual(library.readings[0].text, "")
        XCTAssertGreaterThan(library.readings[0].wordCount, 100_000)
        let last = try XCTUnwrap(book.chapterList.last)
        try library.position(book.id, last.offset)
        book = try library.load(book.id)
        XCTAssertEqual(book.position, last.offset)
        let reopened = LibraryStore(root: root)
        XCTAssertNil(reopened.error); XCTAssertEqual(try reopened.load(book.id).text, book.text)
        let backup = try reopened.backup(); defer { try? FileManager.default.removeItem(at: backup) }
        let restored = LibraryStore(root: root.appendingPathComponent("restored"))
        try restored.restore(Data(contentsOf: backup))
        XCTAssertEqual(try restored.load(book.id).chapters, book.chapters)
        XCTAssertEqual(try restored.load(book.id).text, book.text)
        XCTAssertEqual(try restored.load(book.id).position, last.offset)
        let player = PlaybackController(); player.open(book)
        XCTAssertEqual(player.activeChapter, 23); XCTAssertLessThanOrEqual(player.visibleText.utf16.count, 64_000)
        player.seekOffset(book.chapterList[1].offset)
        XCTAssertEqual(player.activeChapter, 1); XCTAssertFalse(player.isPlaying)
        var previous = 0
        let windows = ReadingText.windows(book, passages: ReadingText.passages(book))
        XCTAssertGreaterThan(windows.count, book.chapterList.count)
        for window in windows { XCTAssertEqual(window.location, previous); XCTAssertLessThanOrEqual(window.length, 64_000); previous = NSMaxRange(window) }
        XCTAssertEqual(previous, book.text.utf16.count)
        player.seekOffset(0); player.seekTextWindow(1)
        XCTAssertEqual(player.position, windows[1].location)
        player.stop()
    }
    @MainActor func testLegacyLibraryMigratesWithoutDroppingTextProgressOrBookmarks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Reading(title: "Existing reading", text: "Read these words.", position: 5, bookmarks: [.init(offset: 5, label: "My place")])
        try JSONEncoder().encode(ReadingBackup(documents: [book])).write(to: root.appendingPathComponent("library.json"))
        let library = LibraryStore(root: root)
        XCTAssertNil(library.error); let migrated = try library.load(book.id)
        XCTAssertEqual(migrated.text, book.text); XCTAssertEqual(migrated.position, 5); XCTAssertEqual(migrated.bookmarks, book.bookmarks)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
    }
    @MainActor func testInvalidBookBackupCannotPartiallyReplaceTheShelf() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root); let original = Reading(title: "Keep me", text: "Existing text.")
        try library.save(original)
        let zip = root.appendingPathComponent("bad.zip"); let archive = try Archive(url: zip, accessMode: .create)
        for (name, body) in [("readings/0.json", try JSONEncoder().encode(Reading(title: "New", text: "Valid text."))), ("readings/1.json", Data("{}".utf8))] {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(body.count)) { position, size in body.subdata(in: Int(position)..<min(body.count, Int(position) + size)) }
        }
        XCTAssertThrowsError(try library.restore(Data(contentsOf: zip)))
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Books").path)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(library.readings.count, 1); XCTAssertEqual(try library.load(original.id).text, original.text)
    }

}
