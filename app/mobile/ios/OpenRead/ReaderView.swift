import SwiftUI
import UIKit

struct ReaderView: View {
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: LibraryStore
    @State private var settings = false
    @State private var options = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            if let reading = player.reading {
                VStack(spacing: 8) {
                    Text(reading.author?.uppercased() ?? "YOUR READING").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    Text(reading.title).font(.system(.title, design: .serif)).multilineTextAlignment(.center)
                    Text("\(reading.wordCount) words · about \(max(1, Int(Double(reading.wordCount) / (165 * Double(player.rate))))) min").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.top, 20)
                ReadingTextView(text: reading.text, highlighted: player.highlighted, follow: player.follow)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground)).navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                HStack {
                    Button { settings = true } label: { Label(player.voice.capitalized, systemImage: "waveform").font(.subheadline.weight(.medium)) }
                    Spacer()
                    Menu { ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in Button("\(speed.formatted())×") { player.rate = Float(speed) } } } label: { Text("\(player.rate.formatted())×").font(.subheadline.monospacedDigit()) }.accessibilityLabel("Reading speed")
                }
                HStack(spacing: 38) {
                    Button { player.previous() } label: { Image(systemName: "backward.end.fill") }.disabled(player.index == 0).accessibilityLabel("Previous passage")
                    Button {
                        if !player.installed { settings = true } else { player.toggle() }
                    } label: {
                        Group { if player.isPreparing { ProgressView() } else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") } }.font(.title2).frame(width: 62, height: 48)
                    }.buttonStyle(.borderedProminent).clipShape(Capsule()).accessibilityLabel(player.isPlaying || player.isPreparing ? "Pause reading" : "Listen to reading")
                    Button { player.next() } label: { Image(systemName: "forward.end.fill") }.disabled(!player.canNext).accessibilityLabel("Next passage")
                }
                Text(player.status + " · \(min(player.index + 1, player.passageCount)) of \(player.passageCount)").font(.caption2).foregroundStyle(.secondary)
            }.padding(20).readerGlass().padding(.horizontal, 18).padding(.bottom, 6)
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { options = true } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Reading options") } }
        .sheet(isPresented: $settings) { NativeSettingsView() }
        .sheet(isPresented: $options) { ReadingOptionsView() }
        .alert("OpenRead", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) { Button("OK") { player.error = nil } } message: { Text(player.error ?? "") }
    }
}

struct ReadingOptionsView: View {
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var exporting: Task<Void, Never>?
    @State private var exportStatus: String?
    @State private var exported: URL?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Save to library", systemImage: "bookmark") { guard var reading = player.reading else { return }; reading.position = player.position; do { try library.save(reading); dismiss() } catch { self.error = error.localizedDescription } }
                    Button("Bookmark this passage", systemImage: "bookmark.fill") {
                        guard var reading = player.reading else { return }
                        if !reading.bookmarks.contains(where: { $0.offset == player.position }) {
                            reading.bookmarks.append(.init(offset: player.position, label: String((reading.text as NSString).substring(from: player.position).prefix(80))))
                            reading.position = player.position
                            do { try library.save(reading); player.reading = reading } catch { self.error = error.localizedDescription }
                        }
                    }
                    Button("Export text", systemImage: "square.and.arrow.up") {
                        guard let reading = player.reading else { return }; let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenRead-reading.txt")
                        do { try reading.text.write(to: url, atomically: true, encoding: .utf8); exported = url } catch { self.error = error.localizedDescription }
                    }
                    if let exportStatus {
                        ProgressView(exportStatus)
                        Button("Cancel export", role: .cancel) { exporting?.cancel() }
                    } else {
                        Button("Export audio · WAV", systemImage: "waveform") {
                            exportStatus = "Preparing audio…"
                            exporting = Task {
                                do { exported = try await player.exportAudio { done, total in Task { @MainActor in exportStatus = "Exporting audio · \(done) of \(total)" } } }
                                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                                exportStatus = nil; exporting = nil
                            }
                        }.disabled(!player.installed)
                    }
                    Button("Stop reading", systemImage: "stop") { player.stop(); dismiss() }
                }
                Section {
                    Toggle("Highlight words", isOn: $player.highlight)
                    Toggle("Follow the spoken word", isOn: $player.follow)
                    Picker("Sleep timer", selection: Binding(get: { player.sleepMinutes }, set: player.setSleep)) {
                        Text("Off").tag(0); ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                }
                if let reading = player.reading, !reading.bookmarks.isEmpty {
                    Section("Bookmarks") {
                        ForEach(reading.bookmarks) { bookmark in Button(bookmark.label) { player.seekOffset(bookmark.offset); dismiss() } }
                        .onDelete { offsets in
                            var updated = reading; updated.bookmarks.remove(atOffsets: offsets)
                            do { try library.save(updated); player.reading = updated } catch { self.error = error.localizedDescription }
                        }
                    }
                }
                Text("Word timings are approximate. Appearance follows your device.").font(.footnote).foregroundStyle(.secondary)
            }.onDisappear { exporting?.cancel() }.navigationTitle("Reading options").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: Binding(get: { exported != nil }, set: { if !$0 { exported = nil } })) { if let exported { ShareFile(url: exported) } }
            .alert("OpenRead", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
        }
    }
}

