import SwiftUI
import UIKit

struct ReaderView: View {
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reader-paged") private var paged = true
    @State private var aiPassage: AppleReadingPassage?
    @State private var chaptersOpen = false
    @State private var settings = false
    @State private var options = false
    @State private var hingeFold = 0.0
    @State private var browsing: Int?
    @State private var currentPage = 0
    @State private var pageCount = 1
    @State private var command = BookPageCommand()

    var body: some View {
        Group {
            if #available(iOS 27.1, *) {
                canvas.onHingeChange { _, context in
                    let degrees = context.hinge?.angle.degrees ?? 180
                    // Effects only. Layout uses the actual reserved region below.
                    hingeFold = reduceMotion ? 0 : min(1, max(0, (180 - degrees) / 110))
                }
            } else { canvas }
        }
        .background(ReadingBackdrop()).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 3) {
                    Text(player.reading?.title ?? "OpenRead").font(.system(.subheadline, design: .serif)).lineLimit(1)
                    if let author = player.reading?.author { Text(author).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                }.accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Contents", systemImage: "list.bullet") { chaptersOpen = true }
                        .disabled(player.reading?.chapterList.isEmpty != false)
                    Button("Ask about this passage", systemImage: "sparkles") { aiPassage = AppleReadingPassage(text: player.currentPassage) }
                    Button("Reading options", systemImage: "slider.horizontal.3") { options = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Reading menu")
            }
        }
        .onChange(of: player.reading?.id) { _, _ in browsing = nil }
        .onChange(of: player.textWindow.location) { _, _ in browsing = nil }
        .sheet(item: $aiPassage) { AppleReadingToolsSheet(passage: $0.text) }
        .sheet(isPresented: $settings) { NativeSettingsView() }
        .sheet(isPresented: $options) { ReadingOptionsView() }
        .sheet(isPresented: $chaptersOpen) {
            NavigationStack {
                List(Array((player.reading?.chapterList ?? []).enumerated()), id: \.element.id) { index, chapter in
                    Button { browsing = nil; player.seekOffset(chapter.offset); chaptersOpen = false } label: {
                        HStack { Text(chapter.title); Spacer(); if index == player.activeChapter { Image(systemName: "checkmark") } }
                    }
                }.navigationTitle("Contents").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { chaptersOpen = false } }
            }
        }
        .alert("OpenRead", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("OK") { player.error = nil }
        } message: { Text(player.error ?? "") }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let layout = layout(in: geometry)
            ZStack(alignment: .topLeading) {
                book(pages: layout.pages, gutter: layout.gutter)
                    .frame(width: layout.book.width, height: layout.book.height)
                    .position(x: layout.book.midX, y: layout.book.midY)
                playbackDock(tabletop: layout.kind == .tabletop)
                    .frame(width: layout.controls.width, height: layout.controls.height)
                    .position(x: layout.controls.midX, y: layout.controls.midY)
            }
        }
    }
    private func layout(in geometry: GeometryProxy) -> BookLayout {
        if #available(iOS 27.1, *) {
            let division = geometry.reservedRegions(kind: .division, options: .includeInactive).first {
                $0.frame.midX > 0 && $0.frame.midX < geometry.size.width && $0.frame.midY > 0 && $0.frame.midY < geometry.size.height
            }
            let reserved = division.map { region in
                region.isActive ? region.frame.insetBy(dx: -max(region.margins.leading, region.margins.trailing),
                                                       dy: -max(region.margins.top, region.margins.bottom)) : region.frame
            }
            return BookLayout.resolve(size: geometry.size, division: reserved, active: division?.isActive == true)
        }
        return BookLayout.resolve(size: geometry.size)
    }
    private func book(pages: Int, gutter: CGFloat) -> some View {
        VStack(spacing: 8) {
            Group {
                if paged {
                    PagedBookView(text: player.visibleText, sourceOffset: player.textWindow.location,
                                  position: player.position, highlighted: player.highlighted,
                                  follow: player.follow && browsing == nil, title: player.reading?.title ?? "",
                                  pages: pages, gutter: gutter, fold: hingeFold, reduceMotion: reduceMotion,
                                  command: command, onBrowse: didBrowse,
                                  onPageInfo: { currentPage = $0; pageCount = $1 }, onBoundary: changeSection)
                } else {
                    GeometryReader { geometry in
                        ReadingTextView(text: player.visibleText, highlighted: player.visibleHighlight, follow: player.follow)
                            .frame(width: pages == 2 ? (geometry.size.width - gutter) / 2 : geometry.size.width)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: pages == 2 ? 18 : 22))
            .overlay { RoundedRectangle(cornerRadius: pages == 2 ? 18 : 22).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.05 + hingeFold * 0.03), radius: 15, y: 7)
            HStack(spacing: 12) {
                Button { if paged { command = BookPageCommand(delta: -1) } else { changeSection(-1) } } label: {
                    Image(systemName: "chevron.backward").frame(width: 44, height: 44)
                }.disabled(currentPage == 0 && player.textWindow.location == 0).accessibilityLabel("Previous page")
                Spacer(minLength: 0)
                if let browsing, player.isPlaying || player.isPreparing {
                    Menu {
                        Button("Return to spoken word", systemImage: "waveform") { self.browsing = nil }
                        Button("Listen from this page", systemImage: "play") { player.seekToPage(browsing); self.browsing = nil; if !player.isPlaying { player.play() } }
                    } label: { Label("Browsing pages", systemImage: "book") }.font(.caption)
                } else {
                    Text(paged ? pageLabel(pages: pages) : "Read at your own pace")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { if paged { command = BookPageCommand(delta: 1) } else { changeSection(1) } } label: {
                    Image(systemName: "chevron.forward").frame(width: 44, height: 44)
                }.disabled(currentPage + pages >= pageCount && NSMaxRange(player.textWindow) >= (player.reading?.textLength ?? 0))
                    .accessibilityLabel("Next page")
            }.buttonStyle(.plain).foregroundStyle(ReaderStyle.accent)
        }
    }
    private func pageLabel(pages: Int) -> String {
        let range = pages == 2 && currentPage + 1 < pageCount ? "\(currentPage + 1)–\(min(currentPage + pages, pageCount))" : "\(currentPage + 1)"
        return "\(range) / \(pageCount)" + ((player.reading?.textLength ?? 0) > 64_000 ? " · this section" : "")
    }
    private func didBrowse(_ offset: Int) {
        if player.isPlaying || player.isPreparing { browsing = offset }
        else { player.seekToPage(offset); browsing = nil }
    }
    private func changeSection(_ direction: Int) { browsing = nil; player.seekTextWindow(direction > 0 ? 1 : -1) }

    private func playbackDock(tabletop: Bool) -> some View {
        VStack(spacing: tabletop ? 22 : 0) {
            if tabletop {
                VStack(spacing: 8) {
                    Image(systemName: "headphones").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(ReaderStyle.accent)
                    Text("A little space to listen.").font(.system(.title3, design: .serif))
                }.accessibilityHidden(true)
            }
            VStack(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { voiceButton; Spacer(minLength: 0); transport; speedButton }
                    HStack(spacing: 10) { voiceButton.labelStyle(.iconOnly); Spacer(minLength: 0); transport; Spacer(minLength: 0); speedButton }
                }
                ProgressView(value: player.progress).tint(ReaderStyle.accent).accessibilityLabel("Reading progress")
                HStack {
                    Text(player.timingWarning ?? player.status).lineLimit(2)
                    Spacer()
                    Text("\(Int(player.progress * 100))% read").monospacedDigit()
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 13).readerGlass()
        }.frame(maxWidth: 560)
    }
    private var voiceButton: some View {
        Button { settings = true } label: {
            Label {
                Text(VoiceEngine.name(player.voice)).font(.system(size: 12, weight: .medium)).lineLimit(1)
            } icon: { Image(systemName: "waveform").foregroundStyle(ReaderStyle.accent).frame(width: 22, height: 36) }
            .frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel("Choose voice, \(VoiceEngine.name(player.voice))")
    }
    private var transport: some View {
        HStack(spacing: 8) {
            Button { browsing = nil; player.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 14)).frame(width: 44, height: 44) }
                .disabled(player.index == 0).accessibilityLabel("Previous passage")
            Button { if !player.installed { settings = true } else { player.toggle() } } label: {
                Group {
                    if player.isPreparing { ProgressView() }
                    else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace)) }
                }.font(.system(size: 17)).frame(width: 46, height: 46)
            }.nativePrimaryButton().clipShape(Circle()).accessibilityLabel(player.isPlaying || player.isPreparing ? "Pause reading" : "Listen to reading")
            Button { browsing = nil; player.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 14)).frame(width: 44, height: 44) }
                .disabled(!player.canNext).accessibilityLabel("Next passage")
        }.buttonStyle(.plain)
    }
    private var speedButton: some View {
        Menu {
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in
                Button("\(speed.formatted())×") { player.rate = Float(speed) }
            }
        } label: { Text("\(player.rate.formatted())×").font(.system(size: 12, weight: .medium)).monospacedDigit().frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("Reading speed, \(player.rate.formatted()) times")
    }
}

