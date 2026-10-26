package dev.openread.mobile

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import com.googlecode.tesseract.android.TessBaseAPI
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.jsoup.Jsoup
import org.w3c.dom.Document
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipFile
import javax.xml.parsers.DocumentBuilderFactory

class DocumentImporter(private val context: Context, private val models: ModelStore) {
    init { PDFBoxResourceLoader.init(context) }
    suspend fun uri(uri: Uri): Reading = withContext(Dispatchers.IO) {
        val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        } ?: "Shared reading"
        val mime = context.contentResolver.getType(uri).orEmpty()
        val extension = name.substringAfterLast('.', "").lowercase().ifEmpty { when {
            mime.contains("pdf") -> "pdf"; mime.contains("epub") -> "epub"; mime.contains("wordprocessingml") -> "docx"
            mime.contains("html") -> "html"; mime.startsWith("image/") -> "jpg"; else -> "txt"
        } }
        val temporary = File.createTempFile("reading-", ".$extension", context.cacheDir)
        try {
            context.contentResolver.openInputStream(uri)?.use { input -> temporary.writeBytes(limited(input, 20 * 1024 * 1024)) }
                ?: error("This file could not be opened. Try sharing it again.")
            file(temporary, name.substringBeforeLast('.'))
        } finally { temporary.delete() }
    }
    fun file(file: File, title: String = file.nameWithoutExtension): Reading {
        require(file.length() <= 20 * 1024 * 1024) { "Choose a file under 20 MB." }
        val text = when (file.extension.lowercase()) {
            "pdf" -> pdf(file)
            "epub" -> epub(file)
            "docx" -> docx(file)
            "html", "htm" -> html(file.readText()).second
            "jpg", "jpeg", "png", "webp", "heic" -> {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }; BitmapFactory.decodeFile(file.path, bounds)
                val options = BitmapFactory.Options().apply { inSampleSize = (maxOf(bounds.outWidth, bounds.outHeight) / 2600).coerceAtLeast(1) }
                val image = requireNotNull(BitmapFactory.decodeFile(file.path, options)) { "This image could not be opened." }
                try { recognize(image) } finally { image.recycle() }
            }
            else -> file.readText()
        }
        require(text.isNotBlank()) { "No readable text was found. For scanned pages, download Scan & Listen in Settings." }
        return Reading(title = title.take(240).ifBlank { "Untitled" }, text = text).validated()
    }
    suspend fun web(link: String): Reading = withContext(Dispatchers.IO) {
        val url = URL(link.trim()); require(url.protocol == "https") { "Use an https website address." }
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 20_000; connection.readTimeout = 25_000
        try {
            require(connection.responseCode == 200 && connection.url.protocol == "https") { "This page could not be opened. Share selected text instead." }
            require(connection.contentType.orEmpty().contains("text/html")) { "Share the document file instead of its link." }
            val document = html(connection.inputStream.use { limited(it, 5 * 1024 * 1024) }.toString(Charsets.UTF_8))
            Reading(title = document.first.take(240), text = document.second, source = connection.url.toString().take(1000)).validated()
        } finally { connection.disconnect() }
    }
    internal fun html(source: String): Pair<String, String> {
        val document = Jsoup.parse(source)
        document.select("script,style,nav,aside,footer,header,form,button,input,select,textarea,[hidden],[aria-hidden=true],.reading-time,.read-time,.byline,.advertisement,[role=navigation]").remove()
        val root = document.selectFirst("article") ?: document.selectFirst("main") ?: document.body()
        val title = root.selectFirst("h1")?.text() ?: document.title().ifBlank { "Shared page" }
        root.select("p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,br").forEach { it.appendText("\n\n") }
        val text = root.wholeText().replace(Regex("[ \\t]+"), " ").replace(Regex("\\n[ \\t]+"), "\n").replace(Regex("\\n{3,}"), "\n\n").trim()
        return title to text
    }
    private fun pdf(file: File): String {
        val pages = PDDocument.load(file).use { document ->
            require(document.numberOfPages <= 200) { "Choose a PDF with at most 200 pages." }
            List(document.numberOfPages) { index -> PDFTextStripper().apply { startPage = index + 1; endPage = index + 1; sortByPosition = true }.getText(document).trim() }
        }.toMutableList()
        val scanned = pages.indices.filter { pages[it].isBlank() }
        if (scanned.isNotEmpty()) {
            require(scanned.size <= 20) { "Import at most 20 scanned pages at a time." }
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor -> PdfRenderer(descriptor).use { renderer ->
                scanned.forEach { index -> renderer.openPage(index).use { page ->
                    val scale = minOf(2f, 2400f / maxOf(page.width, page.height))
                    val image = Bitmap.createBitmap((page.width * scale).toInt().coerceAtLeast(1), (page.height * scale).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
                    try { image.eraseColor(android.graphics.Color.WHITE); page.render(image, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY); pages[index] = recognize(image) } finally { image.recycle() }
                } }
            } }
        }
        return pages.joinToString("\n\n")
    }
    private fun recognize(bitmap: Bitmap): String {
        require(models.installed(ocr = true)) { "Download Scan & Listen in Settings first. It works offline after setup." }
        val api = TessBaseAPI()
        try {
            check(api.init(models.root.path, "eng")) { "The text scanner could not start. Re-download Scan & Listen." }
            api.setImage(bitmap); return api.utF8Text.orEmpty().trim()
        } finally { api.recycle() }
    }
    private fun xml(data: ByteArray): Document {
        // Android's XML implementation does not support Xerces' disallow-doctype feature.
        // Decode explicitly, reject DTDs before parsing, and refuse any external resolution.
        val source = data.toString(Charsets.UTF_8)
        require(!source.contains("<!DOCTYPE", ignoreCase = true) && !source.contains('\u0000')) { "This document uses an unsupported XML format." }
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true; isExpandEntityReferences = false }
        val builder = factory.newDocumentBuilder()
        builder.setEntityResolver { _, _ -> throw org.xml.sax.SAXException("External document references are not supported.") }
        return builder.parse(org.xml.sax.InputSource(java.io.StringReader(source)))
    }

    private fun entry(zip: ZipFile, path: String): ByteArray {
        val item = requireNotNull(zip.getEntry(path)) { "The document is incomplete or encrypted." }
        require(!item.isDirectory && item.size in 0..20_000_000) { "This document is too large." }
        return zip.getInputStream(item).use { limited(it, 20 * 1024 * 1024) }
    }
    private fun docx(file: File): String = ZipFile(file).use { zip ->
        val document = xml(entry(zip, "word/document.xml")); val paragraphs = document.getElementsByTagNameNS("*", "p")
        (0 until paragraphs.length).joinToString("\n\n") { index ->
            val text = StringBuilder()
            fun collect(node: org.w3c.dom.Node) {
                when (node.localName) { "t" -> text.append(node.textContent); "tab" -> text.append('\t'); "br" -> text.append('\n')
                    else -> for (i in 0 until node.childNodes.length) collect(node.childNodes.item(i)) }
            }
            collect(paragraphs.item(index)); text.toString()
        }
    }
    private fun epub(file: File): String = ZipFile(file).use { zip ->
        val container = xml(entry(zip, "META-INF/container.xml"))
        val opf = (container.getElementsByTagNameNS("*", "rootfile").item(0) as? org.w3c.dom.Element)?.getAttribute("full-path") ?: error("This EPUB has no reading order.")
        val base = opf.substringBeforeLast('/', "")
        val document = xml(entry(zip, safePath("", opf)))
        val items = document.getElementsByTagNameNS("*", "item")
        val manifest = (0 until items.length).associate { index -> (items.item(index) as org.w3c.dom.Element).let { it.getAttribute("id") to it.getAttribute("href") } }
        val spine = document.getElementsByTagNameNS("*", "itemref")
        require(spine.length in 1..500) { "This EPUB has an unsupported reading order." }
        val output = StringBuilder()
        for (index in 0 until spine.length) {
            val id = (spine.item(index) as org.w3c.dom.Element).getAttribute("idref")
            val path = safePath(base, java.net.URLDecoder.decode(manifest[id] ?: error("An EPUB chapter is missing."), "UTF-8"))
            output.append(html(entry(zip, path).toString(Charsets.UTF_8)).second).append("\n\n")
            require(output.length <= 250_000) { "Import a shorter book or an excerpt under 250,000 characters." }
        }
        output.toString().trim()
    }
    private fun safePath(base: String, relative: String): String {
        require(!relative.contains(':') && !relative.startsWith('/') && !relative.contains('\\')) { "This EPUB contains an invalid chapter path." }
        val parts = mutableListOf<String>()
        "$base/$relative".substringBefore('#').split('/').forEach { when (it) { "", "." -> {}; ".." -> { require(parts.isNotEmpty()); parts.removeAt(parts.lastIndex) }; else -> parts.add(it) } }
        return parts.joinToString("/")
    }
    internal fun limited(input: InputStream, maximum: Int): ByteArray {
        val output = java.io.ByteArrayOutputStream(); val buffer = ByteArray(64 * 1024)
        while (true) { val count = input.read(buffer); if (count < 0) break; require(output.size() + count <= maximum) { "Choose a smaller document." }; output.write(buffer, 0, count) }
        return output.toByteArray()
    }
}
