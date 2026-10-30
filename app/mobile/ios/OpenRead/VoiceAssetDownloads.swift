import Foundation
import CryptoKit

extension Notification.Name { static let voiceAssetInstalled = Notification.Name("OpenRead.voiceAssetInstalled") }

/// The OS owns the transfers, so dismissing Settings or leaving the app does not
/// discard a multi-gigabyte download. Only checksum-verified files are installed.
final class VoiceAssetDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = (Bundle.main.bundleIdentifier ?? "app.getopenread.reader") + ".voice-assets"
    static let shared = VoiceAssetDownloads()
    private final class Transfer: @unchecked Sendable {
        let asset: VoiceAsset
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        var task: URLSessionDownloadTask?
        var cancelled = false
        var completed = false
        init(asset: VoiceAsset, progress: @escaping @Sendable (Double) -> Void) { self.asset = asset; self.progress = progress }
    }
    private let root: URL
    private let assets: [String: VoiceAsset]
    private let lock = NSLock()
    private var observers: [Int: Transfer] = [:]
    private var completion: (() -> Void)?
    private var session: URLSession!

    init(root: URL = AppFiles.models, assets supplied: [VoiceAsset]? = nil, configuration: URLSessionConfiguration? = nil) {
        self.root = root
        let bundled = Bundle.main.url(forResource: "models", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(VoiceManifest.self, from: $0) }
        let all = supplied ?? ((bundled?.assets ?? []) + (bundled?.kokoroAssets ?? []) + (bundled?.kitten2Assets ?? []))
        assets = Dictionary(all.filter { !$0.name.isEmpty && $0.name == URL(fileURLWithPath: $0.name).lastPathComponent }.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        super.init()
        let config = configuration ?? URLSessionConfiguration.background(withIdentifier: Self.identifier)
        if configuration == nil {
            config.isDiscretionary = false; config.httpMaximumConnectionsPerHost = 2
            config.timeoutIntervalForResource = 7 * 24 * 60 * 60
            #if os(iOS)
            config.sessionSendsLaunchEvents = true; config.waitsForConnectivity = true
            #endif
            #if !OPENREAD_PERSONAL
            config.sharedContainerIdentifier = AppFiles.group
            #endif
        }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }
    func reconnect() { session.getAllTasks { _ in } }
    func handleBackgroundEvents(completion: @escaping () -> Void) {
        lock.withLock { self.completion = completion }; reconnect()
    }
    func download(_ asset: VoiceAsset, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard assets[asset.name]?.sha256 == asset.sha256, assets[asset.name]?.url == asset.url else { throw ReadingError.downloadFailed }
        let transfer = Transfer(asset: asset, progress: progress)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.getAllTasks { [self] tasks in
                    lock.lock()
                    if transfer.cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                    let existing = tasks.compactMap { $0 as? URLSessionDownloadTask }.first {
                        $0.taskDescription == asset.name && ($0.state == .running || $0.state == .suspended)
                    }
                    // A background transfer may finish between the caller's
                    // initial scan and reconnecting to the session.
                    if existing == nil, (try? VoiceAsset.digest(root.appendingPathComponent(asset.name))) == asset.sha256 {
                        transfer.completed = true
                        lock.unlock(); progress(1); continuation.resume(); return
                    }
                    if let existing, observers[existing.taskIdentifier] != nil {
                        lock.unlock(); continuation.resume(throwing: ReadingError.downloadFailed); return
                    }
                    let task: URLSessionDownloadTask
                    if let existing { task = existing }
                    else if let data = try? Data(contentsOf: resumeFile(asset)), !data.isEmpty {
                        task = session.downloadTask(withResumeData: data)
                        try? FileManager.default.removeItem(at: resumeFile(asset))
                    }
                    else { task = session.downloadTask(with: asset.url) }
                    task.taskDescription = asset.name
                    transfer.continuation = continuation; transfer.task = task
                    observers[task.taskIdentifier] = transfer
                    lock.unlock(); task.resume()
                }
            }
        } onCancel: { self.cancel(transfer) }
    }
    private func cancel(_ transfer: Transfer) {
        lock.lock()
        guard !transfer.completed else { lock.unlock(); return }
        transfer.cancelled = true; transfer.completed = true
        let task = transfer.task, continuation = transfer.continuation
        transfer.continuation = nil
        if let task { observers.removeValue(forKey: task.taskIdentifier) }
        lock.unlock()
        if let task {
            task.cancel { [self] data in
                if let data { saveResume(data, asset: transfer.asset) }
                // A retry is safe as soon as the awaiting task finishes, even
                // when the user immediately taps Download again.
                continuation?.resume(throwing: CancellationError())
            }
        } else { continuation?.resume(throwing: CancellationError()) }
    }
    private func finish(_ task: URLSessionTask, result: Result<Void, Error>) {
        lock.lock()
        let transfer = observers.removeValue(forKey: task.taskIdentifier)
        transfer?.completed = true
        let continuation = transfer?.continuation; transfer?.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
    private func resumeFile(_ asset: VoiceAsset) -> URL { root.appendingPathComponent(".downloads").appendingPathComponent(asset.name + "." + asset.sha256 + ".resume") }
    private func saveResume(_ data: Data, asset: VoiceAsset) {
        let file = resumeFile(asset)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let update = lock.withLock { observers[downloadTask.taskIdentifier]?.progress }
        if totalBytesExpectedToWrite > 0 { update?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = downloadTask.taskDescription, let asset = assets[name] else { finish(downloadTask, result: .failure(ReadingError.downloadFailed)); return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw ReadingError.downloadFailed }
            guard try VoiceAsset.digest(location) == asset.sha256 else { throw ReadingError.checksumFailed }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: location)
            } else { try FileManager.default.moveItem(at: location, to: destination) }
            #if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            #endif
            try? FileManager.default.removeItem(at: resumeFile(asset))
            finish(downloadTask, result: .success(()))
            DispatchQueue.main.async { NotificationCenter.default.post(name: .voiceAssetInstalled, object: nil) }
        } catch {
            try? FileManager.default.removeItem(at: resumeFile(asset))
            finish(downloadTask, result: .failure(error))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if let name = task.taskDescription, let asset = assets[name], let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { saveResume(data, asset: asset) }
        finish(task, result: .failure(error))
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { let value = completion; completion = nil; return value }
        if let handler { DispatchQueue.main.async(execute: handler) }
    }
    func invalidate() { session.invalidateAndCancel() }
}

/// One progress clock per pack, weighted by the real sizes of its assets.
final class VoiceAssetProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let weights: [Double]
    private var fractions: [Double]
    init(_ assets: [VoiceAsset]) { weights = assets.map { Double($0.bytes ?? 1) }; fractions = Array(repeating: 0, count: assets.count) }
    func update(_ index: Int, _ value: Double) -> Double {
        lock.withLock {
            fractions[index] = max(fractions[index], min(1, max(0, value)))
            return zip(weights, fractions).reduce(0) { $0 + $1.0 * $1.1 } / max(1, weights.reduce(0, +))
        }
    }
}