struct ReadingOptionsView: View {
    @AppStorage("reader-paged") private var paged = true
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
                    Picker("Reading layout", selection: $paged) {
                        Text("Pages").tag(true)
                        Text("Scroll").tag(false)
                    }.pickerStyle(.segmented)
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
                Text("Highlights follow the generated speech timing. Appearance follows your device.").font(.footnote).foregroundStyle(.secondary)
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
                    } else if !player.kittenInstalled {
                        Text("Download the eight Kitten Mini voices once. Speech then runs on this device, without a Mac or account.")
                        Button("Download voices · about 83 MB") { player.downloadVoices() }.buttonStyle(.borderedProminent)
                        Text("Uses your internet connection for the download. You may prefer Wi-Fi.").font(.footnote).foregroundStyle(.secondary)
                    } else { Label("Natural voices are ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                } header: { Text("On-device voices") }
                Section("Reading voice") {
                    NavigationLink(VoiceEngine.name(player.voice)) { VoiceLibraryView() }
                    if !player.kokoroInstalled {
                        Button("Download Kokoro voices · about 192 MB") { player.downloadVoices(voice: "af_heart") }.disabled(player.downloading)
                        Text("41 additional voices across six languages.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if #available(iOS 26, *) { Kitten2PackSection() }
                Section("On-device AI") { Text(AppleReadingTools.availability).font(.footnote).foregroundStyle(.secondary) }
                Section("Your library") {
                    Button("Export library backup", systemImage: "arrow.down.doc") { do { backup = try library.backup() } catch { self.error = error.localizedDescription } }
                    Text("Readings stay in this app. Export a backup before moving phones or removing OpenRead.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Yours to keep") {
                    Text("Free and open source. No subscriptions, analytics or cloud speech.")
                    NavigationLink("Licences & notices") { MobileNoticesView().navigationTitle("Licences").navigationBarTitleDisplayMode(.inline) }
                    Link("Source & contributions", destination: URL(string: "https://github.com/ahmednajaf/openread")!)
                    Link("Optional support", destination: URL(string: "https://ko-fi.com/pickledjones")!)
                    Text("GPL-3.0-or-later · © 2026 Ahmed Najaf and contributors. Kitten, Kokoro and ONNX Runtime keep their upstream licences. Voices run on this device.").font(.caption).foregroundStyle(.secondary)
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
