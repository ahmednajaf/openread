import Foundation

@MainActor final class SafariPlaybackBridge {
    private weak var player: PlaybackController?
    private let store = SafariListeningSession()
    private var session: SafariListeningSession.Request?
    private var timer: Timer?
    private var previous: SafariListeningSession.State?
    init(player: PlaybackController) { self.player = player }
    deinit { timer?.invalidate() }
    func open(_ url: URL) throws -> Bool {
        guard url.scheme == "openread", url.host == "listen" else { return false }
        guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              let player else { throw ReadingError.invalidReading }
        let request = try store.request(id)
        finish()
        player.stop(); player.voice = request.voice; player.rate = request.rate
        player.open(try request.reading.validated)
        session = request; previous = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.update() } }
        player.play(); update()
        return true
    }
    private func finish() {
        if let session { try? store.write(.init(status: "ended", index: previous?.index ?? session.index, rate: previous?.rate ?? session.rate, word: nil, error: nil), id: session.id) }
        timer?.invalidate(); timer = nil; session = nil; previous = nil
    }
    private func update() {
        guard let session, let player else { finish(); return }
        guard player.reading?.id == "safari:" + session.id else { finish(); return }
        do {
            for command in try store.takeCommands(session.id) {
                switch command.action {
                case "play": player.play()
                case "pause": player.pause()
                case "stop": player.stop(); finish(); return
                case "rate": if let rate = command.rate, rate.isFinite, (0.5...2).contains(rate) { player.rate = rate }
                case "seek":
                    if let index = command.index, session.items.indices.contains(index) {
                        player.pause(); player.seekOffset(session.offsets[index]); if command.autoplay == true { player.play() }
                    }
                default: break
                }
            }
            let status = player.status == "Finished" ? "ended" : player.isPlaying ? "playing" : player.isPreparing ? "loading" : "paused"
            let position = player.highlighted?.location ?? player.position
            let index = session.offsets.lastIndex(where: { $0 <= position }) ?? 0
            let state = SafariListeningSession.State(status: status, index: index, rate: player.rate, word: player.highlighted.map(SafariListeningSession.Word.init), error: player.error, notice: player.timingWarning)
            if state != previous { try store.write(state, id: session.id); previous = state }
        } catch {
            player.pause()
            try? store.write(.init(status: "paused", index: previous?.index ?? session.index, rate: player.rate, word: nil, error: "Safari’s playback connection could not update. Reopen OpenRead to retry."), id: session.id)
            timer?.invalidate(); timer = nil
        }
    }
}
