import Foundation
import Combine
import AVFoundation
import MediaPlayer

@MainActor final class PlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var reading: Reading?
    @Published var index = 0
    @Published var status = "Ready"
    @Published var isPlaying = false
    @Published var isPreparing = false
    @Published var highlighted: NSRange?
    @Published var error: String?
    @Published var installed = false
    @Published var kittenInstalled = false
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
            UserDefaults.standard.set(rate, forKey: "rate"); audio?.rate = rate; streamAudio?.rate = rate; nowPlaying()
        }
    }
    @Published var follow = true
    @Published var highlight = true { didSet { if !highlight { highlighted = nil } } }
    @Published var sleepMinutes = 0
    let engine = VoiceEngine()
    let voiceDownloads = VoicePackDownloads()
    @Published var direction = UserDefaults.standard.string(forKey: "voice-direction") ?? "" { didSet { UserDefaults.standard.set(direction, forKey: "voice-direction") } }
    private var audio: AVAudioPlayer?
    private var streamAudio: ContinuousSpeechPlayer?
    private var streaming = false
    private var words: [SpokenWord] = []
    private var passages: [ReadingPassage] = []
    private var textWindows: [NSRange] = []
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var tick: Timer?
    private var sleepDeadline: Date?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    var onPosition: ((String, Int) -> Void)?

    override init() {
        super.init()
        Task {
            kittenInstalled = await engine.isInstalled()
            installed = await engine.isInstalled(voice: voice)
            if kittenInstalled {
                // Prepare the shared Safari cache in the full app, where model
                // compilation has enough memory. No network request is made.
                do { try await engine.prepare(download: false) { _ in } }
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
    func downloadVoices() {
        guard !downloading else { return }
        downloading = true; downloadProgress = 0; error = nil
        task = Task {
            do { try await engine.prepare(download: true) { value in Task { @MainActor in self.downloadProgress = value } }; kittenInstalled = true; installed = await engine.isInstalled(voice: voice) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            downloading = false
        }
    }
    func cancelDownload() { task?.cancel(); downloading = false }
    func toggle() { if isPlaying || isPreparing { pause() } else { play() } }
    func play() {
        guard !isPlaying, !isPreparing, !passages.isEmpty, !downloading else { return }
        if let deadline = sleepDeadline, deadline <= Date() { sleepDeadline = nil; sleepMinutes = 0; return }
        if streaming, let streamAudio {
            do { try configureAudio(); try streamAudio.resume() }
            catch { self.error = error.localizedDescription }
            return
        }
        if let audio, audio.currentTime < audio.duration - 0.01 {
            do { try configureAudio(); audio.rate = rate; audio.play(); isPlaying = true; status = "Listening"; nowPlaying() } catch { self.error = error.localizedDescription }
        } else { generateAndPlay() }
    }
    func pause() {
        if streaming, let streamAudio { streamAudio.pause() }
        else { generation = UUID(); task?.cancel(); prefetch?.cancel(); prefetch = nil; audio?.pause() }
        isPreparing = false; isPlaying = false; highlighted = nil
        status = "Paused"; persistPosition(); nowPlaying()
    }
    func stop() {
        generation = UUID(); task?.cancel(); prefetch?.cancel(); prefetch = nil
        streamAudio?.stop(); streamAudio = nil; streaming = false
        audio?.stop(); audio = nil; words = []; highlighted = nil
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
        let passage = passages[index]; let chosenVoice = voice
        task = Task {
            do {
                try await engine.prepare(voice: chosenVoice, download: false) { _ in }
                guard token == generation, !Task.isCancelled else { return }
                #if OPENREAD_QWEN
                if chosenVoice.hasPrefix("qwen:") {
                    try configureAudio()
                    streaming = true; words = []
                    let output = ContinuousSpeechPlayer(estimatedDuration: Double(ReadingText.words(in: passage.text).count) / 2.4)
                    output.rate = rate
                    output.onStateChange = { [weak self] playing in
                        guard let self, token == self.generation else { return }
                        self.isPlaying = playing
                        let paused = self.streamAudio?.isPaused == true
                        self.isPreparing = !playing && !paused
                        self.status = paused ? "Paused" : playing ? "Listening · Qwen timing is approximate" : "Buffering Qwen audio on this device…"
                        if !playing { self.highlighted = nil }
                        self.nowPlaying()
                    }
                    output.onFinished = { [weak self] in
                        guard let self, token == self.generation else { return }
                        self.finishPassage()
                    }
                    streamAudio = output
                    for try await chunk in engine.qwen.stream(passage.text, voice: chosenVoice, instruction: direction) {
                        guard token == generation, !Task.isCancelled else { return }
                        let offset = output.duration
                        words.append(contentsOf: chunk.words.map { SpokenWord(range: $0.range, start: $0.start + offset, end: $0.end + offset) })
                        try output.append(chunk)
                    }
                    guard token == generation, !Task.isCancelled else { return }
                    try output.finish()
                    if canNext {
                        let next = passages[index + 1].text
                        let instruction = direction
                        prefetch = Task { _ = try? await engine.generate(next, voice: chosenVoice, instruction: instruction) }
                    }
                    return
                }
                #endif
                let clip = try await engine.generate(passage.text, voice: chosenVoice, instruction: direction)
                guard token == generation, !Task.isCancelled else { return }
                try configureAudio()
                let player = try AVAudioPlayer(data: clip.wav)
                player.delegate = self; player.enableRate = true; player.rate = rate
                audio = player; words = clip.words; isPreparing = false
                guard player.play() else { throw ReadingError.noText }
                isPlaying = true; status = "Listening"; nowPlaying(); persistPosition()
                if canNext {
                    let next = passages[index + 1].text
                    prefetch = Task { _ = try? await engine.generate(next, voice: chosenVoice, instruction: direction) }
                }
            } catch { if token == generation, !Task.isCancelled { isPreparing = false; isPlaying = false; streaming = false; streamAudio?.stop(); streamAudio = nil; audio?.stop(); audio = nil; status = "Paused"; self.error = error.localizedDescription } }
        }
    }
    private func finishPassage() {
        streaming = false; streamAudio?.stop(); streamAudio = nil; audio = nil; highlighted = nil; isPlaying = false
        if canNext { index += 1; generateAndPlay() }
        else { isPreparing = false; status = "Finished"; index = 0; persistPosition(); nowPlaying() }
    }
    private func updateClock() {
        if let deadline = sleepDeadline, deadline <= Date(), isPlaying || isPreparing { pause(); sleepDeadline = nil; sleepMinutes = 0; status = "Sleep timer finished" }
        guard isPlaying, highlight, passages.indices.contains(index) else { return }
        let time = streamAudio?.currentTime ?? audio?.currentTime ?? 0
        if let word = words.last(where: { $0.start <= time && time < $0.end }) {
            highlighted = NSRange(location: passages[index].range.location + word.range.location, length: word.range.length)
        } else { highlighted = nil }
    }
    private func persistPosition() { if let reading { onPosition?(reading.id, position) } }
    private func nowPlaying() {
        guard let reading else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: reading.title,
            MPMediaItemPropertyArtist: "OpenRead · \(voice.capitalized)", MPMediaItemPropertyPlaybackDuration: streamAudio?.duration ?? audio?.duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: streamAudio?.currentTime ?? audio?.currentTime ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0]
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.audio === player else { return }
            self.audio = nil; self.highlighted = nil; self.isPlaying = false
            if flag { self.finishPassage() }
            else { self.stop(); self.status = "Paused"; self.persistPosition(); self.nowPlaying() }
        }
    }
}


/// A single PCM timeline for an entire passage. Buffer boundaries never recreate
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
    private var waitForCompletion = false
    private var firstArrival: TimeInterval?
    private var firstDuration = 0.0
    private var bufferTarget = 3.0
    private let estimatedDuration: Double
    private let clock: () -> TimeInterval
    private(set) var isPaused = false
    private var generationID = UUID()
    private(set) var duration = 0.0
    private(set) var underruns = 0
    var isPlaying: Bool { started && !isPaused }
    var onStateChange: ((Bool) -> Void)?
    var onFinished: (() -> Void)?
    var rate: Float = 1 { didSet { timePitch.rate = rate; timePitch.bypass = rate == 1 } }
    var currentTime: Double {
        guard started, let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) else { return completedDuration }
        return min(duration, timelineBase + Double(time.sampleTime) / time.sampleRate)
    }
    init(estimatedDuration: Double = 0, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.estimatedDuration = estimatedDuration; self.clock = clock
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
        if firstArrival == nil { firstArrival = now; firstDuration = seconds }
        duration += seconds; pending += 1
        let token = generationID
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.completed(seconds, token: token) }
        }
        // Estimate how much lead the producer needs at this listening speed.
        // This is per bounded passage, not the whole chapter/book. Excluding the
        // first chunk avoids treating model startup as sustained synthesis cost.
        let elapsed = now - (firstArrival ?? now)
        if !started, elapsed > 0.05, duration > firstDuration {
            let productionRate = (duration - firstDuration) / elapsed
            let remaining = max(0, estimatedDuration - duration)
            bufferTarget = max(3 * Double(rate), remaining * max(0, Double(rate) / productionRate - 1) + Double(rate))
        }
        try startIfReady()
    }
    func finish() throws {
        guard !stopped else { return }
        finished = true
        if pending == 0 { if !isPaused { onFinished?() } }
        else { try startIfReady() }
    }
    private func startIfReady() throws {
        guard !started, !isPaused, pending > 0, finished || (!waitForCompletion && duration - completedDuration >= max(bufferTarget, 3 * Double(rate))) else { return }
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
            // Once this device underruns, buffer the rest of the passage. Repeated
            // one-second starts are worse than a single honest buffering interval.
            underruns += 1; waitForCompletion = true; onStateChange?(false)
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
        stopped = true; generationID = UUID(); player.stop(); engine.stop()
        pending = 0; started = false; onStateChange = nil; onFinished = nil
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
