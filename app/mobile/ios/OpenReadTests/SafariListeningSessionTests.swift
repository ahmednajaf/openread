import XCTest
@testable import OpenRead

final class SafariListeningSessionTests: XCTestCase {
    private var root: URL!
    private var store: SafariListeningSession!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SafariListeningSession(root: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func create() throws -> SafariListeningSession.Request {
        try store.create(tab: 7, title: "Arabic reading", source: "https://example.org/book", voice: "kitten2:ArabicFalconer", rate: 1.5, items: ["🌊 حين نقرأ", "نقرأ مرة أخرى"], index: 1)
    }
    func testAppHandoffKeepsExactUTF16OffsetsWithoutSavingToLibrary() throws {
        let request = try create()
        XCTAssertEqual(request.offsets, [0, "🌊 حين نقرأ".utf16.count + 2])
        XCTAssertEqual(request.reading.position, request.offsets[1])
        XCTAssertEqual((request.reading.text as NSString).substring(from: request.reading.position), "نقرأ مرة أخرى")
        XCTAssertEqual(try store.request(request.id, tab: 7).voice, "kitten2:ArabicFalconer")
        XCTAssertThrowsError(try store.request(request.id, tab: 8))
        XCTAssertThrowsError(try store.request("../../Models"))
    }
    func testWordRangesUseTheWebBridgeObjectContract() throws {
        let request = try create()
        let range = NSRange(location: request.offsets[1], length: 4)
        try store.write(.init(status: "playing", index: 1, rate: 1.5, word: .init(range), error: nil), id: request.id)
        let value = try store.state(request.id, tab: 7)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        let word = try XCTUnwrap(object["word"] as? [String: Int])
        XCTAssertEqual(word, ["location": range.location, "length": 4])
    }
    func testControlsCannotCrossTabsAndCommandsAreConsumedOnlyOnce() throws {
        let request = try create()
        XCTAssertThrowsError(try store.command(request.id, tab: 8, action: "pause", index: nil, rate: nil, autoplay: nil))
        XCTAssertThrowsError(try store.command(request.id, tab: 7, action: "rate", index: nil, rate: 5, autoplay: nil))
        XCTAssertThrowsError(try store.command(request.id, tab: 7, action: "seek", index: 9, rate: nil, autoplay: true))
        try store.command(request.id, tab: 7, action: "pause", index: nil, rate: nil, autoplay: nil)
        XCTAssertEqual(try store.takeCommands(request.id).map(\.action), ["pause"])
        XCTAssertTrue(try store.takeCommands(request.id).isEmpty)
    }
    func testEndedSessionsDoNotExhaustTheSmallActiveSessionLimit() throws {
        for _ in 0..<10 {
            let request = try create()
            try store.write(.init(status: "ended", index: 1, rate: 1.5, word: nil, error: nil), id: request.id)
        }
        XCTAssertNoThrow(try create())
    }
    func testInvalidOrOversizedHandoffsAreRejectedBeforeWriting() {
        for items in [[], [" "], [String(repeating: "a", count: 250_000)]] {
            XCTAssertThrowsError(try store.create(tab: 7, title: "Book", source: "https://example.org", voice: "kitten2:Arabic", rate: 1, items: items, index: 0))
        }
        XCTAssertThrowsError(try store.create(tab: 7, title: "Book", source: "file:///private", voice: "kitten2:Arabic", rate: 1, items: ["Words"], index: 0))
    }
}
