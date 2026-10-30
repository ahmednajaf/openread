import Foundation
import SafariServices
import os

// Source text is never logged or sent over the network. Only Safari's own
// background script can reach this host, through the nativeMessaging permission.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let voice = VoiceEngine()
    private static let log = Logger(subsystem: "app.getopenread.reader", category: "SafariVoice")
    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any] else {
            complete(context, ["ok": false, "error": "The extension request was invalid."]); return
        }
        Task {
            do { complete(context, try await Self.handle(message)) }
            catch {
                // Log only the error category, never a reading or model request.
                Self.log.error("Native voice request failed: \(String(describing: type(of: error)), privacy: .public)")
                complete(context, ["ok": false, "error": "Open the OpenRead app and download its natural voices, then retry. If voices are installed, try a shorter passage."])
            }
        }
    }
    private static func handle(_ message: [String: Any]) async throws -> [String: Any] {
        switch message["type"] as? String {
        case "health":
            let kitten = await voice.isInstalled(), kokoro = await voice.isInstalled(voice: "af_heart"), kitten2 = await voice.isInstalled(voice: "kitten2:Arabic")
            return ["ok": true, "native": true, "voices": VoiceEngine.choices.map { ["id": $0.id, "available": $0.pack == "kitten2" ? kitten2 : $0.id.hasPrefix("kitten:") ? kitten : kokoro] },
                    "setupHint": "Open the OpenRead app and download natural voices first."]
        case "startListening":
            guard let tab = message["tab"] as? Int, let items = message["items"] as? [String],
                  let id = message["voice"] as? String, let rate = message["rate"] as? Double,
                  let index = message["index"] as? Int else { throw ReadingError.invalidReading }
            let request = try SafariListeningSession().create(tab: tab, title: String((message["title"] as? String ?? "Safari reading").prefix(240)),
                source: message["source"] as? String ?? "", voice: id, rate: Float(rate), items: items, index: index)
            return ["ok": true, "id": request.id]
        case "listeningState":
            guard let id = message["id"] as? String, let tab = message["tab"] as? Int else { throw ReadingError.invalidReading }
            let value = try SafariListeningSession().state(id, tab: tab)
            var result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
            result["ok"] = true; return result
        case "listeningCommand":
            guard let id = message["id"] as? String, let tab = message["tab"] as? Int,
                  let action = message["action"] as? String else { throw ReadingError.invalidReading }
            let store = SafariListeningSession()
            try store.command(id, tab: tab, action: action, index: message["index"] as? Int,
                rate: (message["rate"] as? Double).map(Float.init), autoplay: message["autoplay"] as? Bool)
            if action == "stop", let state = try? store.state(id, tab: tab) {
                try store.write(.init(status: "ended", index: state.index, rate: state.rate, word: nil, error: nil), id: id)
            }
            return ["ok": true]
        case "synthesize":
            guard let text = message["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 1600,
                  let id = message["voice"] as? String, VoiceEngine.choices.contains(where: { $0.id == id }) else {
                return ["ok": false, "error": "Choose an installed OpenRead voice and a shorter passage."]
            }
            #if os(iOS)
            Self.log.notice("Preparing Safari voice. Available memory: \(os_proc_available_memory(), privacy: .public) bytes")
            #endif
            guard !VoiceEngine.isKitten2(id) else {
                return ["ok": false, "error": "Kitten TTS 2 plays in the OpenRead app. Choose Listen to page to begin."]
            }
            let selected = VoiceEngine.canonical(id)
            guard FileManager.default.fileExists(atPath: LocalVoiceInference.preparedModel(in: AppFiles.models, kokoro: VoiceEngine.isKokoro(selected)).path) else {
                return ["ok": false, "error": "Open the OpenRead app once to prepare its Safari voices, then return here."]
            }
            try await voice.prepare(voice: selected, download: false) { _ in }
            Self.log.notice("Safari voice ready")
            let clip = try await voice.generate(text, voice: selected)
            Self.log.notice("Safari audio generated")
            return ["ok": true, "audio": clip.wav.base64EncodedString(), "duration": clip.duration, "voice": id, "timingSource": "model-phonemes",
                    "words": clip.words.map { ["offset": $0.range.location, "length": $0.range.length, "start": $0.start, "end": $0.end] }]
        case "saveDocument":
            guard let text = message["text"] as? String, !text.isEmpty, text.utf16.count <= 250_000,
                  FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppFiles.group) != nil else { throw ReadingError.invalidReading }
            let reading = try Reading(title: String((message["title"] as? String ?? "Saved reading").prefix(240)), text: text,
                                      source: (message["source"] as? String).map { String($0.prefix(1000)) }).validated
            try JSONEncoder().encode(reading).write(to: AppFiles.inbox.appendingPathComponent(reading.id + ".json"), options: .atomic)
            return ["ok": true]
        default: return ["ok": false, "error": "This extension action is unavailable."]
        }
    }
    private func complete(_ context: NSExtensionContext, _ message: [String: Any]) {
        let response = NSExtensionItem(); response.userInfo = [SFExtensionMessageKey: message]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
