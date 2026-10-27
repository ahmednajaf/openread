# OpenRead on your phone

Native previews are in this repository: **SwiftUI for iPhone/iPad** and **Kotlin + Jetpack Compose for Android**. They run Kitten Mini directly on the device, with optional Qwen expressive and personal voice packs. You do not need the Mac helper, an account or a subscription.

These are developer previews, not App Store or Play Store releases. The updated voice engine has been tested on a physical iPhone. Store release preparation and wider device testing are ongoing.

## What you can use

- Eight English Kitten voices, with a one-time download of about 83 MB.
- Optional Qwen preset voices, style direction and local voice cloning. See [voice pack setup](VOICE_PACKS.md).
- A reader with word highlighting, follow-along scrolling, passage controls and 0.5–2× speed.
- A saved library, reading positions, bookmarks and a sleep timer.
- PDF, EPUB, DOCX, HTML, text and image imports. Scanned PDFs and photos use on-device OCR. Android's English scanner is a separate, optional 4 MB download.
- Background audio and system media controls.
- Text and WAV exports, plus portable iPhone/Android library backups.
- Android's **Share → OpenRead**, plus share and Safari extensions in the full Apple build.

Appearance follows your phone. iOS 26 uses SwiftUI's native glass material; iOS 17–25 use Apple's system material. Android uses native Material 3 controls.

Mobile currently focuses on reading. The desktop's optional AI summaries, podcasts, dictation and automatic WhatsApp Web chat extraction have **not** been ported. To listen to a message on a phone, copy or share its text into OpenRead. The apps cannot inspect other apps or read their conversations automatically.

## Try it on iPhone or iPad

You need a Mac with **Xcode 26 or later** and an iPhone/iPad running **iOS 17 or later**. The checked-in Xcode project opens directly; Node, Python and XcodeGen are not needed to build it.

1. Download this repository and open `app/mobile/ios/OpenRead.xcodeproj` in Xcode. Allow its pinned Swift packages to finish loading.
2. Select the **OpenReadPersonal** scheme for a free Apple account. This build supports paste, file import, OCR and the reader; it leaves out the share/Safari extensions and App Groups.
3. Connect your phone, select it as the destination, then select your Personal Team under **Signing & Capabilities** for the OpenReadPersonal target. Give it a unique bundle identifier if Xcode asks.
4. Press **Run**. Follow Apple's device trust/Developer Mode prompts on your phone, if shown.
5. In OpenRead, open **Settings → Download voices**, then try **The Odyssey** or paste your own text.

