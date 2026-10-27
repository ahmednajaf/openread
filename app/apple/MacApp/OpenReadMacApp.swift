import SwiftUI
import SafariServices
import AppKit

@main struct OpenReadMacApp: App {
    @StateObject private var library = LibraryStore()
    @State private var installed = false
    @State private var downloading = false
    @State private var progress = 0.0
    @State private var selected: Reading.ID?
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase
    private let engine = VoiceEngine()
    var body: some Scene {
        WindowGroup("OpenRead") {
            NavigationSplitView {
                List(selection: $selected) {
                    Section("Your library") { ForEach(library.readings) { reading in
                        VStack(alignment: .leading, spacing: 5) { Text(reading.title).font(.headline); Text("\(reading.wordCount) words").font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 5).tag(reading.id)
                    } }
                }.navigationSplitViewColumnWidth(min: 210, ideal: 250)
            } detail: {
                if let reading = library.readings.first(where: { $0.id == selected }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            Text(reading.title).font(.system(size: 36, design: .serif))
                            Text(reading.text).font(.system(size: 20, design: .serif)).lineSpacing(10).textSelection(.enabled)
                            if let source = reading.source, let url = URL(string: source), ["https", "http"].contains(url.scheme ?? "") { Link("Read on the original page", destination: url) }
                        }.padding(40).frame(maxWidth: 760)
                    }
                } else {
                    VStack(spacing: 24) {
                        Image(systemName: "book.pages").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(.tint)
                        Text("Your words.\nYour rhythm.").font(.system(size: 46, design: .serif)).multilineTextAlignment(.center)
                        Text("Natural reading, right inside Safari.").font(.title3).foregroundStyle(.secondary)
                        if downloading { ProgressView(value: progress).frame(width: 260); Text("Downloading your voices…").foregroundStyle(.secondary) }
                        else if !installed {
                            Button("Download eight natural voices · 83 MB") { setup() }.buttonStyle(.borderedProminent)
                            Text("Download once. Then speech stays on your Mac.").font(.caption).foregroundStyle(.secondary)
                        } else { Label("Your voices are ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        Button("Enable OpenRead in Safari") {
                            SFSafariApplication.showPreferencesForExtension(withIdentifier: (Bundle.main.bundleIdentifier ?? "app.getopenread.reader") + ".safari") { failure in if let failure { Task { @MainActor in error = failure.localizedDescription } } }
                        }
                        Text("Open an article in Safari, click OpenRead, then Listen to page.\nWords highlight on the page while you listen.\nSaved pages appear in your library here.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                        HStack(spacing: 20) { Link("Source", destination: URL(string: "https://github.com/ahmednajaf/openread")!); Link("Optional support", destination: URL(string: "https://ko-fi.com/pickledjones")!) }.font(.caption)
                    }.padding(45).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .tint(Color(red: 0.47, green: 0.37, blue: 0.65))
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(minWidth: 850, minHeight: 650)
            .task {
                installed = await engine.isInstalled(); receiveInbox()
                if installed {
                    do { try await engine.prepare(download: false) { _ in } }
                    catch { self.error = "Your voices could not be prepared. Reopen OpenRead and try again." }
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { receiveInbox() } }
            .onOpenURL { url in if url.scheme == "openread" { receiveInbox(); NSApp.activate(ignoringOtherApps: true) } }
            .alert("OpenRead", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
        Settings { ScrollView { Text((Bundle.main.url(forResource: "NOTICES", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "See licences in the source repository.").font(.caption).textSelection(.enabled).padding() }.frame(width: 650, height: 500) }
    }
    private func setup() {
        downloading = true
        Task {
            do { try await engine.prepare(download: true) { value in Task { @MainActor in progress = value } }; installed = true }
            catch { self.error = error.localizedDescription }
            downloading = false
        }
    }
    private func receiveInbox() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: AppFiles.inbox, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == "json" {
            do { let reading = try JSONDecoder().decode(Reading.self, from: Data(contentsOf: url)); try library.save(reading); try FileManager.default.removeItem(at: url) }
            catch { self.error = "A saved page could not be opened. Its file has been kept." }
        }
    }
}
