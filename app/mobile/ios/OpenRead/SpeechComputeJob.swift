#if os(iOS)
import BackgroundTasks
import UIKit
import OSLog

/// A finite, user-requested lease for background GPU work. Foreground GPU
/// access does not depend on this lease; inactive work otherwise uses CPU.
@available(iOS 26, *)
@MainActor final class SpeechComputeJob {
    private static let prefix = (Bundle.main.bundleIdentifier ?? "app.getopenread.reader") + ".speech."
    private struct Request {
        let continuation: CheckedContinuation<SpeechComputeJob?, Never>
        let total: Int
        let expired: () -> Void
    }
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenRead", category: "NarrationGPU")
    private static var pending: [String: Request] = [:]
    private let task: BGContinuedProcessingTask
    private var finished = false
    private init(_ task: BGContinuedProcessingTask) { self.task = task }

    private static func register(_ identifier: String) -> Bool {
        // The plist allows the wildcard family; the launch handler must match
        // the exact identifier submitted for this user-started job.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            Task { @MainActor in
                guard let task = task as? BGContinuedProcessingTask,
                      let request = pending.removeValue(forKey: task.identifier) else {
                    task.setTaskCompleted(success: false); return
                }
                let job = SpeechComputeJob(task)
                task.progress.totalUnitCount = Int64(max(1, request.total))
                task.expirationHandler = { [weak job] in
                    Task { @MainActor in
                        guard let job, !job.finished else { return }
                        request.expired(); job.finish(success: false)
                    }
                }
                request.continuation.resume(returning: job)
            }
        }
    }
    static func start(title: String, passages: Int, expired: @escaping () -> Void) async -> SpeechComputeJob? {
        guard BGTaskScheduler.supportedResources.contains(.gpu), UIApplication.shared.applicationState != .background else { return nil }
        guard !Task.isCancelled else { return nil }
        let identifier = prefix + UUID().uuidString
        guard register(identifier) else {
            log.error("Could not register the narration GPU launch handler")
            return nil
        }
        return await withTaskCancellationHandler {
            if Task.isCancelled { return nil }
            return await withCheckedContinuation { continuation in
                pending[identifier] = Request(continuation: continuation, total: passages, expired: expired)
                let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Preparing narration", subtitle: String(title.prefix(120)))
                request.strategy = .fail; request.requiredResources = .gpu
                Task {
                    do {
                        try await Task.detached {
                            if #available(iOS 27, *) { try await BGTaskScheduler.shared.submitTaskRequest(request) }
                            else { try BGTaskScheduler.shared.submit(request) }
                        }.value
                    } catch {
                        let failure = error as NSError
                        log.error("Narration GPU request rejected: \(failure.domain, privacy: .public) \(failure.code)")
                        cancel(identifier)
                    }
                }
                // A rejected or delayed launch must not leave Play spinning.
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    if pending[identifier] != nil { log.error("Narration GPU launch timed out") }
                    cancel(identifier)
                }
            }
        } onCancel: { Task { @MainActor in cancel(identifier) } }
    }
    private static func cancel(_ identifier: String) {
        guard let request = pending.removeValue(forKey: identifier) else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        request.continuation.resume(returning: nil)
    }
    func completedPassages(_ count: Int) {
        guard !finished else { return }
        task.progress.completedUnitCount = min(task.progress.totalUnitCount, Int64(max(0, count)))
    }
    func finish(success: Bool) {
        guard !finished else { return }; finished = true
        task.expirationHandler = nil
        if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
        task.setTaskCompleted(success: success)
    }
}
#endif
