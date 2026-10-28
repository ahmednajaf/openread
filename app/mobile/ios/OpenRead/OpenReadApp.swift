import SwiftUI
import UniformTypeIdentifiers

@main struct OpenReadApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var playback = PlaybackController()
    var body: some Scene {
        WindowGroup { LibraryView().environmentObject(library).environmentObject(playback).tint(ReaderStyle.accent) }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var readerOpen = false
    @State private var pasteOpen = false
    @State private var importOpen = false
    @State private var settingsOpen = false
    @State private var cameraOpen = false
    @State private var restoring = false
    @State private var processingInbox = false
    @State private var busy: String?
    @State private var error: String?
    private let importer = DocumentImporter()
    private let allowed: [UTType] = [.pdf, .plainText, .html, .image, .json, UTType(filenameExtension: "epub")!, UTType(filenameExtension: "docx")!]
    private var filtered: [Reading] { library.readings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.text.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(spacing: 8) {
                        Image(systemName: "book.pages").font(.title3.weight(.light))
                        Text("openread.").font(.system(.title2, design: .rounded, weight: .bold)).tracking(-1)
                        Spacer()
                        Label("On device", systemImage: "lock").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 36) {
                            introduction.frame(width: 300, alignment: .leading)
                            sampleCard.frame(minWidth: 300, maxWidth: .infinity)
                        }
                        VStack(alignment: .leading, spacing: 24) { introduction; sampleCard }
                    }.padding(.top, 12)
                    if let reading = inProgress {
                        Button { open(reading) } label: {
                            HStack(spacing: 18) {
                                BookCover(reading: reading)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("CONTINUE READING").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary)
                                    Text(reading.title).font(.system(.title3, design: .serif)).foregroundStyle(.primary).lineLimit(2)
                                    ProgressView(value: Double(reading.position) / Double(max(1, reading.textLength))).tint(ReaderStyle.accent).frame(maxWidth: 200)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.right").font(.body).foregroundStyle(ReaderStyle.accent)
                            }.padding(20).readerGlass()
                        }.buttonStyle(.plain).accessibilityLabel("Continue reading \(reading.title)")
                    }
                    if !playback.installed {
                        Button { settingsOpen = true } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "waveform.circle").font(.title)
                                VStack(alignment: .leading, spacing: 4) { Text("Make yourself at home").font(.subheadline.weight(.semibold)); Text("Download your eight on-device voices").font(.caption).foregroundStyle(.secondary) }
                                Spacer(); Image(systemName: "arrow.down").font(.subheadline)
                            }.padding(18).readerGlass()
                        }.buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("Your library").font(.system(.title2, design: .serif))
                            Spacer(); Text("\(filtered.count) saved").font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], alignment: .leading, spacing: 16) {
                            ForEach(filtered) { reading in
                                Button { open(reading) } label: {
                                    HStack(spacing: 18) {
                                        BookCover(reading: reading)
                                        VStack(alignment: .leading, spacing: 7) {
                                            Text(reading.title).font(.system(.headline, design: .serif)).foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(2)
                                            Text("\(reading.wordCount) words · \(max(1, reading.wordCount / 165)) min").font(.caption).foregroundStyle(.secondary)
                                            if reading.position > 0 { ProgressView(value: Double(reading.position) / Double(max(1, reading.textLength))).frame(maxWidth: 100).tint(ReaderStyle.accent) }
                                        }
                                        Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }.padding(16).frame(maxWidth: .infinity, minHeight: 122, alignment: .leading).readerGlass()
                                }.buttonStyle(.plain)
                                .contextMenu { Button("Delete reading", systemImage: "trash", role: .destructive) { do { try library.remove(reading.id); if playback.reading?.id == reading.id { playback.stop() } } catch { self.error = error.localizedDescription } } }
                            }
                        }
                        if filtered.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: "text.badge.plus").font(.title2.weight(.light)).foregroundStyle(.secondary)
                                Text(search.isEmpty ? "Room for your next read." : "No matching readings.").font(.system(.title3, design: .serif))
                                Text(AppFiles.sharingHint).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                if search.isEmpty { Button("Add a reading") { pasteOpen = true }.font(.subheadline.weight(.medium)).padding(.top, 5) }
                            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 24))
                        }
                    }
                    Label("On your device. Yours to keep.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.padding(.horizontal, 26).padding(.bottom, 25).frame(maxWidth: 1_040).frame(maxWidth: .infinity)
            }
            .background(ReadingBackdrop()).navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Find a reading")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { settingsOpen = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Settings") }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Paste text", systemImage: "doc.on.clipboard") { pasteOpen = true }
                        Button("Import a document", systemImage: "doc.badge.plus") { restoring = false; importOpen = true }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { Button("Scan a page", systemImage: "camera") { cameraOpen = true } }
                        Button("Restore a library backup", systemImage: "arrow.uturn.backward") { restoring = true; importOpen = true }
                    } label: { Image(systemName: "plus") }.accessibilityLabel("Add a reading")
                }
            }
            .navigationDestination(isPresented: $readerOpen) { ReaderView() }
            .sheet(isPresented: $pasteOpen) { PasteReadingView { reading in playback.open(reading); pasteOpen = false; readerOpen = true } }
            .sheet(isPresented: $settingsOpen) { NativeSettingsView() }
            .sheet(isPresented: $cameraOpen) { CameraCapture { data in cameraOpen = false; if let data { run { try await importer.image(data) } } } }
            .fileImporter(isPresented: $importOpen, allowedContentTypes: restoring ? [.json, .zip] : allowed, allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first {
                    if restoring { do { let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }; try library.restore(url) } catch { self.error = error.localizedDescription } }
                    else { run { try await importer.file(url) } }
                }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
            .onOpenURL { url in if url.scheme == "openread" { readerOpen = false; Task { await receiveInbox() } } else { run { try await importer.file(url) } } }
            .onAppear {
                playback.onPosition = { id, offset in
                    do { try library.position(id, offset) } catch { self.error = error.localizedDescription }
                }
                Task { await receiveInbox() }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await receiveInbox() } } }
            .overlay { if let busy { ProgressView(busy).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
            .alert("OpenRead", isPresented: Binding(get: { error != nil || library.error != nil }, set: { if !$0 { error = nil; library.error = nil } })) { Button("OK") { error = nil; library.error = nil } } message: { Text(error ?? library.error ?? "") }
        }
    }
    private var inProgress: Reading? {
        library.readings.first { $0.position > 0 && $0.position < $0.textLength }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            (Text("Your next\n") + Text("chapter.").italic().foregroundColor(ReaderStyle.accent))
                .font(.system(size: 48, weight: .regular, design: .serif)).tracking(-1.8)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick a book. Find your rhythm.").font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var sampleCard: some View {
        Button { openSample() } label: {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A CLASSIC, REOPENED").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary)
                        Text("The Odyssey").font(.system(size: 32, design: .serif)).foregroundStyle(.primary)
                        Text("Homer · Book I").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 10); BookEmblem(compact: true)
                }
                HStack {
                    Label("Open the book", systemImage: "book.pages").font(.subheadline.weight(.medium))
                    Spacer(); Image(systemName: "arrow.up.right").font(.subheadline)
                }
            }.padding(26).frame(maxWidth: .infinity, alignment: .leading).readerGlass()
        }.buttonStyle(.plain).accessibilityLabel("Try The Odyssey")
    }
    private func open(_ reading: Reading) {
        do { playback.open(try library.load(reading.id)); readerOpen = true }
        catch { self.error = error.localizedDescription }
    }
    private func openSample() {
        do {
            struct Sample: Decodable { let title: String; let text: String; let author: String? }
            let sample = try JSONDecoder().decode(Sample.self, from: Data(contentsOf: Bundle.main.url(forResource: "odyssey", withExtension: "json")!))
            playback.open(Reading(id: "odyssey-sample", title: sample.title, text: sample.text, author: sample.author)); readerOpen = true
        } catch { self.error = error.localizedDescription }
    }
    private func run(_ operation: @escaping () async throws -> Reading) {
        busy = "Opening your reading…"
        Task { do { let reading = try await operation(); playback.open(reading); readerOpen = true } catch { self.error = error.localizedDescription }; busy = nil }
    }
    private func receiveInbox() async {
        guard !processingInbox else { return }; processingInbox = true
        defer { processingInbox = false }
        for (url, result) in await importer.inbox() {
            switch result {
            case .success(var reading):
                reading.id = url.deletingPathExtension().lastPathComponent
                do { try library.save(reading); try FileManager.default.removeItem(at: url) } catch { self.error = error.localizedDescription }
            case .failure(let error): self.error = "A shared reading could not be opened: \(error.localizedDescription)"
            }
        }
    }
}

struct PasteReadingView: View {
    @Environment(\.dismiss) private var dismiss
    let complete: (Reading) -> Void
    @State private var title = ""
    @State private var text = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Give it a title", text: $title).textInputAutocapitalization(.sentences)
                TextEditor(text: $text).frame(minHeight: 300).accessibilityLabel("Text to read")
                Text("Your text stays on this device. Choose Save in the reader to keep it.").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("Bring your own words").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Read") { complete(Reading(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Your reading" : String(title.prefix(240)), text: text.trimmingCharacters(in: .whitespacesAndNewlines))) }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf16.count > 20_000_000) } }
        }
    }
}
