# Optional Qwen voices and full books

Kitten remains the small, quick default. Qwen is an optional local engine for
richer preset voices and personal voice cloning. No API key or subscription is
needed. Downloads go directly to your device; reading text and samples stay local.

## iPhone, iPad, Android and Mac apps

Open Settings → **Qwen voice packs**. Download the pack you want, then choose a
Qwen voice in the reader. The app generates speech on that device; it does not
connect to a Mac helper. Keep the app open for the initial download and first use.

- **Expressive voices:** about 1.44 GB, including the shared audio codec. Try Ryan
  or Aiden for English narration. Voice direction accepts a short description such
  as “Warm, unhurried storytelling, with thoughtful pauses.”
- **Personal voice cloning:** about 884 MB, including the shared codec. Both packs
  together use about 2.07 GB because the codec is shared.

Qwen needs considerably more memory and processing time than Kitten. The app
checks available memory before loading it. Native Apple apps use Metal acceleration
with precompiled shaders and a CPU fallback; the existing voice packs still work.
Speed depends on the device and
long books can drain the battery. Choose Kitten when a phone cannot load Qwen or generate it quickly enough.
These are optional experimental voices, not a guarantee of real-time performance
on every supported phone. Safari's separate, memory-limited extension continues
to use Kitten; save a webpage to the full app to use Qwen.

## Desktop browser workspace

Start OpenRead, open the voice panel, and expand **Qwen voice packs**. Choose a
pack and follow its progress. The first setup compiles the included CPU engine
and needs Apple's Command Line Tools/Xcode. Alternatively, double-click
`setup/Set Up Qwen Voices.command`. Restart an older helper after updating.
Downloaded models stay in `.local/qwen-models`; no model weights are part of Git.
The browser workspace can use Qwen through this local helper. The signed Safari
extension uses its own native Kitten engine.

## Create a personal voice

1. Download the cloning pack.
2. Import a clear **3–30 second audio sample** under **20 MB**, without music or
   other speakers. Use your own voice or a voice you have permission to clone.
3. Name it and confirm that permission. Leave the transcript blank for the faster
   voice-identity mode, or add the exact spoken words to follow the reference
   delivery more closely. Reference-delivery mode takes substantially longer.
4. Create the voice, then select it in the reader. Delete it in Settings when done.

The original imported sample is discarded after preparation. Derived speaker
embeddings or reference prompts remain locally with the voice's name and optional
transcript. They are sensitive voice data: they are not included in library
backups or automatically transferred between devices. Uninstalling may remove
them. Cloned voices do not support the preset voices' style-direction control.
The current integration synthesizes English; pronunciation and cloning quality
vary. Qwen word highlighting estimates timing rather than providing exact alignment.

## Import a complete book

Choose Import and select a DRM-free EPUB, PDF, DOCX, HTML or text file. The apps
accept files up to **100 MB** and **20 million text characters**, rather than
requiring the book to fit a short excerpt. EPUB 3 navigation and EPUB 2 NCX contents
become a chapter picker, with previous/next controls. Books without a contents
list use document headings. Inline links retain their readable words, and lists
stay in order. DRM is not removed.

Save to the library to preserve chapters, bookmarks and your place. The native
apps keep text in bounded files and load one book at a time; progress updates
write only metadata. The native reader displays bounded sections of long chapters
while playback continues across the complete book. Use Earlier text/More text to
browse those sections. Importing again is necessary for older books saved without
chapter information.

PDFs can contain up to 2,000 pages; OCR remains limited to 20 scanned pages per
import. EPUB expansion is limited to 200 MB/10,000 archive entries. Native library
ZIP backups support up to 200 readings and 500 MB total, and can be restored on
iPhone or Android. Existing small JSON backups remain readable. Desktop library
backups use their existing format. Audio exports are generated a passage at a time
and remain limited by WAV/file size; a complete audiobook can take a long time.

Exact source revisions, checksums and licences are in the shared model manifest,
[third-party inventory](../THIRD_PARTY.md), and bundled native notices.

## Smooth listening at higher speeds

Apple apps keep Qwen audio on one queue across passages. Increasing speed consumes
that audio faster; a phone generating 1.5 seconds of speech per second cannot
sustain 2× listening indefinitely from an empty queue.

In reading options, choose **Prepare 10 minutes ahead** (also available in the Mac
reader). Keep the app open while it prepares, then tap Play. This uses the selected
voice, direction and listening speed, stopping at the end of the reading if sooner.
It does not silently slow playback or switch voices. Preparation can be cancelled.
Generated audio and approximate word timing are cached locally, up to 512 MB;
older audio may be regenerated, and the OS may clear the cache. Changing text,
voice or direction uses a different cache entry. Removing a personal voice also
removes its prepared audio. No extra model or cloud service is involved.
