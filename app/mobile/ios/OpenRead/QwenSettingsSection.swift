import SwiftUI
import UniformTypeIdentifiers

struct QwenSettingsSection: View {
    @EnvironmentObject private var player: PlaybackController
    var body: some View { QwenSettingsContent(downloads: player.voiceDownloads) }
}

private struct QwenSettingsContent: View {
    @EnvironmentObject private var player: PlaybackController
    @ObservedObject var downloads: VoicePackDownloads
    @State private var busy: String?
    @State private var progress = 0.0
    @State private var operation: Task<Void, Never>?
    @State private var expressive = QwenFiles.installed("expressive")
    @State private var cloning = QwenFiles.installed("clone")
    @State private var profiles = QwenFiles.profiles
    @State private var importing = false
    @State private var sample: URL?
    @State private var name = ""
    @State private var transcript = ""
    @State private var permission = false
    var body: some View {
        Group {
        Section("Qwen · optional voice packs") {
            Text("Richer narration, generated on this device. These larger packs use more storage, memory and battery. Kitten stays available for quick reading.").font(.footnote).foregroundStyle(.secondary)
            if let busy {
                ProgressView(busy, value: progress)
                Button("Cancel", role: .cancel) { operation?.cancel() }
            }
            if let pack = downloads.active {
                ProgressView("Downloading " + (pack == "clone" ? "voice cloning…" : "expressive voices…"), value: downloads.progress)
                Button("Cancel current download", role: .cancel) { downloads.cancelCurrent() }
                Text("You can close Settings while this downloads.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(downloads.queued, id: \.self) { pack in Text("Queued: " + (pack == "clone" ? "Voice cloning" : "Expressive voices")).font(.caption).foregroundStyle(.secondary) }
            if let error = downloads.error { Text(error).font(.footnote).foregroundStyle(.red) }
            if !expressive { Button("Download expressive voices · up to 1.44 GB") { download("expressive") }.disabled(downloads.active == "expressive" || downloads.queued.contains("expressive")) }
            if !cloning { Button("Download voice cloning · up to 884 MB") { download("clone") }.disabled(downloads.active == "clone" || downloads.queued.contains("clone")) }
            if expressive {
                ForEach(QwenFiles.speakers, id: \.self) { speaker in
                    Button { player.voice = "qwen:" + speaker } label: { HStack { Text(speaker.replacingOccurrences(of: "_", with: " ").capitalized); Spacer(); if player.voice == "qwen:" + speaker { Image(systemName: "checkmark") } } }
                }
                TextField("Voice direction, e.g. warm, unhurried storytelling", text: $player.direction, axis: .vertical)
                    .onChange(of: player.direction) { _, text in if text.count > 500 { player.direction = String(text.prefix(500)) } }
                Text("Direction applies to Qwen's expressive voices. Word highlighting is estimated.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if cloning {
            Section("Your voices") {
                ForEach(profiles) { profile in
                    HStack {
                        Button { player.voice = "qwen:clone:" + profile.id } label: { Label(profile.name, systemImage: player.voice == "qwen:clone:" + profile.id ? "checkmark.circle.fill" : "person.wave.2") }
                        Spacer()
                        Button(role: .destructive) { operation = Task { do { player.stop(); try await player.engine.qwen.removeProfile(profile.id); if player.voice == "qwen:clone:" + profile.id { player.voice = "kiki" }; profiles = QwenFiles.profiles } catch { player.error = error.localizedDescription } } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete " + profile.name)
                    }
                }
                TextField("Name your voice", text: $name).onChange(of: name) { _, value in name = String(value.prefix(80)) }
                Button(sample == nil ? "Choose a 3–30 second audio sample" : "Sample: " + sample!.lastPathComponent) { importing = true }
                TextField("Optional transcript · closer delivery, slower", text: $transcript, axis: .vertical).lineLimit(3...6)
                    .onChange(of: transcript) { _, value in transcript = String(value.prefix(2000)) }
                Toggle("This is my voice, or I have permission to clone it", isOn: $permission)
                Text("A clear sample without music works best. Leave the transcript blank for faster reading. Add the exact words for closer reference delivery, which takes longer to prepare. The sample and voice profile stay on this device; the original sample is discarded after preparation.").font(.caption).foregroundStyle(.secondary)
                Button("Create personal voice") { createVoice() }.disabled(busy != nil || downloads.isBusy || sample == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !permission)
            }
        }
        }.fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result { case .success(let url): sample = url; case .failure(let error): player.error = error.localizedDescription }
        }
        .onAppear { refreshPacks() }
        .onChange(of: downloads.revision) { _, _ in refreshPacks() }
        .onDisappear { operation?.cancel() }
    }
    private func refreshPacks() {
        expressive = QwenFiles.installed("expressive"); cloning = QwenFiles.installed("clone")
        Task { player.installed = await player.engine.isInstalled(voice: player.voice) }
    }
    private func download(_ pack: String) {
        let engine = player.engine.qwen
        downloads.enqueue(pack) { pack, progress in try await engine.download(pack, progress: progress) }
    }
    private func createVoice() {
        guard let sample else { return }; player.stop(); busy = "Preparing your voice…"; progress = 0
        operation = Task {
            do { let profile = try await player.engine.qwen.clone(name: name, transcript: transcript, sample: sample, permission: permission); try Task.checkCancellation(); profiles = QwenFiles.profiles; player.voice = "qwen:clone:" + profile.id; name = ""; transcript = ""; self.sample = nil; permission = false }
            catch { if !Task.isCancelled { player.error = error.localizedDescription } }
            busy = nil; operation = nil
        }
    }
}
