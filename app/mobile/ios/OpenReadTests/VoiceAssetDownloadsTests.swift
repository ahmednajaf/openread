import XCTest
import Network
import CryptoKit
@testable import OpenRead

private final class AssetHTTPServer: @unchecked Sendable {
    let body: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "OpenRead.asset-download-test")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var offsets: [Int] = []
    let status: Int
    let slow: Bool
    var requestedOffsets: [Int] { lock.withLock { offsets } }
    init(body: Data, status: Int = 200, slow: Bool = false) throws {
        self.body = body; self.status = status; self.slow = slow
        listener = try NWListener(using: .tcp, on: .any)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var waiting = true
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    guard waiting, let port = listener.port else { return }; waiting = false
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/model.bin")!)
                case .failed(let error): if waiting { waiting = false; continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                lock.withLock { connections.append(connection) }
                connection.start(queue: queue); receive(connection, header: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, header: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            var header = header; if let data { header.append(data) }
            guard header.count <= 8192, error == nil else { connection.cancel(); return }
            guard let text = String(data: header, encoding: .utf8), text.contains("\r\n\r\n") else {
                if !complete { receive(connection, header: header) }; return
            }
            let range = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
            let offset = range.flatMap { Int($0.split(separator: "=").last?.split(separator: "-").first ?? "") } ?? 0
            lock.withLock { offsets.append(offset) }
            let start = min(body.count, max(0, offset)), count = body.count - start
            let code = status == 200 && start > 0 ? 206 : status
            var response = "HTTP/1.1 \(code) OK\r\nContent-Length: \(count)\r\nAccept-Ranges: bytes\r\nETag: \"openread-test-v1\"\r\nLast-Modified: Tue, 27 Oct 2026 00:00:00 GMT\r\nConnection: close\r\n"
            if code == 206 { response += "Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)\r\n" }
            response += "\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [self] error in
                guard error == nil else { connection.cancel(); return }
                send(connection, at: start)
            })
        }
    }
    private func send(_ connection: NWConnection, at offset: Int) {
        guard offset < body.count else { connection.cancel(); return }
        let end = min(body.count, offset + 32_768)
        connection.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { [self] error in
            guard error == nil else { connection.cancel(); return }
            if slow { queue.asyncAfter(deadline: .now() + 0.02) { [self] in send(connection, at: end) } }
            else { send(connection, at: end) }
        })
    }
    func stop() { listener.cancel(); lock.withLock { connections.forEach { $0.cancel() }; connections.removeAll() } }
}

final class VoiceAssetDownloadsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenRead-download-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func asset(url: URL, data: Data) -> VoiceAsset {
        VoiceAsset(name: "model.bin", url: url, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: Int64(data.count))
    }
    func testOnlyCompleteVerifiedDownloadsReplaceAnExistingModel() async throws {
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        let server = try AssetHTTPServer(body: body); let url = try await server.start(); defer { server.stop() }
        let expected = asset(url: url, data: body)
        let downloads = VoiceAssetDownloads(root: root, assets: [expected], configuration: .ephemeral); defer { downloads.invalidate() }
        let file = root.appendingPathComponent(expected.name)
        try Data("old model".utf8).write(to: file)
        try await downloads.download(expected) { _ in }
        XCTAssertEqual(try Data(contentsOf: file), body)
        let requests = server.requestedOffsets.count
        try await downloads.download(expected) { _ in }
        XCTAssertEqual(server.requestedOffsets.count, requests, "A completed background asset must not be downloaded again.")
    }
    func testChecksumFailureKeepsThePreviousModelUntouched() async throws {
        let server = try AssetHTTPServer(body: Data("corrupt payload".utf8)); let url = try await server.start(); defer { server.stop() }
        let expected = asset(url: url, data: Data("valid model".utf8))
        let downloads = VoiceAssetDownloads(root: root, assets: [expected], configuration: .ephemeral); defer { downloads.invalidate() }
        let file = root.appendingPathComponent(expected.name), previous = Data("previous valid model".utf8)
        try previous.write(to: file)
        do { try await downloads.download(expected) { _ in }; XCTFail("A corrupt transfer must fail its checksum.") }
        catch { XCTAssertTrue(error is ReadingError) }
        XCTAssertEqual(try Data(contentsOf: file), previous)
    }
    func testCancelledTransferDoesNotPublishAPartialModelAndCanResume() async throws {
        let body = Data((0..<2_000_000).map { UInt8($0 % 251) })
        let server = try AssetHTTPServer(body: body, slow: true); let url = try await server.start(); defer { server.stop() }
        let expected = asset(url: url, data: body)
        let downloads = VoiceAssetDownloads(root: root, assets: [expected], configuration: .ephemeral); defer { downloads.invalidate() }
        let (updates, continuation) = AsyncStream<Double>.makeStream()
        let work = Task { try await downloads.download(expected) { continuation.yield($0) } }
        for await value in updates { if value > 0.02 { break } }
        work.cancel()
        do { try await work.value; XCTFail("Cancellation must reach the awaiting app task.") } catch is CancellationError { }
        continuation.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(expected.name).path))
        // Retry immediately: cancellation must persist resume data before the
        // original awaiting task is released.
        try await downloads.download(expected) { _ in }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(expected.name)), body)
        XCTAssertTrue(server.requestedOffsets.contains { $0 > 0 }, "The second request should use the saved HTTP byte range.")
    }
}
