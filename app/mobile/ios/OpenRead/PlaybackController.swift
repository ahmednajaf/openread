import Foundation
import Combine
import AVFoundation
import MediaPlayer

@MainActor final class PlaybackController: NSObject, ObservableObject {
    @Published var reading: Reading?
    @Published var index = 0
    @Published var status = "Ready"
    @Published var isPlaying = false
    @Published var isPreparing = false
    @Published var highlighted: NSRange?
    @Published var error: String?
    @Published var installed = false
    @Published var kittenInstalled = false
    @Published var kokoroInstalled = false

    @Published var downloadProgress = 0.0
    @Published var downloading = false
    @Published var voice: String = VoiceEngine.voices.contains(UserDefaults.standard.string(forKey: "voice") ?? "") ? UserDefaults.standard.string(forKey: "voice")! : "kiki" {
        didSet { UserDefaults.standard.set(voice, forKey: "voice"); restartForVoice(); Task { installed = await engine.isInstalled(voice: voice) } }
    }
    @Published var rate: Float = min(2, max(0.5, UserDefaults.standard.float(forKey: "rate") == 0 ? 1 : UserDefaults.standard.float(forKey: "rate"))) {
        didSet {
            let bounded: Float = rate.isFinite ? min(2, max(0.5, rate)) : 1
            // @Published re-enters this observer when assigned. Only correct an
            // out-of-range value; assigning every time overflows the stack.
            if bounded != rate { rate = bounded; return }
            UserDefaults.standard.set(rate, forKey: "rate"); streamAudio?.rate = rate; nowPlaying()
        }
    }
    @Published var follow = true
    @Published var highlight = true { didSet { if !highlight { highlighted = nil } } }
    @Published var sleepMinutes = 0
    let engine = VoiceEngine()
    let voiceDownloads = VoicePackDownloads()
    private var streamAudio: ContinuousSpeechPlayer?
    private var words: [SpokenWord] = []
    private var streamPassages: [(index: Int, start: Double)] = []
    private var passages: [ReadingPassage] = []
    private var textWindows: [NSRange] = []
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var tick: Timer?
    private var sleepDeadline: Date?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var downloadObserver: AnyCancellable?
    var onPosition: ((String, Int) -> Void)?

