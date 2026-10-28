# Voice packs and books

Kitten Mini is the small, fast default: eight English voices, downloaded once.
Kokoro adds 41 presets across English (American/British), Spanish, French, Hindi,
Italian and Brazilian Portuguese. Choose a voice matching the text's language.
Both engines use model duration outputs for highlighting. Neither offers a
prompt-based emotion or cloning control in the currently shipped runtime.

On iPhone and Mac, download packs in OpenRead Settings. Kokoro is about 192 MB;
its prepared Safari cache brings installed use to about 360 MB. The Mac browser
helper installs the packs through Set Up OpenRead.command. Reading and synthesis
stay on your device. Existing Qwen downloads and saved personal voice files are
left untouched, but its experimental Apple/web controls have been removed.
Android's paused source still contains its earlier Qwen integration.

Kitten TTS 2 is a separate model under local evaluation, with more voices,
cloning and expression. It is not part of these shipped packs. See the
[evaluation and native-port status](KITTEN2-EVALUATION.md).

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
iPhone (Android development is paused). Existing small JSON backups remain readable. Desktop library
backups use their existing format. Audio exports are generated a passage at a time
and remain limited by WAV/file size; a complete audiobook can take a long time.

Exact source revisions, checksums and licences are in the shared model manifest,
[third-party inventory](../THIRD_PARTY.md), and bundled native notices.

## Continuous listening

The Apple apps generate into one audio queue across passages. Speed changes
consume the same audio and source timings faster or slower; they do not restart
synthesis. Safari and Chrome prepare the following passage while the current
one plays. A slow device can still buffer if it cannot generate at the chosen
listening speed. No cloud fallback is used.
