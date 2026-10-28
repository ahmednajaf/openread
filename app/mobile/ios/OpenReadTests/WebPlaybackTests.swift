import XCTest
import WebKit
@testable import OpenRead

final class WebPlaybackTests: XCTestCase {
    @MainActor func testWebKitPreloadsPassagesPreservesPitchAndClearsPausedHighlights() async throws {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController(); controller.view = view; window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "player", withExtension: "js"))
        let source = try String(contentsOf: url, encoding: .utf8)
        _ = try await view.evaluateJavaScript(source)
        let samples = (0..<24_000).map { Float(sin(Double($0) * 2 * .pi * 220 / 24_000) * 0.05) }
        let wav = SpeechTokens.wav(samples).base64EncodedString()
        let result = try await view.callAsyncJavaScript("""
        const changes = [], highlights = [], errors = [];
        const player = new OpenReadPlayer({ AudioClass: Audio, preloadAudio: true,
          frame: f => setTimeout(f, 10), cancelFrame: id => clearTimeout(id),
          request: async () => ({ok:true,audio:wav,words:[{offset:0,length:4,start:0.05,end:0.85}]}),
          onChange: v => changes.push(v), onWord: o => highlights.push(o), onWordClear: () => highlights.push(null), onError: e => errors.push(e) });
        const sleep = n => new Promise(r => setTimeout(r,n));
        player.load([{text:'First.'},{text:'Second.'},{text:'Third.'}]);
        await player.play(); await sleep(250);
        const preloaded = !!player.queued;
        player.pause(); const position = player.audio.currentTime;
        const cleared = highlights.at(-1) === null;
        await sleep(150); const pausedDelta = player.audio.currentTime - position;
        player.configure({rate:2}); await player.play();
        const pitch = player.audio.preservesPitch;
        const deadline = Date.now() + 8000;
        while (player.status !== 'ended' && Date.now() < deadline && !errors.length) await sleep(25);
        const result = {preloaded,cleared,pausedDelta,pitch,status:player.status,indices:[...new Set(changes.filter(v=>v.status==='playing').map(v=>v.index))],highlighted:highlights.some(v=>v===0),errors};
        player.destroy(); return result;
        """, arguments: ["wav": wav], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["preloaded"] as? Bool, true)
        XCTAssertEqual(values["cleared"] as? Bool, true)
        XCTAssertLessThan(abs(values["pausedDelta"] as? Double ?? 1), 0.03)
        XCTAssertEqual(values["pitch"] as? Bool, true)
        XCTAssertEqual(values["status"] as? String, "ended", "\(values)")
        XCTAssertEqual(values["indices"] as? [Int], [0,1,2])
        XCTAssertEqual(values["highlighted"] as? Bool, true)
        XCTAssertEqual(values["errors"] as? [String], [])
    }
}