    override init() {
        super.init()
        voiceDownloads.$progress.assign(to: &$downloadProgress)
        voiceDownloads.$active.map { $0 != nil }.assign(to: &$downloading)
        voiceDownloads.$error.assign(to: &$error)
        downloadObserver = voiceDownloads.$revision.dropFirst().sink { [weak self] _ in
            Task { await self?.refreshVoices() }
        }
        Task {
            await refreshVoices()
            if installed {
                // Prepare the shared Safari cache in the full app, where model
                // compilation has enough memory. No network request is made.
                do { try await engine.prepare(voice: voice, download: false) { _ in } }
                catch { self.error = "Your downloaded voices could not be prepared. Try Download voices in Settings." }
            }
        }
        tick = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateClock() } }
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            if notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor in self?.pause() }
            }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in self?.pause() } }
        }
        #endif
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
    }
    var position: Int { passages.indices.contains(index) ? passages[index].range.location : 0 }
    var progress: Double { guard let reading, !reading.text.isEmpty else { return 0 }; return min(1, Double(position) / Double(reading.text.utf16.count)) }
    var passageCount: Int { passages.count }
    var currentPassage: String { passages.indices.contains(index) ? passages[index].text : "" }
    var activeChapter: Int { reading?.chapterList.lastIndex(where: { $0.offset <= position }) ?? 0 }
    var textWindow: NSRange { textWindows.last(where: { $0.location <= position }) ?? NSRange(location: 0, length: 0) }
    func seekTextWindow(_ delta: Int) {
        guard let index = textWindows.lastIndex(where: { $0.location <= position }), textWindows.indices.contains(index + delta) else { return }
        seekOffset(textWindows[index + delta].location)
    }
    var visibleText: String { guard let reading else { return "" }; return (reading.text as NSString).substring(with: textWindow) }
    var visibleHighlight: NSRange? { guard let highlighted, NSLocationInRange(highlighted.location, textWindow) else { return nil }; return NSRange(location: highlighted.location - textWindow.location, length: min(highlighted.length, NSMaxRange(textWindow) - highlighted.location)) }
    var canNext: Bool { index + 1 < passages.count }

    func open(_ reading: Reading) {
        stop(); var book = reading; book.cachedWordCount = reading.wordCount; book.cachedTextLength = reading.text.utf16.count; self.reading = book; passages = ReadingText.passages(reading); textWindows = ReadingText.windows(reading, passages: passages)
        index = passages.lastIndex(where: { $0.range.location <= reading.position }) ?? 0
        status = "Ready"; error = nil
    }
    func downloadVoices(voice selectedVoice: String = "kiki") {
        stop()
        let pack = VoiceEngine.isKokoro(selectedVoice) ? "kokoro" : "kitten"
        voiceDownloads.enqueue(pack) { [engine] pack, progress in
            try await engine.prepare(voice: pack == "kokoro" ? "af_heart" : "kiki", download: true, progress: progress)
        }
    }
    func cancelDownload() { voiceDownloads.cancelCurrent() }
    private func refreshVoices() async {
        kittenInstalled = await engine.isInstalled()
        kokoroInstalled = await engine.isInstalled(voice: "af_heart")
        installed = await engine.isInstalled(voice: voice)
    }
    func toggle() { if isPlaying || isPreparing { pause() } else { play() } }
    func play() {
        guard !isPlaying, !isPreparing, !passages.isEmpty, !downloading else { return }
        if let deadline = sleepDeadline, deadline <= Date() { sleepDeadline = nil; sleepMinutes = 0; return }
        if status == "Finished" { stop(); index = 0 }
        if let streamAudio {
            do { try configureAudio(); try streamAudio.resume() }
            catch { self.error = error.localizedDescription }
            return
        }
        generateAndPlay()
    }
    func pause() {
        if let streamAudio { streamAudio.pause() }
        else { generation = UUID(); task?.cancel() }
        isPreparing = false; isPlaying = false; highlighted = nil
        status = "Paused"; persistPosition(); nowPlaying()
    }
    func stop() {
        generation = UUID(); task?.cancel();
        streamAudio?.stop(); streamAudio = nil
        words = []; streamPassages = []; highlighted = nil
        isPlaying = false; isPreparing = false; status = "Ready"; persistPosition(); nowPlaying()
    }
    func next() { seek(min(passages.count - 1, index + 1)) }
    func previous() { seek(max(0, index - 1)) }
    func seekOffset(_ offset: Int) { seek(passages.lastIndex(where: { $0.range.location <= offset }) ?? 0) }
    func seek(_ target: Int) {
        guard passages.indices.contains(target) else { return }
        let resume = isPlaying || isPreparing; stop(); index = target; persistPosition()
        if resume { play() }
    }
    func setSleep(_ minutes: Int) { sleepMinutes = minutes; sleepDeadline = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil }

    func exportAudio(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> URL {
        guard let reading else { throw ReadingError.noText }
        // Audio is written a passage at a time; the WAV format remains bounded below.
        let selectedVoice = voice
        try await engine.prepare(voice: voice, download: false) { _ in }
        let parts = ReadingText.passages(reading)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenRead-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: Data(count: 44))
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                let clip = try await engine.generate(part.text, voice: selectedVoice)
                guard clip.wav.count > 44 else { throw ReadingError.noText }
                guard try handle.offset() - 44 + UInt64(clip.wav.count - 44) < UInt64(UInt32.max) - 36 else { throw ReadingError.fileTooLarge }
                try handle.write(contentsOf: clip.wav.dropFirst(44))
                progress(index + 1, parts.count)
            }
            let count = try handle.offset() - 44
            guard count < UInt32.max - 36 else { throw ReadingError.fileTooLarge }
            var header = Data("RIFF".utf8)
            func append<T: FixedWidthInteger>(_ value: T) { var number = value.littleEndian; withUnsafeBytes(of: &number) { header.append(contentsOf: $0) } }
            append(UInt32(36 + count)); header.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
            append(UInt32(24_000)); append(UInt32(48_000)); append(UInt16(2)); append(UInt16(16)); header.append(Data("data".utf8)); append(UInt32(count))
            try handle.seek(toOffset: 0); try handle.write(contentsOf: header); try handle.close(); return url
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: url); throw error }
    }
    private func restartForVoice() { let resume = isPlaying || isPreparing; stop(); if resume { play() } }
    private func configureAudio() throws {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
    private func generateAndPlay() {
        let token = UUID(); generation = token; error = nil; isPreparing = true; status = "Preparing on your device…"
        let chosenVoice = voice
        task = Task {
            do {
                try await engine.prepare(voice: chosenVoice, download: false) { _ in }
                guard token == generation, !Task.isCancelled else { return }
                try configureAudio()
                words = []; streamPassages = []
                let output = ContinuousSpeechPlayer()
                output.rate = rate
                output.onStateChange = { [weak self] playing in
                    guard let self, token == self.generation else { return }
                    self.isPlaying = playing
                    let paused = self.streamAudio?.isPaused == true
                    self.isPreparing = !playing && !paused
                    self.status = paused ? "Paused" : playing ? "Listening" : "Buffering audio…"
                    if !playing { self.highlighted = nil }
                    self.nowPlaying()
                }
                output.onFailure = { [weak self] error in
                    guard let self, token == self.generation else { return }
                    self.stop(); self.error = error.localizedDescription
                }
                output.onFinished = { [weak self] in
                    guard let self, token == self.generation else { return }
                    self.isPlaying = false; self.isPreparing = false; self.highlighted = nil
                    self.status = "Finished"; self.persistPosition(); self.nowPlaying()
                }
                streamAudio = output
                let first = index
                // One audio clock for every chunk and passage. Generation runs on
                // the voice actor while the player consumes its bounded queue.
                for next in first..<passages.count {
                    while output.bufferedSeconds > 20 * Double(rate) || output.isPaused {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        try Task.checkCancellation()
                    }
                    guard token == generation, !Task.isCancelled else { return }
                    let part = passages[next]
                    streamPassages.append((next, output.duration))
                    for try await chunk in await engine.stream(part.text, voice: chosenVoice) {
                        guard token == generation, !Task.isCancelled else { return }
                        appendWords(chunk.words, source: part.range.location, time: output.duration)
                        try output.append(chunk)
                    }
                }
                guard token == generation, !Task.isCancelled else { return }
                try output.finish()

            } catch { if token == generation, !Task.isCancelled { isPreparing = false; isPlaying = false; streamAudio?.stop(); streamAudio = nil; status = "Paused"; self.error = error.localizedDescription } }
        }
    }
    private func appendWords(_ timing: [SpokenWord], source: Int, time: Double) {
        for word in timing {
            let next = SpokenWord(range: NSRange(location: source + word.range.location, length: word.range.length),
                                  start: time + word.start, end: time + word.end)
            if let last = words.last, last.range == next.range {
                words[words.count - 1] = SpokenWord(range: last.range, start: last.start, end: next.end)
            } else { words.append(next) }
        }
    }
    private func updateClock() {
        if let deadline = sleepDeadline, deadline <= Date(), isPlaying || isPreparing { pause(); sleepDeadline = nil; sleepMinutes = 0; status = "Sleep timer finished" }
        guard isPlaying, passages.indices.contains(index) else { return }
        let time = streamAudio?.currentTime ?? 0
        if let marker = streamPassages.last(where: { $0.start <= time }), marker.index != index {
            index = marker.index; persistPosition(); nowPlaying()
        }
        // A book can be arbitrarily long; keep only the active/buffered window.
        words.removeAll { $0.end < time - 1 }
        if let current = streamPassages.lastIndex(where: { $0.start <= time }), current > 0 {
            streamPassages.removeFirst(current)
        }
        guard highlight else { highlighted = nil; return }
        if let word = words.last(where: { $0.start <= time && time < $0.end }) {
            highlighted = NSRange(location: word.range.location, length: word.range.length)
        } else { highlighted = nil }
    }

    private func persistPosition() { if let reading { onPosition?(reading.id, position) } }
    private func nowPlaying() {
        guard let reading else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: reading.title,
            MPMediaItemPropertyArtist: "OpenRead · \(voice.capitalized)", MPMediaItemPropertyPlaybackDuration: streamAudio?.duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: streamAudio?.currentTime ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0]
    }

}


