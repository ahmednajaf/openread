package dev.openread.mobile

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.nio.ByteOrder

/** Decode a short user-selected sample with Android's codecs; never upload it. */
object VoiceSample {
    fun read(context: Context, uri: Uri): FloatArray {
        context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { require(it.length < 0 || it.length <= 20L * 1024 * 1024) { "Choose a sample under 20 MB." } }
        val extractor = MediaExtractor(); var codec: MediaCodec? = null
        try {
            extractor.setDataSource(context, uri, null)
            val track = (0 until extractor.trackCount).firstOrNull { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME).orEmpty().startsWith("audio/") } ?: error("Choose an audio sample.")
            extractor.selectTrack(track); val format = extractor.getTrackFormat(track)
            val declaredDuration = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) / 1_000_000.0 else 0.0
            require(declaredDuration == 0.0 || declaredDuration in 3.0..30.0) { "Choose a voice sample between 3 and 30 seconds." }
            val mime = requireNotNull(format.getString(MediaFormat.KEY_MIME))
            codec = MediaCodec.createDecoderByType(mime); codec.configure(format, null, null, 0); codec.start()
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE); var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var encoding = AudioFormat.ENCODING_PCM_16BIT; val samples = ArrayList<Float>(); val info = MediaCodec.BufferInfo()
            var ended = false; var finished = false; val deadline = System.nanoTime() + 60_000_000_000L
            while (!finished) {
                require(System.nanoTime() < deadline) { "The audio sample could not be decoded." }
                if (!ended) {
                    val index = codec.dequeueInputBuffer(10_000)
                    if (index >= 0) { val input = requireNotNull(codec.getInputBuffer(index)); val count = extractor.readSampleData(input, 0)
                        if (count < 0) { codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); ended = true }
                        else { codec.queueInputBuffer(index, 0, count, extractor.sampleTime, 0); extractor.advance() }
                    }
                }
                when (val index = codec.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { val output = codec.outputFormat; rate = output.getInteger(MediaFormat.KEY_SAMPLE_RATE); channels = output.getInteger(MediaFormat.KEY_CHANNEL_COUNT); encoding = if (output.containsKey(MediaFormat.KEY_PCM_ENCODING)) output.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT }
                    else -> if (index >= 0) {
                        val output = requireNotNull(codec.getOutputBuffer(index)).order(ByteOrder.LITTLE_ENDIAN); output.position(info.offset); output.limit(info.offset + info.size)
                        require(rate in 8000..192000 && channels in 1..8 && encoding in listOf(AudioFormat.ENCODING_PCM_16BIT, AudioFormat.ENCODING_PCM_FLOAT)) { "This audio format is not supported." }
                        val width = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
                        while (output.remaining() >= channels * width) { var mono = 0f; repeat(channels) { mono += if (width == 4) output.float else output.short / 32768f }; samples.add(mono / channels); require(samples.size <= rate * 30) { "Choose a sample under 30 seconds." } }
                        codec.releaseOutputBuffer(index, false); finished = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    }
                }
            }
            require(samples.size / rate.toDouble() in 3.0..30.0) { "Choose a sample between 3 and 30 seconds." }
            return FloatArray((samples.size.toLong() * 24000 / rate).toInt()) { index -> val position = index.toDouble() * rate / 24000.0; val lower = position.toInt().coerceAtMost(samples.lastIndex); val upper = (lower + 1).coerceAtMost(samples.lastIndex); samples[lower] + (samples[upper] - samples[lower]) * (position - lower).toFloat() }
        } finally { runCatching { codec?.stop() }; codec?.release(); extractor.release() }
    }
}
