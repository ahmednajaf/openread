import SwiftUI

struct VoiceLibraryView: View {
    @EnvironmentObject private var player: PlaybackController
    @State private var search = ""
    @State private var language = "all"
    @AppStorage("favourite-voices") private var savedFavourites = ""
    private var favourites: Set<String> { Set(savedFavourites.split(separator: "|").map(String.init)) }
    private func languageCode(_ voice: VoiceEngine.Choice) -> String { String(voice.lang.prefix(2)).lowercased() }
    private func languageName(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code }
    private var languages: [String] { Set(VoiceEngine.choices.map(languageCode)).sorted { languageName($0) < languageName($1) } }
    private var visible: [VoiceEngine.Choice] {
        VoiceEngine.choices.filter { choice in
            (language == "all" || languageCode(choice) == language) &&
            (search.isEmpty || "\(choice.name) \(choice.detail) \(choice.pack ?? "")".localizedCaseInsensitiveContains(search))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func installed(_ voice: VoiceEngine.Choice) -> Bool {
        voice.pack == "kitten2" ? player.kitten2Installed : voice.pack == "kitten" ? player.kittenInstalled : player.kokoroInstalled
    }
    private func row(_ voice: VoiceEngine.Choice) -> some View {
        HStack(spacing: 12) {
            Button {
                player.voice = VoiceEngine.canonical(voice.id)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(voice.name).foregroundStyle(.primary)
                        Text(voice.detail + (voice.pack == "kitten2" ? " · Kitten 2" : "")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if VoiceEngine.canonical(voice.id) == player.voice { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                    else if !installed(voice) { Image(systemName: "arrow.down.circle").foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!installed(voice))
            Button {
                var values = favourites
                if values.contains(voice.id) { values.remove(voice.id) } else { values.insert(voice.id) }
                savedFavourites = values.sorted().joined(separator: "|")
            } label: { Image(systemName: favourites.contains(voice.id) ? "star.fill" : "star").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).accessibilityLabel("\(favourites.contains(voice.id) ? "Unfavourite" : "Favourite") \(voice.name)")
        }.padding(.vertical, 4)
    }
    var body: some View {
        List {
            Section {
                Picker("Language", selection: $language) {
                    Text("All languages").tag("all")
                    ForEach(languages, id: \.self) { Text(languageName($0)).tag($0) }
                }
                Text("Download a voice pack in Settings to use its voices.").font(.footnote).foregroundStyle(.secondary)
            }
            let saved = visible.filter { favourites.contains($0.id) }
            if !saved.isEmpty { Section("Favourites") { ForEach(saved, id: \.id) { row($0) } } }
            let featured = visible.filter { ["kitten2:Arabic", "kitten2:ArabicFalconer"].contains($0.id) && !favourites.contains($0.id) }
            if !featured.isEmpty { Section("Featured") { ForEach(featured, id: \.id) { row($0) } } }
            ForEach(languages, id: \.self) { code in
                let voices = visible.filter { languageCode($0) == code }
                // Favourites and featured voices stay in their language too, so
                // filtering does not make the catalog appear incomplete.
                if !voices.isEmpty { Section(languageName(code)) { ForEach(voices, id: \.id) { row($0) } } }
            }
            if visible.isEmpty { Text("No matching voices").foregroundStyle(.secondary) }
        }.navigationTitle("Voices").searchable(text: $search, prompt: "Find a voice, accent or language")
    }
}

@available(iOS 26, macOS 26, *)
struct Kitten2PackSection: View {
    @EnvironmentObject private var player: PlaybackController
    @AppStorage("kitten2-expressive") private var expressive = false
    @AppStorage("kitten2-emotion") private var emotion = "natural"
    private var selected: String { VoiceEngine.isKitten2(player.voice) ? player.voice : "kitten2:Arabic" }
    private var language: String { player.timingLanguage(for: selected) }
    private var languageName: String { Locale.current.localizedString(forIdentifier: language) ?? language }
    var body: some View {
        Section("Kitten TTS 2 · beta") {
            Text("115 voices across 16 languages, including Arabic and Arabic Falconer. The shared voice pack uses about 2.1 GB.").font(.footnote).foregroundStyle(.secondary)
            if player.downloading {
                ProgressView(value: player.downloadProgress) { Text(player.downloadProgress >= 0.95 ? "Preparing language and voice engine…" : "Downloading voices…") }
            } else if player.kitten2Installed && player.kitten2TimingReady {
                Label("\(languageName) highlighting is ready", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                Button(player.kitten2Installed ? "Prepare \(languageName) highlighting" : "Download Kitten TTS 2 · about 2.1 GB") { player.downloadVoices(voice: selected) }
            }
            if player.kitten2Installed {
                NavigationLink("Browse all voices") { VoiceLibraryView() }
                Toggle("More expressive variation", isOn: $expressive)
                Picker("Delivery", selection: $emotion) {
                    Text("Natural").tag("natural")
                    ForEach(["mundane", "nervous", "tender", "angry", "excited", "stern", "sad", "contemplative", "surprised", "joyful"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                Text("Delivery applies to Kitten TTS 2. The voice’s accent comes from its speaker. Word highlighting uses an additional one-time Apple language download, processed entirely on this device.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Use Wi-Fi and allow room for the download. Kitten Mini and Kokoro remain the smaller options for everyday reading.").font(.footnote).foregroundStyle(.secondary)
            }
            Text("Powered by KittenML").font(.caption).foregroundStyle(.secondary)
            Link("Kitten TTS 2 model licence", destination: URL(string: "https://kittenml.com/license/")!).font(.caption)
        }
    }
}
