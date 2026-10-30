import Foundation
import Combine

/// App-owned work: dismissing a settings sheet must not cancel a large transfer.
@MainActor final class VoicePackDownloads: ObservableObject {
    typealias Download = @Sendable (String, @escaping @Sendable (Double) -> Void) async throws -> Void
    @Published private(set) var active: String?
    @Published private(set) var progress = 0.0
    @Published private(set) var queued: [String] = []
    @Published private(set) var revision = 0
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var downloads: [String: Download] = [:]
    private var generation = UUID()
    var isBusy: Bool { active != nil || !queued.isEmpty }

    func enqueue(_ pack: String, download: @escaping Download) {
        guard ["kitten", "kokoro", "kitten2"].contains(pack), active != pack, !queued.contains(pack) else { return }
        downloads[pack] = download; error = nil; queued.append(pack); startNext()
    }
    func cancelCurrent() { task?.cancel() }
    func cancelAll() { queued.removeAll(); downloads.removeAll(); task?.cancel() }
    private func startNext() {
        guard active == nil, !queued.isEmpty else { return }
        let pack = queued.removeFirst()
        guard let download = downloads.removeValue(forKey: pack) else { return }
        active = pack; progress = 0
        let token = UUID(); generation = token
        task = Task {
            do {
                try await download(pack) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.active == pack else { return }
                        self.progress = max(self.progress, min(1, max(0, value.isFinite ? value : 0)))
                    }
                }
                try Task.checkCancellation(); revision += 1
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            guard generation == token else { return }
            active = nil; task = nil; startNext()
        }
    }
}