/// A single PCM timeline across all queued passages. Buffer boundaries never recreate
/// the output device or time-stretch unit. All scheduling/state changes stay on MainActor.
@MainActor final class ContinuousSpeechPlayer {
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var pending = 0
    private var completedDuration = 0.0
    private var timelineBase = 0.0
    private var started = false
    private var finished = false
    private var stopped = false
    private var firstArrival: TimeInterval?
    private var firstDuration = 0.0
    private var bufferTarget = 3.0
    private var startDeadline: Task<Void, Never>?
    private let clock: () -> TimeInterval
    private(set) var isPaused = false
    private var generationID = UUID()
    private(set) var duration = 0.0
    private(set) var underruns = 0
    var isPlaying: Bool { started && !isPaused }
    var bufferedSeconds: Double { max(0, duration - currentTime) }
    var onStateChange: ((Bool) -> Void)?
    var onFinished: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var rate: Float = 1 {
        didSet {
            timePitch.rate = rate; timePitch.bypass = rate == 1
            bufferTarget = (underruns > 0 ? 3 : 1.5) * Double(rate)
            do { try startIfReady() } catch { onFailure?(error) }
        }
    }
    var currentTime: Double {
        guard started, let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) else { return completedDuration }
        return min(duration, timelineBase + Double(time.sampleTime) / time.sampleRate)
    }
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        engine.attach(player); engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        timePitch.bypass = true
    }
    func append(_ clip: SpokenClip) throws {
        guard !stopped, !finished else { return }
        let buffer = try Self.decode(clip.wav, format: format)
        let seconds = Double(buffer.frameLength) / format.sampleRate
        let now = clock()
        if firstArrival == nil {
            firstArrival = now; firstDuration = seconds
            startDeadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                guard let self, !self.stopped else { return }
                do { try self.startIfReady(deadlineReached: true) }
                catch { self.onFailure?(error) }
            }
        }
        duration += seconds; pending += 1
        let token = generationID
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.completed(seconds, token: token) }
        }
        // Adapt within a small bounded lead. Estimating the remaining passage
        // previously made a slow phone wait a minute before playing any audio.
        let elapsed = now - (firstArrival ?? now)
        let minimum = (underruns > 0 ? 3.0 : 1.5) * Double(rate)
        bufferTarget = minimum
        if !started, elapsed > 0.05, duration - completedDuration > firstDuration {
            let productionRate = (duration - completedDuration - firstDuration) / elapsed
            bufferTarget = min(3 * Double(rate), max(minimum, Double(rate) / max(0.01, productionRate)))
        }
        try startIfReady()
    }
    func finish() throws {
        guard !stopped else { return }
        finished = true
        if pending == 0 { if !isPaused { onFinished?() } }
        else { try startIfReady() }
    }
    private func startIfReady(deadlineReached: Bool = false) throws {
        guard !stopped, !started, !isPaused, pending > 0 else { return }
        let waited = clock() - (firstArrival ?? clock())
        guard finished || duration - completedDuration >= bufferTarget || deadlineReached || waited >= 4 else { return }
        startDeadline?.cancel(); startDeadline = nil
        if !engine.isRunning { try engine.start() }
        timelineBase = completedDuration
        player.play(); started = true; onStateChange?(true)
    }
    private func completed(_ seconds: Double, token: UUID) {
        guard !stopped, token == generationID else { return }
        completedDuration += seconds; pending -= 1
        guard pending == 0 else { return }
        player.stop(); started = false
        if finished { if !isPaused { onFinished?() } }
        else {
            underruns += 1; firstArrival = nil
            startDeadline?.cancel(); startDeadline = nil
            onStateChange?(false)
        }
    }
    func pause() {
        guard !stopped else { return }
        isPaused = true
        if started { player.pause() }
        onStateChange?(false)
    }
    func resume() throws {
        guard !stopped else { return }
        isPaused = false
        if finished, pending == 0 { onFinished?(); return }
        if started { if !engine.isRunning { try engine.start() }; player.play(); onStateChange?(true) }
        else { try startIfReady(); if !started { onStateChange?(false) } }
    }
    func stop() {
        stopped = true; generationID = UUID(); startDeadline?.cancel(); startDeadline = nil
        player.stop(); engine.stop()
        pending = 0; started = false; onStateChange = nil; onFinished = nil; onFailure = nil
    }
    static func decode(_ wav: Data, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let bytes = [UInt8](wav)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard bytes.count > 44, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<16], encoding: .ascii) == "WAVEfmt ", u32(16) == 16,
              u16(20) == 1, u16(22) == 1, u32(24) == 24_000, u16(34) == 16,
              String(bytes: bytes[36..<40], encoding: .ascii) == "data",
              u32(40) == bytes.count - 44, (bytes.count - 44).isMultiple(of: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount((bytes.count - 44) / 2)),
              let samples = buffer.floatChannelData?[0] else { throw ReadingError.noText }
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { samples[i] = Float(Int16(bitPattern: UInt16(u16(44 + i * 2)))) / 32768 }
        return buffer
    }
}
