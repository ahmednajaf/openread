import XCTest
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
