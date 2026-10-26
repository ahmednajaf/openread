import SwiftUI
import UniformTypeIdentifiers

@main struct OpenReadApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var playback = PlaybackController()
    var body: some Scene {
        WindowGroup { LibraryView().environmentObject(library).environmentObject(playback).tint(Color(red: 0.53, green: 0.43, blue: 0.72)) }
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
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your words.\nYour rhythm.").font(.system(size: 37, weight: .regular, design: .serif))
                        Text("A natural voice. A little more focus.").foregroundStyle(.secondary)
                        Button { openSample() } label: { Label("Try The Odyssey", systemImage: "headphones") }.buttonStyle(.borderedProminent)
                    }.padding(.vertical, 20).listRowBackground(Color.clear)
                }
                if !playback.installed {
                    Section { Button { settingsOpen = true } label: { Label("Set up natural voices", systemImage: "arrow.down.circle").font(.headline) } }
                }
                Section("Your library") {
                    ForEach(filtered) { reading in
                        Button { playback.open(reading); readerOpen = true } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "book.closed.fill").font(.title2).foregroundStyle(.tint).frame(width: 42, height: 58).background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 5) { Text(reading.title).font(.headline).foregroundStyle(.primary); Text("\(reading.wordCount) words · saved on this device").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 6)
                        }.swipeActions { Button("Delete", role: .destructive) { do { try library.remove(reading.id); if playback.reading?.id == reading.id { playback.stop() } } catch { self.error = error.localizedDescription } } }
                    }
                    if filtered.isEmpty { ContentUnavailableView(search.isEmpty ? "Room for your next read" : "No matching readings", systemImage: "books.vertical", description: Text(AppFiles.sharingHint)) }
                }
                Section { Text("Free. On your device. Yours to keep.").font(.footnote).foregroundStyle(.secondary) }
            }
            .listStyle(.insetGrouped).navigationTitle("OpenRead")
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
            .fileImporter(isPresented: $importOpen, allowedContentTypes: restoring ? [.json] : allowed, allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first {
                    if restoring { do { let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }; try library.restore(Data(contentsOf: url)) } catch { self.error = error.localizedDescription } }
                    else { run { try await importer.file(url) } }
                }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
            .onOpenURL { url in run { try await importer.file(url) } }
            .onAppear {
                playback.onPosition = { id, offset in
                    if var reading = library.readings.first(where: { $0.id == id }) { reading.position = offset; do { try library.save(reading) } catch { self.error = error.localizedDescription } }
                }
                Task { await receiveInbox() }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await receiveInbox() } } }
            .overlay { if let busy { ProgressView(busy).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
            .alert("OpenRead", isPresented: Binding(get: { error != nil || library.error != nil }, set: { if !$0 { error = nil; library.error = nil } })) { Button("OK") { error = nil; library.error = nil } } message: { Text(error ?? library.error ?? "") }
        }
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Read") { complete(Reading(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Your reading" : String(title.prefix(240)), text: text.trimmingCharacters(in: .whitespacesAndNewlines))) }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf16.count > 250_000) } }
        }
    }
}
