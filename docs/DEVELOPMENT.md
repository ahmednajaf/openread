# OpenRead development notes

Build instructions, packaging, implementation details and verification for contributors. For installation, start with [Getting started](../GETTING_STARTED.md).

## Run locally

For a temporary Safari install, the committed `extension/` folder already contains the bundled UI. Node isn't needed just to load that folder.

For development: Node 22+, Python **3.11–3.13**, macOS with Safari or Chrome. Optional model integrations can be set up separately.

```sh
npm ci
npm run build
python3.11 app/voice/setup.py
.venv/bin/python app/voice/server.py --allow-preview
```

One-time voice setup creates a private `.venv/` and downloads approximately **436 MB** of voice weights/styles into `.local/models/` and `.local/kitten-mini/`, plus Python packages. Pinned SHA-256 hashes verify the model assets. This includes all 49 voice choices. Whisper is an optional, separate dictation download. After setup, inference is local. ONNX Runtime telemetry is disabled.

Start the preview in another terminal:

```sh
npm run preview
```

Open [the local preview](http://127.0.0.1:4173). The preview runs the shared settings UI, speech engine, extraction, and in-page highlighting. Its Open OpenRead button opens an in-page preview of the shared settings view. In Safari itself, controls open in the actual extension toolbar popup; the webpage hosts only playback and word highlighting.

For ordinary Safari use, omit `--allow-preview`, or double-click **Start OpenRead.command** in Finder. Leave the helper running while listening; Control-C stops it. Restart it after updating `app/voice/server.py`.

## Add to Chrome

Open `chrome://extensions`, enable Developer mode, choose Load unpacked, and select this repository’s `extension/` folder. Pin OpenRead from the puzzle-piece menu. The local helper must be running. Read [GETTING_STARTED.md](../GETTING_STARTED.md) for the illustrated-by-steps install flow and update instructions.

For a separate clean package: `npm run chrome`. This builds a ZIP for distribution; it does not publish to the Chrome Web Store.

## Add to Safari

### Temporary development extension

1. Open Safari Settings → Developer → **Add Temporary Extension…**.
2. Approve **Allow unsigned extensions** in macOS if prompted. This approval resets when Safari quits.
3. Choose this repository's `extension/` folder.
4. Enable **OpenRead** for your Safari profile in Settings → Extensions.
5. Start the local helper, open an article, and click OpenRead's book icon in the toolbar.

After source changes, rebuild the UI with `npm run build`, then use **Reload** in OpenRead's Safari extension settings and reload the webpage. Safari lists this under Temporary extensions; you may need to add or enable it after a restart.

### Xcode app wrapper

Full Xcode is needed for the wrapper, not the temporary-folder install above.

```sh
npm run safari
open build/safari/OpenRead/OpenRead.xcodeproj
```

If extension files were added since generating the project:

```sh
npm run safari -- --refresh
```

Unsigned local development build:

```sh
xcodebuild -project build/safari/OpenRead/OpenRead.xcodeproj \
  -scheme OpenRead -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
open build/DerivedData/Build/Products/Debug/OpenRead.app
```

Run the containing app once, enable unsigned extensions, and enable OpenRead in Safari's extension settings. The generated project references `extension/` source files. `build/` is generated and ignored.

## Listening

The toolbar popup and the page player have separate lifetimes. Dismissing or reopening the popup does not restart speech. No settings panel is injected into production webpages; only highlights and, when Safari requires a page gesture, the temporary start button are added.

- Click **Listen to page**. The popover hides when audio starts; the current word highlights in the page. If Safari blocks popup-initiated audio, a temporary **Start listening** button appears on the webpage. Click it once to authorize that page’s audio; it disappears when reading starts. Voice previews use the same fallback when needed.
- Click the toolbar icon to change voice or speed, pause, skip a passage, or stop. Closing settings keeps audio playing.
- **Option–Shift–P** plays/pauses from the webpage. **Escape** hides settings.
- **Reading options** controls word highlighting, auto-scroll, text selection and Paste text.
- Select text before opening OpenRead to listen only to that selection. To switch back, choose This page in Reading options.
- Preview any selected voice with the small play button beside the voice picker.

## Safari Reader

OpenRead does not create a second reading window. Use Safari's native **Show Reader** command (`Shift–Command–R`) when available. Safari exposes no supported WebExtension API for OpenRead to switch its Reader on itself, so the settings action explains the native shortcut.

Word highlighting targets the **original webpage**. Safari's protected Reader interface is outside that DOM. Reader can obscure the highlights, and some page/Reader transitions may stop the page's audio. Return to the original webpage to use synchronized highlighting. This limitation is explicit rather than presenting a custom reading overlay as Apple's Reader.

## Glass and logo sources

Safari provides the actual native toolbar material. The extension keeps its popup background transparent so that surface remains visible. The in-page development preview uses an independent CSS blur; it is not the native macOS material. Chrome uses its own device-matched popup surface. Light/dark appearance follows the device, with reduced motion and reduced transparency respected.

`app/extension-ui/glass-entry.js` is a small DOM adapter copied to `extension/glass.js` by the build. The toolbar has no React runtime. The reading workspace uses bundled React and the MIT-licensed Glass Headline Hero; see THIRD_PARTY.md and docs/notices/. No CDN or remote UI assets are fetched.

The generated logo master is `docs/assets/openread-logo.png`; its exact prompt/mode is `docs/assets/logo-prompt.txt`. Runtime icon sizes live in `extension/icons/`.

## Word timing and extraction details

Kokoro's duration-capable model provides phoneme timestamps. The helper aligns source words against those phonemes, handling number expansions and contextual pronunciations, and returns UTF-16 offsets for DOM ranges. Rare unmatched words are interpolated between surrounding model timings and explicitly marked `estimated` in the response. This is not forced alignment against a recorded human reading; unusual words can still drift slightly.

Normalized speech text retains offsets into original text nodes, including words split across inline markup. One non-interactive overlay paints rectangles for the current word and replaces them each time. This avoids stale CSS Custom Highlight paints in Safari. Scroll and resize reposition the current rectangles without accumulating marks. Stops and navigation clear highlights. If the underlying mapped text changes, playback pauses rather than highlighting a wrong word.

Article extraction is heuristic and won't be perfect on every site. The extension cannot read inside Safari’s PDF viewer, browser-internal pages, embedded frames, or closed shadow roots. Import PDFs/images into the companion workspace for text extraction or macOS OCR. English is strongest; the additional exposed languages remain experimental. Keep the tab open; multiple tabs can play independently, so use one at a time.

Kitten's model also supplies token durations. The helper maps the exact tokenizer sequence (including separators and boundary tokens) onto those durations, then joins chunk times into the source timeline. Empty, silent, non-finite audio or invalid durations are rejected. Kitten and Kokoro share source-to-phoneme alignment; uncertain source matches are explicitly marked `estimated`. Neither requires a Whisper recognition pass for reading.

## Privacy and permissions

On `web.whatsapp.com`, the extension defaults to chat mode and extracts loaded message bodies inside `#main`, in DOM order, using `data-pre-plain-text` sender metadata. Outgoing bubbles use “You said”. Sender introductions have no highlight ranges; message text keeps its exact DOM mapping. Quoted copies, controls and drafts are excluded. There is no automatic incoming-message playback or background chat collection. Refresh explicitly replaces the snapshot. A source validator and mutation observer stop stale conversation audio, including synthesis already in flight. WhatsApp's undocumented markup can change; empty/unsupported layouts do not fall back to whole-page extraction.

- `activeTab` and `scripting` open the reader only when invoked on a tab; no automatic all-site content scripts or history permission.
- Extension/browser preferences remember voice, speed and reading options. Ordinary webpage playback remains in memory. Only an explicit Save creates a local library entry; saved documents/bookmarks/progress live in `.local/library.sqlite3`. The companion can export text/audio/backups at your request. Uploaded recordings are processed in memory, not intentionally retained as files.
- Loopback host permission lets the background contact only the local helper at `127.0.0.1:8765`. Text is never sent to a cloud speech provider.
- The helper binds to loopback, checks Host/origin/custom headers, limits body size/concurrency and queues local work, and does not log text/audio or synthesis exceptions. The local workspace has a restrictive content security policy. It is a personal service, not an authenticated multi-user server. AI calls go only to local Ollama; runtime transcription loads already-downloaded weights.
- Model/package downloads require internet during setup. Runtime speech, AI processing and UI use no cloud inference endpoints or remote fonts. ONNX telemetry is disabled before model initialization.

## Licence, contributions and support

**OpenRead is free and open source under [GPL-3.0-or-later](../LICENSE).** You can use, modify and share it, including commercially, under those terms. Distributed covered versions must preserve the applicable source freedoms and notices. See [LICENSING.md](../LICENSING.md) and [THIRD_PARTY.md](../THIRD_PARTY.md); downloaded models keep their upstream licences.

Contributions are welcome: report a bug, improve installation instructions, help with accessibility, or send a focused pull request. [CONTRIBUTING.md](../CONTRIBUTING.md) explains how. Ahmed (@ahmednajaf) reviews proposed changes and decides what to merge. Community contributions are optional; using OpenRead requires no contribution or payment.

If OpenRead helps you, [optional donations on Ko-fi](https://ko-fi.com/pickledjones) support maintenance. Starring the repository, sharing it and reporting problems help too. Donations do not unlock features or buy priority reviews.

Local speech and AI have no per-minute API or OpenRead hosting fees; they use your computer’s processing, memory, disk and electricity. A future paid distribution may support easier installation and maintenance while source access remains free. No paid/store edition is available in this release; store terms and GPL distribution obligations need review before that separate release.

## Verification

```sh
npm test
```

The automated tests cover timing alignment/UTF-16, voice validation, local-service access rules, playback cancellation races, audio-clock word events, prefetch, and position-preserving speed changes.

`node dev/tests/whatsapp-browser.cjs` tests chat extraction, sender announcements, exact DOM ranges, playback order, refresh and conversation-change cancellation in WebKit. Use `BROWSER=chromium` for Chromium. Every network request is intercepted and messages come from a synthetic fixture; no WhatsApp account is used. Live WhatsApp compatibility still needs checking against its current layout. As with the other browser checks, Playwright and its browser binaries are development-only dependencies.

`dev/tests/browser.cjs`, `dev/tests/reading-browser.cjs`, and `dev/tests/popup-browser.cjs` use an isolated Playwright WebKit browser with the running preview/helper. Set `NODE_PATH` to your Playwright installation if it is outside this project. They test native-popup transparency and preview surfaces, real speech, original-page highlighting, nested lists, skipped/hidden content, inline markup, partial selections, stale DOM maps, dark/narrow layouts, and non-destructive page handling. The full reading test completes all passages with real speech, checks linked-word highlights and metadata exclusion, and verifies that old marks are removed. Set `BROWSER=chromium` for the Chrome variant; loopback permission is granted only to that isolated test profile. Playwright isn't a runtime dependency.


## Real-engine integration checks

```sh
.venv/bin/python dev/tests/local_tools_integration.py
.venv/bin/python dev/tests/local_tools_integration.py --voices
.venv/bin/python dev/tests/ai_integration.py
node dev/tests/workspace-browser.cjs
node dev/tests/chrome-extension.cjs
```

The Python checks need their corresponding optional packages/models. Browser tests need an external Playwright install and its browser binaries. `workspace-browser.cjs` starts a separate helper on port 8766 with a temporary library; it does not change your saved readings. The Chrome extension test uses a disposable Chromium profile. These are development checks, not installation requirements. Windows/Linux helper setup is manual and not verified in this release; Vision OCR and Finder launchers require macOS.

## Reading app UI

`app/reader/src/` contains the React/TypeScript reading workspace. `app/shared/components/ui/` holds shared controls and the attributed glass headline. `npm run build` produces the committed files in `app/reader/dist/`; Finder users do not need Node. Restart the helper after updating, then refresh http://127.0.0.1:8765/. Existing saved readings remain in the same library file.

EPUB import preserves chapter starts as paragraph indices, using EPUB 3 navigation or EPUB 2 NCX labels in spine order. Paragraph indices avoid Python/JavaScript Unicode offset differences; `chapterLayout` maps them to the first speech chunk in each paragraph. The library migrates older databases with an empty chapter list, and backups retain chapter metadata. Previously flattened imports need reimporting. `dev/tests/epub_fixture.py` builds a small EPUB with three chapters, including a percent-encoded fragment and two chapters in one file. Run `node dev/tests/chapters-browser.cjs` (or `BROWSER=chromium` for Chrome) for real-voice chapter selection, playback, save/resume, backup/restore and layout checks against a disposable library on port 8766. Run it separately from `workspace-browser.cjs`, which uses the same port.

`npm run design` runs the same app in an isolated development server at port 4180, using a separate library on its helper at 8767. It is a developer preview of the production source, not a separate design implementation.

## Repository map

| Folder | Contents |
| --- | --- |
| `app/` | Reader, local voice helper, public website and shared UI |
| `extension/` | Ready-to-load Safari/Chrome extension |
| `setup/` | Optional AI, dictation and extra voice launchers |
| `dev/` | Build scripts, tests, article fixtures and tool configuration |
| `docs/` | Additional guides, dependency notices and brand assets |

`build/`, `.local/`, `.venv/`, `.vercel/`, `app/website/dist/` and local launch drafts are ignored. They contain generated packages, local data or deployment state; never commit them.

## Public website

Run `npm run site:dev` to build and preview the static site at http://127.0.0.1:4190/. The page uses a prerecorded Kiki sample and demo; it does not expose the Python helper or accept document uploads. See [website notes](../app/website/README.md) for the asset inventory.

Vercel builds with `npm ci` and `npm run site:build`, serving only `app/website/dist/` as configured in `vercel.json`. Set `SITE_URL` to the production HTTPS origin for canonical and social links, when deploying a fork. Deploy with the official Vercel CLI after signing in; authentication and `.vercel/` stay local. The app and model downloads continue to run on each user's Mac.

## Native mobile

SwiftUI iPhone/iPad and Kotlin/Compose Android previews live in `app/mobile`. See [mobile setup and checks](MOBILE.md) for builds, device setup and current scope. The mobile voice engine runs on the phone and does not use the desktop helper.
