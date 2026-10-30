import XCTest
import UIKit
@testable import OpenRead

final class BookPaginationTests: XCTestCase {
    @MainActor func testPagesPreserveEveryUnicodeCharacterWithoutOverlap() {
        let text = String(repeating: "🌊 A café, a repeated word, and a family 👨‍👩‍👧‍👦.\n\nحين نقرأ، نبحث عن المعنى.\n\n", count: 90)
        let pages = BookPagination(text: text, bodySize: CGSize(width: 290, height: 380), font: BookPagination.font(for: .large))
        XCTAssertGreaterThan(pages.ranges.count, 4)
        let source = text as NSString
        XCTAssertEqual(pages.ranges.map { source.substring(with: $0) }.joined(), text)
        var end = 0
        for range in pages.ranges {
            XCTAssertEqual(range.location, end)
            XCTAssertGreaterThan(range.length, 0)
            let composed = source.rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1)
            XCTAssertLessThanOrEqual(NSMaxRange(composed), NSMaxRange(range), "Do not cut emoji or combining marks")
            end = NSMaxRange(range)
        }
        XCTAssertEqual(end, text.utf16.count)
    }
    @MainActor func testDynamicTypeReflowsAroundTheSameSourceWord() {
        let text = String(repeating: "Every page keeps its original source position. ", count: 150)
        let regular = BookPagination(text: text, bodySize: CGSize(width: 320, height: 480), font: BookPagination.font(for: .large))
        let accessible = BookPagination(text: text, bodySize: CGSize(width: 320, height: 480), font: BookPagination.font(for: .accessibilityExtraExtraExtraLarge))
        let anchor = regular.ranges[2].location + 8
        XCTAssertGreaterThan(accessible.ranges.count, regular.ranges.count)
        XCTAssertTrue(NSLocationInRange(anchor, accessible.ranges[accessible.page(containing: anchor)]))
        XCTAssertEqual(accessible.ranges.last.map(NSMaxRange), text.utf16.count)
    }
    func testLayoutsRespectRealFoldRegionsRatherThanHingeThresholds() {
        let phone = BookLayout.resolve(size: CGSize(width: 390, height: 700))
        XCTAssertEqual(phone.pages, 1)
        let flat = BookLayout.resolve(size: CGSize(width: 950, height: 620), division: CGRect(x: 480, y: 0, width: 0, height: 620))
        XCTAssertEqual(flat.pages, 2); XCTAssertEqual(flat.book.midX, 480)
        let fold = CGRect(x: 450, y: 0, width: 50, height: 620)
        let book = BookLayout.resolve(size: CGSize(width: 950, height: 620), division: fold, active: true)
        XCTAssertGreaterThanOrEqual(book.controls.minX, fold.maxX)
        XCTAssertEqual(book.book.midX, fold.midX)
        let horizontal = CGRect(x: 0, y: 300, width: 950, height: 24)
        let tabletop = BookLayout.resolve(size: CGSize(width: 950, height: 650), division: horizontal, active: true)
        XCTAssertEqual(tabletop.kind, .tabletop)
        XCTAssertLessThan(tabletop.book.maxY, horizontal.minY)
        XCTAssertGreaterThan(tabletop.controls.minY, horizontal.maxY)
    }
    func testArabicUsesRightToLeftPageOrderAndEnglishDoesNot() {
        XCTAssertTrue(BookPagination.isRightToLeft("حين نقرأ، نبحث عن المعنى الذي يجمع الكلمات. لكل قصة إيقاعها الخاص."))
        XCTAssertFalse(BookPagination.isRightToLeft("Tell me the story of that resourceful man who wandered far and wide."))
    }
    @MainActor func testPageSeekAndReopeningKeepTheExactSourceAnchor() {
        let text = "🌊 First page. A second page begins here, in the middle of a passage.\n\nThe last page."
        let range = (text as NSString).range(of: "second")
        let player = PlaybackController()
        defer { player.stop() }
        player.open(Reading(title: "Book", text: text))
        player.seekToPage(range.location)
        XCTAssertEqual(player.position, range.location)
        XCTAssertTrue(player.currentPassage.contains("First page."), "Keep the preceding sentence context for synthesis")
        let saved = Reading(title: "Book", text: text, position: range.location)
        player.open(saved)
        XCTAssertEqual(player.position, range.location)
        XCTAssertTrue(player.currentPassage.contains("First page."), "Keep the preceding sentence context for synthesis")
        player.seekToPage(1) // Inside a surrogate pair: return a valid composed boundary.
        XCTAssertEqual(player.position, 0)
    }
    func testExactAudioSeekUsesModelTimesAndRetainsOriginalSourceRanges() throws {
        let words = [SpokenWord(range: NSRange(location: 0, length: 4), start: 0.1, end: 0.3),
                     SpokenWord(range: NSRange(location: 5, length: 5), start: 0.5, end: 0.8)]
        let clip = SpokenClip(wav: SpeechTokens.wav(Array(repeating: Float(0.25), count: 24_000)), words: words, duration: 1)
        let trimmed = try XCTUnwrap(clip.starting(atSourceOffset: 5))
        XCTAssertEqual(trimmed.words.map(\.range), [words[1].range])
        XCTAssertEqual(trimmed.words[0].start, 0.025, accuracy: 1.0 / 24_000)
        XCTAssertEqual(trimmed.duration, 0.525, accuracy: 1.0 / 24_000)
        XCTAssertEqual(trimmed.wav.count, 44 + Int(trimmed.duration * 24_000) * 2)
        XCTAssertNil(try clip.starting(atSourceOffset: 10))
        XCTAssertEqual(try clip.starting(atSourceOffset: 0)?.wav, clip.wav)
    }
    func testUntimedVoiceResumeRetainsAudioInsteadOfSkippingThePassage() throws {
        let clip = SpokenClip(wav: SpeechTokens.wav(Array(repeating: Float(0.25), count: 24_000)),
            words: [], duration: 1, timingWarning: "Word timing is unavailable.")
        let resumed = try XCTUnwrap(clip.starting(atSourceOffset: 20))
        XCTAssertEqual(resumed.wav, clip.wav)
        XCTAssertTrue(resumed.words.isEmpty, "A fallback must not invent source-word timings.")
        XCTAssertEqual(resumed.timingWarning, clip.timingWarning)
    }
    @MainActor func testExactPagePlaybackSkipsEarlierWordsButKeepsTheirContext() async throws {
        guard await VoiceEngine().isInstalled() else { throw XCTSkip("Install Kitten for exact page playback checks.") }
        let player = PlaybackController()
        let original = player.voice, originalRate = player.rate
        defer { player.stop(); player.voice = original; player.rate = originalRate }
        player.voice = "kiki"
        let text = "Yesterday I read a story about a resourceful man. Today the story continues by the sea."
        let second = (text as NSString).range(of: "Today").location
        let offset = (text as NSString).range(of: "read").location
        let chapters = [ReadingChapter(id: "first", title: "Opening", offset: 0), ReadingChapter(id: "second", title: "Continuation", offset: second)]
        player.rate = 2
        player.open(Reading(title: "Context check", text: text, chapters: chapters)); player.seekToPage(offset)
        XCTAssertTrue(player.currentPassage.hasPrefix("Yesterday"))
        player.play()
        let deadline = Date().addingTimeInterval(15)
        var heard: [Int] = []
        while Date() < deadline, heard.count < 3 || player.index < 1 {
            try await Task.sleep(for: .milliseconds(50))
            if let word = player.highlighted, heard.last != word.location { heard.append(word.location) }
            if player.error != nil { break }
        }
        XCTAssertNil(player.error)
        XCTAssertGreaterThanOrEqual(heard.count, 3)
        XCTAssertTrue(heard.allSatisfy { $0 >= offset }, "Do not speak or highlight the preceding context again")
        XCTAssertGreaterThanOrEqual(player.position, second, "The exact starting anchor must clear when narration enters the next passage")
    }
    @MainActor func testCompletedBookShowsFullProgressAndStoppingDoesNotOverwriteIt() {
        let text = String(repeating: "This is a complete passage. ", count: 30)
        let player = PlaybackController()
        player.open(Reading(title: "Complete book", text: text, position: text.utf16.count))
        XCTAssertEqual(player.status, "Finished")
        XCTAssertEqual(player.progress, 1)
        XCTAssertEqual(player.position, text.utf16.count)
        var saved: [Int] = []
        player.onPosition = { _, offset in saved.append(offset) }
        player.stop()
        XCTAssertTrue(saved.isEmpty, "Stopping must not turn a completed book back into an unfinished last passage")
    }
    @MainActor func testAutoTurningDoesNotSeekAndPausingDoesNotRewindThePage() async throws {
        let text = String(repeating: "Listen to the story and follow the words across the page. ", count: 90)
        let controller = BookPagerController()
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 480)
        var browsed: [Int] = []
        let command = BookPageCommand()
        func configuration(_ word: NSRange?) -> PagedBookView {
            PagedBookView(text: text, sourceOffset: 0, position: 0, highlighted: word, follow: true,
                          title: "Book", pages: 1, gutter: 0, fold: 0, reduceMotion: true, command: command,
                          onBrowse: { browsed.append($0) }, onPageInfo: { _,_ in }, onBoundary: { _ in })
        }
        controller.update(configuration(nil)); controller.view.layoutIfNeeded()
        let range = try XCTUnwrap(controller.pagination).ranges[2]
        controller.update(configuration(NSRange(location: range.location + 1, length: 4)))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.currentPage, 2)
        XCTAssertTrue(browsed.isEmpty, "Narration-driven turns must not trigger a seek callback")
        controller.update(configuration(nil)) // Pause clears the highlight, not the remembered spoken word.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.currentPage, 2)
        controller.view.frame.size.width = 450
        controller.update(configuration(nil)); controller.view.layoutIfNeeded()
        let pages = try XCTUnwrap(controller.pagination)
        XCTAssertTrue(NSLocationInRange(range.location + 1, pages.ranges[controller.currentPage]))
        XCTAssertTrue(browsed.isEmpty)
    }
    @MainActor func testPagedHighlightsClearOldWordsAndResizeRetainsAnAnchor() async throws {
        let text = String(repeating: "Read these words, then turn the page. ", count: 140)
        let controller = BookPagerController()
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 850, height: 480)
        var browsed: [Int] = []
        func configuration(highlight: NSRange?, pages: Int = 2) -> PagedBookView {
            PagedBookView(text: text, sourceOffset: 1_000, position: 1_000, highlighted: highlight, follow: false,
                          title: "Book", pages: pages, gutter: 24, fold: 0.4, reduceMotion: true,
                          command: BookPageCommand(), onBrowse: { browsed.append($0) }, onPageInfo: { _,_ in }, onBoundary: { _ in })
        }
        controller.update(configuration(highlight: NSRange(location: 1_000, length: 4)))
        controller.view.layoutIfNeeded()
        func textViews(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        func highlightCount() -> Int {
            var count = 0
            for view in textViews(controller.view) {
                view.textStorage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: view.textStorage.length)) { value,_,_ in if value != nil { count += 1 } }
            }
            return count
        }
        XCTAssertEqual(highlightCount(), 1)
        controller.update(configuration(highlight: nil))
        XCTAssertEqual(highlightCount(), 0)
        controller.turn(1)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.currentPage, 2)
        XCTAssertEqual(browsed.count, 1)
        let anchor = try XCTUnwrap(controller.pagination).ranges[controller.currentPage].location
        controller.view.frame.size = CGSize(width: 390, height: 580)
        controller.update(configuration(highlight: nil, pages: 1)); controller.view.layoutIfNeeded()
        let pagination = try XCTUnwrap(controller.pagination)
        XCTAssertTrue(NSLocationInRange(anchor, pagination.ranges[controller.currentPage]))
        XCTAssertEqual(browsed.count, 1, "A resize must not seek or restart narration")
    }
    @MainActor func testPageCurlStaysCoherentWhenPhoneRotatesDuringATurn() {
        let finished = expectation(description: "Native phone rotations finish")
        Task { @MainActor in
            defer { finished.fulfill() }
            do { try await rotateBookThroughPageTurns() }
            catch { XCTFail("Rotation scenario failed: \(error)") }
        }
        wait(for: [finished], timeout: 30)
    }
    @MainActor private func rotateBookThroughPageTurns() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let previousDelegate = scene.delegate
        let delegate = RotationSceneDelegate()
        scene.delegate = delegate
        let host = RotationBookHost()
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        previous?.isHidden = true
        window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { scene.delegate = previousDelegate; window.isHidden = true; previous?.makeKeyAndVisible() }
        for orientation: UIInterfaceOrientationMask in [.landscapeRight, .portrait, .landscapeLeft, .portrait] {
            host.book.turn(1)
            try await Task.sleep(for: .milliseconds(50))
            var failure: Error?
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                host.setNeedsUpdateOfSupportedInterfaceOrientations()
                failure = nil
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { failure = $0 }
                try await Task.sleep(for: .milliseconds(300))
                let actual = scene.effectiveGeometry.interfaceOrientation
                if orientation.contains(UIInterfaceOrientationMask(rawValue: 1 << actual.rawValue)) { break }
            }
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertNil(failure)
            let actual = scene.effectiveGeometry.interfaceOrientation
            XCTAssertTrue(orientation.contains(UIInterfaceOrientationMask(rawValue: 1 << actual.rawValue)), "The scene must actually reach the requested orientation.")
            host.view.layoutIfNeeded()
            XCTAssertNotNil(host.book.pagination)
            XCTAssertNotNil(host.book.view.window)
            XCTAssertEqual(host.book.children.count, 1, "Rotation must leave exactly one live pager.")
            XCTAssertTrue(host.book.pagination!.ranges.indices.contains(host.book.currentPage))
        }
    }
    @MainActor func testIntermediateRotationSizesDoNotLoseTheSourceAnchor() throws {
        let text = String(repeating: "Keep the same reading place through every fold and rotation. ", count: 140)
        let offset = 950
        let controller = BookPagerController()
        controller.loadViewIfNeeded()
        let command = BookPageCommand()
        for size in [CGSize(width: 850, height: 480), CGSize(width: 1400, height: 1400),
                     CGSize(width: 850, height: 390), CGSize(width: 390, height: 580)] {
            controller.view.frame.size = size
            controller.update(PagedBookView(text: text, sourceOffset: 0, position: offset,
                highlighted: nil, follow: true, title: "Book", pages: size.width > 700 ? 2 : 1,
                gutter: 24, fold: 0, reduceMotion: true, command: command,
                onBrowse: { _ in XCTFail("Reflow must not seek") }, onPageInfo: { _,_ in }, onBoundary: { _ in }))
            controller.view.layoutIfNeeded()
            let pages = try XCTUnwrap(controller.pagination)
            let visible = pages.ranges[controller.currentPage..<min(pages.ranges.count, controller.currentPage + (size.width > 700 ? 2 : 1))]
            XCTAssertTrue(visible.contains { NSLocationInRange(offset, $0) })
        }
    }

}

@MainActor private final class RotationBookHost: UIViewController {
    let book = BookPagerController()
    private let command = BookPageCommand()
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    override func viewDidLoad() {
        super.viewDidLoad(); addChild(book); view.addSubview(book.view); book.didMove(toParent: self)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        book.view.frame = view.bounds
        let layout = BookLayout.resolve(size: view.bounds.size)
        book.update(PagedBookView(text: String(repeating: "Each page keeps its place as the reader turns and the phone rotates. ", count: 90),
            sourceOffset: 0, position: 1200, highlighted: nil, follow: true, title: "Rotation check",
            pages: layout.pages, gutter: layout.gutter, fold: 0, reduceMotion: false, command: command,
            onBrowse: { _ in }, onPageInfo: { _,_ in }, onBoundary: { _ in }))
    }
}

@MainActor private final class RotationSceneDelegate: NSObject, UIWindowSceneDelegate {
    func supportedInterfaceOrientations(for scene: UIWindowScene) -> UIInterfaceOrientationMask { .allButUpsideDown }
}
