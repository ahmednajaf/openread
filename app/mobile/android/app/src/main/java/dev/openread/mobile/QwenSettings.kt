package dev.openread.mobile

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable fun QwenSettings(state: ReaderState, runtime: ReaderRuntime) {
    var name by remember { mutableStateOf("") }; var transcript by remember { mutableStateOf("") }; var permission by remember { mutableStateOf(false) }; var sample by remember { mutableStateOf<Uri?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { sample = it }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        HorizontalDivider(); Text("Qwen · optional voice packs", style = MaterialTheme.typography.titleMedium)
        Text("Richer narration, generated on this device. Larger packs use more storage, memory and battery. Kitten stays available for quick reading.", style = MaterialTheme.typography.bodySmall)
        if (!state.qwenExpressive) TextButton(onClick = { runtime.setupQwen("expressive") }, enabled = !state.downloading) { Text("Download expressive voices · up to 1.44 GB") }
        if (!state.qwenCloning) TextButton(onClick = { runtime.setupQwen("clone") }, enabled = !state.downloading) { Text("Download voice cloning · up to 884 MB") }
        if (state.qwenExpressive) {
            QwenEngine.speakers.forEach { speaker -> Row(Modifier.fillMaxWidth().clickable { runtime.voice("qwen:$speaker") }, verticalAlignment = Alignment.CenterVertically) { RadioButton(selected = state.voice == "qwen:$speaker", onClick = { runtime.voice("qwen:$speaker") }); Text(runtime.engine.qwen.label("qwen:$speaker")) } }
            OutlinedTextField(state.direction, { runtime.direction(it) }, label = { Text("Voice direction") }, placeholder = { Text("Warm, unhurried storytelling") }, modifier = Modifier.fillMaxWidth())
            Text("Direction applies to Qwen's expressive voices. Word highlighting is estimated.", style = MaterialTheme.typography.bodySmall)
        }
        if (state.qwenCloning) {
            Text("Your voices", style = MaterialTheme.typography.titleMedium)
            state.personalVoices.forEach { voice -> Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { runtime.voice("qwen:clone:${voice.id}") }, modifier = Modifier.weight(1f)) { Text(voice.name + if (state.voice == "qwen:clone:${voice.id}") " ✓" else "") }
                IconButton(onClick = { runtime.removeVoice(voice.id) }) { Icon(Icons.Rounded.DeleteOutline, "Delete ${voice.name}") }
            } }
            OutlinedTextField(name, { name = it.take(80) }, label = { Text("Name your voice") }, modifier = Modifier.fillMaxWidth())
            TextButton(onClick = { picker.launch(arrayOf("audio/*")) }) { Text(if (sample == null) "Choose a 3–30 second voice sample" else "Voice sample selected ✓") }
            OutlinedTextField(transcript, { transcript = it.take(2000) }, label = { Text("Optional transcript · closer delivery, slower") }, minLines = 2, modifier = Modifier.fillMaxWidth())
            Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(permission, { permission = it }); Text("This is my voice, or I have permission to clone it", style = MaterialTheme.typography.bodySmall) }
            Text("Leave the transcript blank for faster reading. Add the exact words for closer reference delivery, which takes longer. Use clear speech without music. Samples and voice profiles stay on this device; the original sample is discarded after preparation.", style = MaterialTheme.typography.bodySmall)
            Button(onClick = { sample?.let { runtime.cloneVoice(name, transcript, it, permission) } }, enabled = !state.downloading && sample != null && name.isNotBlank() && permission) { Text("Create personal voice") }
        }
    }
}

@Composable fun BookChapterControls(state: ReaderState, runtime: ReaderRuntime) {
    val reading = state.reading ?: return
    if (reading.textLength > 64000) {
        val offset = state.highlight?.start ?: runtime.passages.getOrNull(state.index)?.start ?: 0
        val window = runtime.textWindow()
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton(onClick = { runtime.seekTextWindow(-1) }, enabled = window.start > 0) { Text("Earlier text") }
            TextButton(onClick = { runtime.seekTextWindow(1) }, enabled = window.end < reading.textLength) { Text("More text") }
        }
    }
    if (reading.chapters.isEmpty()) return
    var open by remember { mutableStateOf(false) }
    val offset = state.highlight?.start ?: runtime.passages.getOrNull(state.index)?.start ?: 0
    val active = reading.chapters.indexOfLast { it.offset <= offset }.coerceAtLeast(0)
    Row(Modifier.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { runtime.seek(reading.chapters[active - 1].offset) }, enabled = active > 0) { Icon(Icons.Rounded.ChevronLeft, "Previous chapter") }
        TextButton(onClick = { open = true }, modifier = Modifier.weight(1f)) { Text(reading.chapters[active].title, maxLines = 2) }
        IconButton(onClick = { runtime.seek(reading.chapters[active + 1].offset) }, enabled = active + 1 < reading.chapters.size) { Icon(Icons.Rounded.ChevronRight, "Next chapter") }
    }
    if (open) AlertDialog(onDismissRequest = { open = false }, title = { Text("Contents") }, text = {
        androidx.compose.foundation.lazy.LazyColumn(Modifier.heightIn(max = 450.dp)) { items(reading.chapters.size) { index ->
            TextButton(onClick = { runtime.seek(reading.chapters[index].offset); open = false }, modifier = Modifier.fillMaxWidth()) { Text(reading.chapters[index].title + if (index == active) " ✓" else "", modifier = Modifier.fillMaxWidth()) }
        } }
    }, confirmButton = { TextButton(onClick = { open = false }) { Text("Done") } })
}