struct NativeSettingsView: View {
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var backup: URL?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if player.downloading {
                        ProgressView(value: player.downloadProgress) { Text("Preparing natural voices…") }
                        Button("Cancel download", role: .cancel) { player.cancelDownload() }
                    } else if !player.installed {
                        Text("Download the eight Kitten Mini voices once. Speech then runs on this device, without a Mac or account.")
                        Button("Download voices · about 83 MB") { player.downloadVoices() }.buttonStyle(.borderedProminent)
                        Text("Uses your internet connection for the download. You may prefer Wi-Fi.").font(.footnote).foregroundStyle(.secondary)
                    } else { Label("Natural voices are ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                } header: { Text("On-device voices") }
                Section("Your voice") { ForEach(VoiceEngine.voices, id: \.self) { voice in
                    Button { player.voice = voice } label: { HStack { Text(voice.capitalized).foregroundStyle(.primary); Spacer(); if player.voice == voice { Image(systemName: "checkmark") } } }
                } }
                Section("Your library") {
                    Button("Export library backup", systemImage: "arrow.down.doc") { do { backup = try library.backup() } catch { self.error = error.localizedDescription } }
                    Text("Readings stay in this app. Export a backup before moving phones or removing OpenRead.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Yours to keep") {
                    Text("Free and open source. No subscriptions, analytics or cloud speech.")
                    NavigationLink("Licences & notices") { MobileNoticesView().navigationTitle("Licences").navigationBarTitleDisplayMode(.inline) }
                    Link("Source & contributions", destination: URL(string: "https://github.com/ahmednajaf/openread")!)
                    Link("Optional support", destination: URL(string: "https://ko-fi.com/pickledjones")!)
                    Text("GPL-3.0-or-later · © 2026 Ahmed Najaf and contributors. Kitten and ONNX Runtime keep their upstream licences. English voices; timing is approximate.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: Binding(get: { backup != nil }, set: { if !$0 { backup = nil } })) { if let backup { ShareFile(url: backup) } }
            .alert("OpenRead", isPresented: Binding(get: { error != nil || player.error != nil }, set: { if !$0 { error = nil; player.error = nil } })) { Button("OK") { error = nil; player.error = nil } } message: { Text(error ?? player.error ?? "") }
        }
    }
}

struct MobileNoticesView: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .footnote); view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 24, right: 20)
        view.text = Bundle.main.url(forResource: "NOTICES", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Licences are available in the OpenRead source repository."
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {}
}
