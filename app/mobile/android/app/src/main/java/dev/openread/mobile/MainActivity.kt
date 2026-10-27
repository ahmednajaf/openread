package dev.openread.mobile

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.view.Gravity
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.*
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.File

class MainActivity : ComponentActivity() {
    private val runtime get() = (application as OpenReadApplication).reader
    private val incoming = mutableStateOf<Intent?>(null)
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { runtime.command("play") }
    override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState); enableEdgeToEdge(); incoming.value = intent; setContent { OpenRead() } }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); incoming.value = intent }
    private fun play() {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        else runtime.command("play")
    }
    private fun share(file: File, mime: String) {
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = mime; putExtra(Intent.EXTRA_STREAM, FileProvider.getUriForFile(this@MainActivity, "$packageName.files", file)); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION) }, "Share from OpenRead"))
    }
    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun OpenRead() {
        val dark = isSystemInDarkTheme()
        val colors = if (dark) darkColorScheme(primary = Color(0xFFCBC3FF), background = Color(0xFF13121A), surface = Color(0xFF1D1B25))
            else lightColorScheme(primary = Color(0xFF6251AE), background = Color(0xFFF8F7FC), surface = Color(0xFFF8F7FC))
        MaterialTheme(colorScheme = colors) {
            val state by runtime.state.collectAsStateWithLifecycle(); val library by runtime.library.readings.collectAsStateWithLifecycle()
            val scope = rememberCoroutineScope()
            var reader by rememberSaveable { mutableStateOf(false) }; var settings by rememberSaveable { mutableStateOf(false) }
            var notices by remember { mutableStateOf(false) }
            var paste by remember { mutableStateOf(false) }; var options by remember { mutableStateOf(false) }
            var busy by remember { mutableStateOf<String?>(null) }; var search by rememberSaveable { mutableStateOf("") }
            var scanUri by rememberSaveable { mutableStateOf<String?>(null) }
            var exportJob by remember { mutableStateOf<Job?>(null) }
            fun runImport(task: suspend () -> Reading) { scope.launch { busy = "Opening reading…"; try { runtime.open(task()); reader = true } catch (error: Exception) { runtime.fail(error) } finally { busy = null } } }
            val filePicker = androidx.activity.compose.rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> if (uri != null) runImport { runtime.importer.uri(uri) } }
            val restorePicker = androidx.activity.compose.rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> if (uri != null) scope.launch {
                busy = "Restoring library…"
                try { withContext(Dispatchers.IO) { val backup = File.createTempFile("library-backup-", ".zip", cacheDir); try { contentResolver.openInputStream(uri)?.use { input -> backup.outputStream().use { output -> runtime.importer.copyLimited(input, output, 500L * 1024 * 1024) } } ?: error("This backup could not open."); runtime.library.restore(backup) } finally { backup.delete() } } }
                catch (error: Exception) { runtime.fail(error) } finally { busy = null }
            } }
            val camera = androidx.activity.compose.rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { success ->
                val uri = scanUri?.let(Uri::parse); scanUri = null
                if (success && uri != null) runImport { runtime.importer.uri(uri) }
            }
            LaunchedEffect(incoming.value) {
                val value = incoming.value ?: return@LaunchedEffect; incoming.value = null
                val uri = if (value.action == Intent.ACTION_VIEW) value.data else if (Build.VERSION.SDK_INT >= 33) value.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) else @Suppress("DEPRECATION") value.getParcelableExtra(Intent.EXTRA_STREAM)
                val text = value.getStringExtra(Intent.EXTRA_TEXT)?.trim()
                if (uri != null) runImport { runtime.importer.uri(uri) }
                else if (value.action == Intent.ACTION_SEND && !text.isNullOrBlank()) runImport {
                    if (text.matches(Regex("https://\\S+"))) runtime.importer.web(text)
                    else Reading(title = value.getStringExtra(Intent.EXTRA_SUBJECT)?.take(240) ?: text.lineSequence().first().take(80), text = text).validated()
                }
            }
            Scaffold(containerColor = colors.background, topBar = {
                TopAppBar(title = { Text(if (reader) "Now reading" else "openread.", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold) },
                    navigationIcon = { if (reader) IconButton(onClick = { reader = false; runtime.persistPosition() }) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Library") } },
                    actions = {
                        if (reader) IconButton(onClick = { options = true }) { Icon(Icons.Rounded.MoreHoriz, "Reading options") }
                        IconButton(onClick = { settings = true }) { Icon(Icons.Rounded.Tune, "Settings") }
                    })
            }, bottomBar = {
                if (reader && state.reading != null) ReaderDock(state, onPlay = { if (state.playing || state.preparing) runtime.command("pause") else if (!state.installed) settings = true else play() })
                else if (state.reading != null) Surface(tonalElevation = 3.dp, modifier = Modifier.navigationBarsPadding().fillMaxWidth().clickable { reader = true }) {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) { Text(state.reading!!.title, Modifier.weight(1f), maxLines = 1); IconButton(onClick = { if (state.playing) runtime.command("pause") else if (state.installed) play() else settings = true }) { Icon(if (state.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, "Playback") } }
                }
            }) { padding ->
                if (reader && state.reading != null) Column(Modifier.padding(padding).fillMaxSize()) {
                    Text(state.reading!!.title, Modifier.padding(horizontal = 24.dp, vertical = 12.dp), style = MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Serif)
                    Text("${state.reading!!.wordCount} words · ${runtime.engine.qwen.label(state.voice)}", Modifier.padding(horizontal = 24.dp), color = colors.onSurfaceVariant, style = MaterialTheme.typography.labelMedium)
                    BookChapterControls(state, runtime)
                    NativeReadingText(state, runtime, Modifier.weight(1f).fillMaxWidth())
                } else LazyColumn(Modifier.padding(padding).fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    item {
                        Column(Modifier.padding(top = 24.dp, bottom = 20.dp)) {
                            Text("A LITTLE LESS EFFORT", style = MaterialTheme.typography.labelSmall, letterSpacing = 2.sp, color = colors.onSurfaceVariant)
                            Spacer(Modifier.height(22.dp))
                            Text("Your words.", fontSize = 46.sp, lineHeight = 52.sp, fontFamily = FontFamily.Serif, letterSpacing = (-1.5).sp)
                            Text("Your rhythm.", fontSize = 46.sp, lineHeight = 52.sp, fontFamily = FontFamily.Serif, fontStyle = FontStyle.Italic, letterSpacing = (-1.5).sp, color = colors.primary)
                            Spacer(Modifier.height(18.dp))
                            Text("A natural voice. A little more focus.", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
                        }
                    }
                    item { Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        FilledTonalButton(onClick = { paste = true }, modifier = Modifier.weight(1f)) { Icon(Icons.Rounded.ContentPaste, null); Spacer(Modifier.width(8.dp)); Text("Paste text") }
                        FilledTonalButton(onClick = { filePicker.launch(arrayOf("application/pdf", "application/epub+zip", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "text/*", "image/*")) }, modifier = Modifier.weight(1f)) { Icon(Icons.Rounded.Add, null); Spacer(Modifier.width(8.dp)); Text("Import") }
                    } }
                    item { ElevatedCard(onClick = { runImport { val json = JSONObject(assets.open("odyssey.json").bufferedReader().use { it.readText() }); Reading(id = "odyssey-sample", title = json.getString("title"), text = json.getString("text"), author = json.optString("author")) } }, modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(24.dp)) { Text("PICK UP A CLASSIC", style = MaterialTheme.typography.labelSmall, color = colors.primary); Spacer(Modifier.height(12.dp)); Text("The Odyssey", style = MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Serif); Spacer(Modifier.height(6.dp)); Text("Homer · Book I", color = colors.onSurfaceVariant); Spacer(Modifier.height(18.dp)); Text("Let the words come to you  →", color = colors.primary) }
                    } }
                    item { Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Your library", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                        IconButton(onClick = {
                            if (!state.ocrInstalled) settings = true else {
                                val file = File(cacheDir, "scans").apply { mkdirs() }.resolve("scan-${System.currentTimeMillis()}.jpg")
                                val uri = FileProvider.getUriForFile(this@MainActivity, "$packageName.files", file); scanUri = uri.toString(); camera.launch(uri)
                            }
                        }) { Icon(Icons.Rounded.DocumentScanner, "Scan a page") }
                    } }
                    if (library.isEmpty()) item { Text("Save a reading to pick up where you left off. You can also share text or a document into OpenRead from another app.", color = colors.onSurfaceVariant, modifier = Modifier.padding(vertical = 8.dp)) }
                    else {
                        item { OutlinedTextField(search, { search = it }, label = { Text("Search library") }, modifier = Modifier.fillMaxWidth(), singleLine = true) }
                        items(library.filter { it.title.contains(search, true) || it.text.contains(search, true) }, key = { it.id }) { reading ->
                            ListItem(headlineContent = { Text(reading.title, maxLines = 2) }, supportingContent = { Text("${reading.wordCount} words · ${reading.bookmarks.size} bookmarks") },
                                modifier = Modifier.clickable { runImport { withContext(Dispatchers.IO) { runtime.library.load(reading.id) } } }, trailingContent = { IconButton(onClick = { scope.launch(Dispatchers.IO) { runCatching { runtime.library.remove(reading.id) }.onFailure { runtime.fail(it) } } }) { Icon(Icons.Rounded.DeleteOutline, "Remove from library") } })
                        }
                    }
                    item { Text("On your phone. At your pace.", style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant, modifier = Modifier.padding(vertical = 20.dp)) }
                }
            }
            if (notices) ModalBottomSheet(onDismissRequest = { notices = false }) {
                AndroidView(modifier = Modifier.fillMaxWidth().weight(1f, fill = false).heightIn(max = 600.dp), factory = { context -> ScrollView(context).apply {
                    addView(TextView(context).apply { textSize = 13f; setPadding(24.dpPx(context), 20.dpPx(context), 24.dpPx(context), 32.dpPx(context)); setTextIsSelectable(true); text = context.assets.open("NOTICES.txt").bufferedReader().use { it.readText() }; setTextColor(colors.onSurface.toArgb()) })
                } })
            }
            if (paste) PasteSheet(onDismiss = { paste = false }) { title, text -> paste = false; runImport { Reading(title = title.ifBlank { text.lineSequence().first().take(80) }, text = text).validated() } }
            if (settings) ModalBottomSheet(onDismissRequest = { settings = false }) {
                LazyColumn(Modifier.fillMaxWidth(), contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    item { Text("Make yourself comfortable", style = MaterialTheme.typography.headlineSmall) }
                    item { Text("Natural voices", style = MaterialTheme.typography.titleMedium); Text("Kitten Mini · English · about 83 MB. Download once, then listen offline.", color = colors.onSurfaceVariant) }
                    if (state.downloading) item { LinearProgressIndicator(progress = { state.downloadProgress }, modifier = Modifier.fillMaxWidth()); TextButton(onClick = { runtime.cancelDownload() }) { Text("Cancel download") } }
                    else if (!state.installed) item { Button(onClick = { runtime.setup() }) { Text("Download natural voices") } }
                    else items(KittenEngine.voices.keys.toList()) { voice -> Row(Modifier.fillMaxWidth().clickable { runtime.voice(voice) }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) { RadioButton(selected = state.voice == voice, onClick = { runtime.voice(voice) }); Text(voice) } }
                    item { QwenSettings(state, runtime) }
                    item { HorizontalDivider(); Text("Scan & Listen", style = MaterialTheme.typography.titleMedium); Text("Offline English text recognition for photos and scanned PDFs. About 4 MB.", color = colors.onSurfaceVariant); TextButton(onClick = { runtime.setup(true) }, enabled = !state.downloading && !state.ocrInstalled) { Text(if (state.ocrInstalled) "Installed" else "Download Scan & Listen") } }
                    item { HorizontalDivider(); Text("Your library", style = MaterialTheme.typography.titleMedium); TextButton(onClick = {
                        scope.launch { try { val file = withContext(Dispatchers.IO) { runtime.library.backup() }; share(file, "application/zip") } catch (error: Exception) { runtime.fail(error) } }
                    }) { Text("Export library backup") }; TextButton(onClick = { restorePicker.launch(arrayOf("application/json", "application/zip")) }) { Text("Restore a mobile backup") } }
                    item { TextButton(onClick = { settings = false; notices = true }) { Text("Licences & notices") } }
                    item { Text("No account. No subscription. Your readings stay on this device unless you share or export them.", color = colors.onSurfaceVariant); TextButton(onClick = { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/ahmednajaf/openread"))) }) { Text("Source & contributions") }; TextButton(onClick = { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://ko-fi.com/pickledjones"))) }) { Text("Optional support") } }
                }
            }
            if (options) ModalBottomSheet(onDismissRequest = { options = false }) {
                LazyColumn(contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    item { Text("Reading options", style = MaterialTheme.typography.headlineSmall) }
                    item { Row { TextButton(onClick = { runtime.save() }) { Text("Save reading") }; TextButton(onClick = { runtime.bookmark() }) { Text("Add bookmark") } } }
                    item { Row(verticalAlignment = Alignment.CenterVertically) { Text("Highlight words", Modifier.weight(1f)); Switch(state.highlightWords, { value -> runtime.update { it.copy(highlightWords = value, highlight = null) } }) } }
                    item { Row(verticalAlignment = Alignment.CenterVertically) { Text("Follow along", Modifier.weight(1f)); Switch(state.follow, { value -> runtime.update { it.copy(follow = value) } }) } }
                    item { Text("Sleep timer", style = MaterialTheme.typography.titleMedium); Row { listOf(0, 5, 15, 30).forEach { minutes -> FilterChip(selected = state.sleepMinutes == minutes, onClick = { runtime.sleep(minutes) }, label = { Text(if (minutes == 0) "Off" else "$minutes min") }, modifier = Modifier.padding(end = 6.dp)) } } }
                    items(state.reading?.bookmarks.orEmpty()) { bookmark -> ListItem(headlineContent = { Text(bookmark.label, maxLines = 2) }, modifier = Modifier.clickable { runtime.seek(bookmark.offset); options = false }, trailingContent = { IconButton(onClick = { runtime.removeBookmark(bookmark.offset) }) { Icon(Icons.Rounded.Close, "Remove bookmark") } }) }
                    item { TextButton(onClick = { scope.launch {
                        try { val reading = state.reading ?: return@launch; val file = withContext(Dispatchers.IO) { File(cacheDir, "exports").apply { mkdirs() }.resolve("OpenRead-reading.txt").apply { writeText(reading.title + "\n\n" + reading.text) } }; share(file, "text/plain") }
                        catch (error: Exception) { runtime.fail(error) }
                    } }) { Text("Share text") } }
                    item { TextButton(enabled = state.installed, onClick = {
                        options = false
                        exportJob = scope.launch { busy = "Preparing audio…"; try { val file = runtime.exportAudio { done, total -> busy = "Exporting audio · $done of $total" }; share(file, "audio/wav") } catch (_: CancellationException) {} catch (error: Exception) { runtime.fail(error) } finally { busy = null; exportJob = null } }
                    }) { Text("Export audio · WAV") } }
                    item { TextButton(onClick = { runtime.command("stop"); options = false }) { Text("Stop reading") } }
                }
            }
            if (state.error != null) AlertDialog(onDismissRequest = { runtime.update { it.copy(error = null) } }, title = { Text("OpenRead") }, text = { Text(state.error!!) }, confirmButton = { TextButton(onClick = { runtime.update { it.copy(error = null) } }) { Text("OK") } })
            if (busy != null) AlertDialog(onDismissRequest = {}, title = { Text(busy!!) }, text = { LinearProgressIndicator(Modifier.fillMaxWidth()) }, confirmButton = { if (exportJob != null) TextButton(onClick = { exportJob?.cancel() }) { Text("Cancel") } })
        }
    }
    @Composable private fun ReaderDock(state: ReaderState, onPlay: () -> Unit) {
        Surface(shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp), tonalElevation = 5.dp, shadowElevation = 12.dp) {
            Column(Modifier.navigationBarsPadding().padding(horizontal = 24.dp, vertical = 14.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceEvenly) {
                    IconButton(onClick = { runtime.command("previous") }, enabled = state.index > 0) { Icon(Icons.Rounded.SkipPrevious, "Previous passage") }
                    FilledIconButton(onClick = onPlay, modifier = Modifier.size(64.dp)) { if (state.preparing) CircularProgressIndicator(Modifier.size(24.dp), color = MaterialTheme.colorScheme.onPrimary, strokeWidth = 2.dp) else Icon(if (state.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, if (state.playing) "Pause" else "Listen", Modifier.size(32.dp)) }
                    IconButton(onClick = { runtime.command("next") }, enabled = state.index < runtime.passages.lastIndex) { Icon(Icons.Rounded.SkipNext, "Next passage") }
                }
                Row(verticalAlignment = Alignment.CenterVertically) { Text("Speed", style = MaterialTheme.typography.labelMedium); Slider(state.speed, { runtime.speed(it) }, valueRange = .5f..2f, modifier = Modifier.weight(1f).padding(horizontal = 12.dp)); Text("%.1f×".format(state.speed), style = MaterialTheme.typography.labelMedium) }
                Text(state.status, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.align(Alignment.CenterHorizontally))
            }
        }
    }
    @Composable private fun NativeReadingText(state: ReaderState, runtime: ReaderRuntime, modifier: Modifier) {
        val foreground = MaterialTheme.colorScheme.onSurface.toArgb(); val highlight = MaterialTheme.colorScheme.primaryContainer.toArgb()
        AndroidView(modifier = modifier, factory = { context -> ScrollView(context).apply {
            isFillViewport = true; clipToPadding = false
            addView(TextView(context).apply { tag = "reading-text"; textSize = 21f; typeface = android.graphics.Typeface.create("serif", android.graphics.Typeface.NORMAL); setLineSpacing(10f, 1.12f); setPadding(24.dpPx(context), 24.dpPx(context), 24.dpPx(context), 40.dpPx(context)); setTextIsSelectable(true) })
        } }, update = { scroll ->
            val text = scroll.getChildAt(0) as TextView; val reading = state.reading ?: return@AndroidView; val offset = state.highlight?.start ?: runtime.passages.getOrNull(state.index)?.start ?: 0; val window = runtime.textWindow(); val source = reading.text.substring(window.start, window.end)
            if (text.text.toString() != source) { text.setText(source, TextView.BufferType.SPANNABLE); scroll.scrollTo(0, 0) }
            text.setTextColor(foreground)
            if (text.text !is android.text.Spannable) text.setText(source, TextView.BufferType.SPANNABLE)
            val spannable = text.text as android.text.Spannable
            spannable.getSpans(0, spannable.length, BackgroundColorSpan::class.java).forEach { spannable.removeSpan(it) }
            state.highlight?.let { WordRange(it.start - window.start, it.end - window.start) }?.takeIf { it.start >= 0 && it.end <= spannable.length }?.let { range ->
                spannable.setSpan(BackgroundColorSpan(highlight), range.start, range.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                if (state.follow) text.layout?.let { layout -> val y = layout.getLineTop(layout.getLineForOffset(range.start)) + text.paddingTop
                    if (y < scroll.scrollY + 40 || y > scroll.scrollY + scroll.height - 80) scroll.post { scroll.smoothScrollTo(0, (y - scroll.height / 3).coerceAtLeast(0)) }
                }
            }
        })
    }
    private fun Int.dpPx(context: android.content.Context) = (this * context.resources.displayMetrics.density).toInt()
    @OptIn(ExperimentalMaterial3Api::class)
    @Composable private fun PasteSheet(onDismiss: () -> Unit, onOpen: (String, String) -> Unit) {
        var title by remember { mutableStateOf("") }; var text by remember { mutableStateOf("") }
        ModalBottomSheet(onDismissRequest = onDismiss, modifier = Modifier.imePadding()) {
            Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Something worth listening to", style = MaterialTheme.typography.headlineSmall)
                OutlinedTextField(title, { title = it.take(240) }, label = { Text("Title · optional") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(text, { if (it.length <= 20_000_000) text = it }, label = { Text("Paste your text") }, modifier = Modifier.fillMaxWidth().heightIn(min = 150.dp, max = 300.dp))
                Button(onClick = { onOpen(title, text) }, enabled = text.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text("Open reading") }
            }
        }
    }
}
