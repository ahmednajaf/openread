import XCTest
@testable import OpenRead

final class ReadingTests: XCTestCase {
    func testChunksKeepExactUnicodeRangesAndRepeatedWords() {
        let text = "🙂 I\n\nA title\n\nOne repeated phrase. One repeated phrase.\n\n" + String(repeating: "🌊 words ", count: 100)
        let chunks = ReadingText.passages(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks[0].text.hasPrefix("🙂 I"))
        for chunk in chunks { XCTAssertEqual(chunk.text, (text as NSString).substring(with: chunk.range)); XCTAssertLessThanOrEqual(chunk.text.utf16.count, 420) }
        XCTAssertEqual(chunks.map(\.text).joined().filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace })
    }
    func testEstimatedTimingsKeepUtf16OffsetsAndAdvanceEveryWord() {
        let words = ReadingText.estimatedWords("🌊 Read this. Read this.", duration: 4)
        XCTAssertEqual(words[1].range.location, 3)
        XCTAssertTrue(words.allSatisfy { $0.end > $0.start })
        XCTAssertEqual(words.last!.end, 4)
    }
    func testBackupIsValidatedBeforeAnyRestore() throws {
        let original = Reading(title: "A reading", text: "Keep this text.")
        let data = try JSONEncoder().encode(ReadingBackup(documents: [original]))
        XCTAssertEqual(try ReadingBackup.decode(data).documents[0], original)
        var invalid = original; invalid.position = -1
        XCTAssertThrowsError(try ReadingBackup.decode(JSONEncoder().encode(ReadingBackup(documents: [invalid]))))
        XCTAssertThrowsError(try ReadingBackup.decode(JSONEncoder().encode(ReadingBackup(documents: [original, original]))))
    }
}
