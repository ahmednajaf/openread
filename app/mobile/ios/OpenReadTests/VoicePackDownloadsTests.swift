import XCTest
@testable import OpenRead

private actor DownloadGate {
    var starts: [String] = []
    var progress: [String: @Sendable (Double) -> Void] = [:]
    var continuations: [String: AsyncThrowingStream<Void, Error>.Continuation] = [:]
    func run(_ pack: String, update: @escaping @Sendable (Double) -> Void) async throws {
        let stream = AsyncThrowingStream<Void, Error> { continuations[pack] = $0 }
        starts.append(pack); progress[pack] = update
        for try await _ in stream { }
        try Task.checkCancellation()
    }
    func update(_ pack: String, _ value: Double) { progress[pack]?(value) }
    func finish(_ pack: String) { continuations[pack]?.finish() }
    func hasStarted(_ pack: String) -> Bool { starts.contains(pack) }
}

final class VoicePackDownloadsTests: XCTestCase {
    @MainActor func testAppOwnedQueueSerializesDownloadsAndKeepsProgress() async throws {
        let gate = DownloadGate(); let queue = VoicePackDownloads()
        let download: VoicePackDownloads.Download = { try await gate.run($0, update: $1) }
        queue.enqueue("kitten", download: download)
        queue.enqueue("kokoro", download: download)
        queue.enqueue("kitten", download: download) // repeated settings taps
        for _ in 0..<500 { if await gate.hasStarted("kitten") { break }; await Task.yield() }
        XCTAssertEqual(queue.active, "kitten"); XCTAssertEqual(queue.queued, ["kokoro"])
        await gate.update("kitten", 0.6)
        for _ in 0..<100 { if queue.progress == 0.6 { break }; await Task.yield() }
        XCTAssertEqual(queue.progress, 0.6)
        await gate.finish("kitten")
        for _ in 0..<500 { if await gate.hasStarted("kokoro") { break }; await Task.yield() }
        XCTAssertEqual(queue.active, "kokoro"); XCTAssertEqual(queue.revision, 1)
        await gate.update("kitten", 0.99) // late callback from previous pack
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(queue.progress, 0)
        await gate.finish("kokoro")
        for _ in 0..<500 { if !queue.isBusy { break }; await Task.yield() }
        XCTAssertFalse(queue.isBusy); XCTAssertEqual(queue.revision, 2)
    }
    @MainActor func testCancellationReleasesTheNextQueuedPack() async throws {
        let gate = DownloadGate(); let queue = VoicePackDownloads()
        let download: VoicePackDownloads.Download = { try await gate.run($0, update: $1) }
        queue.enqueue("kitten", download: download); queue.enqueue("kokoro", download: download)
        for _ in 0..<500 { if await gate.hasStarted("kitten") { break }; await Task.yield() }
        queue.cancelCurrent()
        for _ in 0..<500 { if await gate.hasStarted("kokoro") { break }; await Task.yield() }
        XCTAssertEqual(queue.active, "kokoro"); XCTAssertNil(queue.error); XCTAssertEqual(queue.revision, 0)
        await gate.finish("kokoro")
        for _ in 0..<500 { if !queue.isBusy { break }; await Task.yield() }
        XCTAssertEqual(queue.revision, 1)
    }
}
