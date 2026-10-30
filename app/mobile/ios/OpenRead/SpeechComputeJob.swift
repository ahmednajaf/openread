#if os(iOS)
import BackgroundTasks
import UIKit

/// A finite, user-requested narration job. GPU use starts only after iOS grants
/// the continued-processing task; an audio session alone is not GPU permission.
@available(iOS 26, *)
@MainActor final class SpeechComputeJob {
    private static let prefix = (Bundle.main.bundleIdentifier ?? "app.getopenread.reader") + ".speech."
    private struct Request {
        let continuation: CheckedContinuation<SpeechComputeJob?, Never>
        let total: Int
        let expired: () -> Void
    }
    private static var registered = false
    private static var pending: [String: Request] = [:]
    private let task: BGContinuedProcessingTask
    private var finished = false
    private init(_ task: BGContinuedProcessingTask) { self.task = task }

    static func register() {
        guard !registered, BGTaskScheduler.supportedResources.contains(.gpu) else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: prefix + "*", using: .main) { task in
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
                        job.finish(success: false); request.expired()
                    }
                }
                request.continuation.resume(returning: job)
            }
        }
    }
    static func start(title: String, passages: Int, expired: @escaping () -> Void) async -> SpeechComputeJob? {
        guard BGTaskScheduler.supportedResources.contains(.gpu), UIApplication.shared.applicationState != .background else { return nil }
        register()
        guard registered else { return nil }
        let identifier = prefix + UUID().uuidString
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
                    } catch { cancel(identifier) }
                }
                // A rejected or delayed launch must not leave Play spinning.
                Task {
                    try? await Task.sleep(for: .seconds(5))
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
