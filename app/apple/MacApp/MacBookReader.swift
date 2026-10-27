import SwiftUI
import AppKit

struct MacBookReader: View {
    @EnvironmentObject var player: PlaybackController
    var body: some View {
        VStack(spacing: 16) {
            if let reading = player.reading, !reading.chapterList.isEmpty {
                Picker("Chapter", selection: Binding(get: { player.activeChapter }, set: { player.seekOffset(reading.chapterList[$0].offset) })) {
                    ForEach(Array(reading.chapterList.enumerated()), id: \.element.id) { index, chapter in Text(chapter.title).tag(index) }
                }
            }
            if (player.reading?.textLength ?? 0) > 64_000 {
                HStack { Button("Earlier text") { player.seekTextWindow(-1) }.disabled(player.textWindow.location == 0); Spacer(); Button("More text") { player.seekTextWindow(1) }.disabled(NSMaxRange(player.textWindow) >= (player.reading?.textLength ?? 0)) }.font(.caption)
            }
            MacReadingText(text: player.visibleText, highlighted: player.visibleHighlight, follow: player.follow).frame(minHeight: 320)
            ProgressView(value: player.progress)
            HStack {
                Picker("Voice", selection: $player.voice) { ForEach(VoiceEngine.voices, id: \.self) { Text(VoiceEngine.name($0)).tag($0) } }.frame(maxWidth: 220)
                Button { player.previous() } label: { Image(systemName: "backward.end.fill") }.disabled(player.index == 0)
                Button { player.toggle() } label: { Label(player.isPreparing ? "Preparing…" : player.isPlaying ? "Pause" : "Listen", systemImage: player.isPlaying || player.isPreparing ? "pause.fill" : "play.fill") }.buttonStyle(.borderedProminent)
                Button { player.next() } label: { Image(systemName: "forward.end.fill") }.disabled(!player.canNext)
                Picker("Speed", selection: $player.rate) { ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text("\($0.formatted())×").tag($0) } }.frame(width: 100)
            }
            Text(player.error ?? player.status).font(.caption).foregroundStyle(.secondary)
        }
    }
}
private struct MacReadingText: NSViewRepresentable {
    let text: String; let highlighted: NSRange?; let follow: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.textContainer?.widthTracksTextView = true
        view.font = NSFont(name: "Georgia", size: 22) ?? .systemFont(ofSize: 22); view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 12, height: 16); scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        view.textColor = .labelColor
        let whole = NSRange(location: 0, length: (text as NSString).length)
        view.textStorage?.removeAttribute(.backgroundColor, range: whole)
        if let highlighted, NSMaxRange(highlighted) <= whole.length {
            view.textStorage?.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: highlighted)
            if follow { view.scrollRangeToVisible(highlighted) }
        }
    }
}