Apple's free personal provisioning expires after seven days; reopen Xcode and run the app again to renew it. See [Apple's account guide](https://developer.apple.com/help/account/basics/about-your-developer-account). App Store/TestFlight distribution is a separate Apple Developer Program process.

For the **full iOS share and Safari extensions**, use the OpenRead scheme with a development team that supports App Groups. Configure unique `OPENREAD_BUNDLE_ID` and `OPENREAD_APP_GROUP` values in the project's build settings, assign the same team to OpenRead, OpenReadShare and OpenReadSafari, and register/enable that group for all three targets. The entitlement files and runtime container use that single group setting. Share-sheet handoff has been checked on a signed physical iPhone.

The personal and full builds have separate libraries. Export a mobile library backup before switching between them.

## Safari on iPhone and Mac

The full Apple builds include OpenRead's toolbar extension. Download voices in
the containing app first; Safari and the app share that download through their
App Group. Chrome's separate desktop helper is not used by this native variant.

On iPhone, enable OpenRead under **Settings → Apps → Safari → Extensions**,
including your Safari profile. Open an article, select OpenRead in Safari's
page menu, and look for the **openread.** panel with the Kiki voice selector.
Safari's own Listen to Page action is a separate Apple feature. If prompted,
tap **Start listening** on the webpage to allow audio playback.

On Mac, open `app/apple/OpenReadMac.xcodeproj`, choose your developer team and
run the OpenReadMac scheme. Download voices in that app, then enable its
extension in Safari Settings. Use the same bundle identifier/App Group settings
for both Mac targets. A signed development build is not an App Store release.

The iPhone Safari voice transport is still being checked on hardware; if it
fails, save the page to the native app to listen. The Mac extension has played
the Odyssey article with its native engine. Word timings remain approximate.

## Try it on Android

You need a **64-bit Android phone (Android 8 or later)**, plus a computer with Android Studio to build this preview. No Google account or Play Store registration is required for a local debug build.

1. Open `app/mobile/android` in Android Studio and let Gradle sync.
2. If prompted, review/install **Android SDK 35**, **Build Tools 35.0.0**, **NDK 27.2.12479018** and **CMake 3.22.1** through SDK Manager. Use JDK 17 or 21 for Gradle (tested with 21); select it under Android Studio’s Gradle JDK setting if needed.
3. Connect your phone with USB debugging enabled, select it and press **Run**. Alternatively, choose **Build APK(s)** and transfer the resulting APK to your phone. Review Android's installation prompt yourself.
4. Open **Settings → Download natural voices**. For photos or scanned PDFs, also download **Scan & Listen**.
5. Try the Odyssey sample, import a file or select OpenRead in another app's share menu.

The local APK is `app/build/outputs/apk/debug/app-debug.apk` inside the Android project. It is a debug build, not a signed store release. Keep signing keys and `local.properties` out of Git.

## Everyday use

**Bring something in:** paste text, use Import, or share a document into the app. A website link is fetched only when you choose to import/share that link; sites requiring login may need selected text instead. The iOS share extension saves into the library; open OpenRead afterwards to listen.

**Keep it:** choose Save in Reading options. Readings stay on that device. Export a library backup before changing phones or uninstalling. Restore merges and validates the whole backup before writing; matching IDs replace their saved entries. Mobile backups work between these two native apps, not the desktop library format.

**Listen offline:** after the model download, speech and scanning run on the phone. Voice files come from pinned upstream URLs with SHA-256 verification. Apple apps also prepare an approximately 80 MB local runtime cache so Safari can map the weights without duplicate copies. Your reading text is not sent to the model host. Download hosts receive the usual request/IP information during setup; imported website hosts receive your request when you open a link.

**Full books:** import a complete DRM-free EPUB and use its chapter picker. The apps accept files up to 100 MB and 20 million text characters, with 2,000 PDF pages (20 scanned pages per OCR import). Libraries hold up to 200 readings; ZIP backups are bounded at 500 MB. Native text is stored in chunks and displayed in bounded sections, while playback follows the whole book. Word timing remains approximate. See [voice packs and book limits](VOICE_PACKS.md) for details.

## Development checks

From the repository root, on a Mac with an installed iOS simulator:

```sh
xcodebuild -project app/mobile/ios/OpenRead.xcodeproj \
  -scheme OpenRead -destination 'platform=iOS Simulator,name=YOUR_SIMULATOR' \
  CODE_SIGNING_ALLOWED=NO test
```

Android, with an installed SDK and JDK:

```sh
cd app/mobile/android
./gradlew :app:assembleDebug :app:testDebugUnitTest
./gradlew :app:connectedDebugAndroidTest
```

The core tests cover exact Unicode ranges, repeated words, passage ordering and atomic backup validation. Device/simulator tests cover article links and lists, EPUB spine order, DOCX paragraphs, rejected external XML entities, local voice generation, WAV exports audio playback and offline OCR. Voice/OCR tests explicitly skip when their model files are absent. Install the voice pack in the test app first to exercise inference; tests never silently download it.

After changing shared extension files, run `node dev/scripts/build-apple-extension.cjs`. The generated Safari resources are committed for Xcode-only builds. If editing `project.yml`, regenerate the checked-in Xcode project with XcodeGen 2.46.0. Android's wrapper pins Gradle 8.11.1 and its distribution checksum. Android ONNX Runtime is pinned to 1.24.3 to avoid the CPU-detection crash observed with 1.24.2 on the ARM emulator.

Native sources are under `app/mobile/ios` and `app/mobile/android`. Shared model pins, test fixtures, the Odyssey sample and the attributed pronunciation engine live in `app/mobile/shared`. See [mobile notices](../app/mobile/shared/NOTICES.txt) and [third-party inventory](../THIRD_PARTY.md).
