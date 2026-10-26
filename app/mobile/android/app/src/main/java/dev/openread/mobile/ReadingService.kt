package dev.openread.mobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import kotlinx.coroutines.*
import java.io.File
import java.util.UUID

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class ReadingService : MediaSessionService() {
    private lateinit var runtime: ReaderRuntime
    private lateinit var player: ExoPlayer
    private var session: MediaSession? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var generation: Job? = null
    private var token = UUID.randomUUID()
    private var loadedKey: String? = null
    private var clip: SpokenClip? = null
    private var currentFile: File? = null
    override fun onCreate() {
        super.onCreate(); runtime = (application as OpenReadApplication).reader; runtime.service = this
        player = ExoPlayer.Builder(this).build().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_SPEECH).build(), true)
            setHandleAudioBecomingNoisy(true); setWakeMode(C.WAKE_MODE_LOCAL)
            addListener(object : Player.Listener {
                override fun onIsPlayingChanged(isPlaying: Boolean) { runtime.update { it.copy(playing = isPlaying, highlight = if (isPlaying) it.highlight else null) } }
                override fun onPlaybackStateChanged(playbackState: Int) { if (playbackState == Player.STATE_ENDED) advance(1, true) }
                override fun onPlayerError(error: androidx.media3.common.PlaybackException) { stopReading(); runtime.fail(IllegalStateException("Audio could not play. Please try again.")); stopForeground(STOP_FOREGROUND_DETACH) }
            })
        }
        val controls = object : ForwardingPlayer(player) {
            override fun getAvailableCommands(): Player.Commands = super.getAvailableCommands().buildUpon()
                .add(Player.COMMAND_SEEK_TO_NEXT).add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM).add(Player.COMMAND_SEEK_TO_PREVIOUS).add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM).build()
            override fun isCommandAvailable(command: Int) = getAvailableCommands().contains(command)
            override fun play() { playReading() }
            override fun pause() { pauseReading() }
            override fun seekToNext() { advance(1, runtime.state.value.playing) }
            override fun seekToNextMediaItem() { seekToNext() }
            override fun seekToPrevious() { advance(-1, runtime.state.value.playing) }
            override fun seekToPreviousMediaItem() { seekToPrevious() }
        }
        session = MediaSession.Builder(this, controls).setSessionActivity(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)).build()
        setMediaNotificationProvider(DefaultMediaNotificationProvider.Builder(this).setNotificationId(1001).build())
        scope.launch { while (isActive) { delay(40); tick() } }
    }
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        if (controllerInfo.isTrusted || controllerInfo.uid == android.os.Process.myUid()) session else null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The service is exported for trusted system media controllers. Custom app
        // actions require an unguessable, process-local token so another app cannot
        // start reading a private document aloud by sending an explicit intent.
        if (intent?.action in listOf("play", "pause", "stop", "next", "previous") && intent?.getStringExtra("openread.command") != runtime.commandToken) {
            if (!runtime.state.value.playing && !runtime.state.value.preparing) stopSelf(startId)
            return START_NOT_STICKY
        }
        super.onStartCommand(intent, flags, startId)
        when (intent?.action) {
            "play" -> playReading()
            "pause" -> pauseReading()
            "stop" -> { stopReading(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
            "next" -> advance(1, runtime.state.value.playing || runtime.state.value.preparing)
            "previous" -> advance(-1, runtime.state.value.playing || runtime.state.value.preparing)
        }
        return START_NOT_STICKY
    }
    private fun preparingNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("openread-playback", "Reading audio", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, ReadingService::class.java).setAction("stop").putExtra("openread.command", runtime.commandToken), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        startForeground(1001, NotificationCompat.Builder(this, "openread-playback").setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(runtime.state.value.reading?.title ?: "OpenRead").setContentText("Preparing on-device voice…").setContentIntent(open)
            .setOngoing(true).addAction(0, "Stop", stop).build())
    }
    private fun playReading() {
        if (runtime.state.value.reading == null) { stopSelf(); return }
        preparingNotification()
        if (runtime.sleepDeadline > 0 && System.currentTimeMillis() >= runtime.sleepDeadline) { runtime.sleep(0); pauseReading(); return }
        val state = runtime.state.value
        val passage = runtime.passages.getOrNull(state.index) ?: run { stopSelf(); return }
        val key = "${state.reading!!.id}:${state.index}:${state.voice}"
        if (key == loadedKey && player.playbackState != Player.STATE_ENDED) { player.play(); return }
        if (state.preparing) return
        generation?.cancel(); val request = UUID.randomUUID(); token = request
        runtime.update { it.copy(preparing = true, error = null, status = "Preparing on-device voice…", highlight = null) }
        generation = scope.launch {
            try {
                runtime.engine.prepare(download = false)
                val audio = runtime.engine.generate(passage.text, state.voice)
                ensureActive(); if (token != request) return@launch
                val directory = File(cacheDir, "playback").apply { mkdirs() }
                val file = File(directory, "$request.wav")
                withContext(Dispatchers.IO) { file.writeBytes(audio.wav) }
                currentFile?.delete(); currentFile = file; clip = audio; loadedKey = key
                player.setMediaItem(MediaItem.Builder().setUri(android.net.Uri.fromFile(file))
                    .setMediaMetadata(MediaMetadata.Builder().setTitle(state.reading.title).setArtist("OpenRead · ${state.voice}").build()).build())
                player.setPlaybackSpeed(runtime.state.value.speed); player.prepare(); player.play()
                runtime.update { it.copy(preparing = false, status = "${it.index + 1} of ${runtime.passages.size}") }
                runtime.passages.getOrNull(state.index + 1)?.let { next -> scope.launch { runCatching { runtime.engine.generate(next.text, state.voice) } } }
            } catch (_: CancellationException) { } catch (error: Exception) {
                if (token == request) { stopReading(); runtime.fail(error); stopForeground(STOP_FOREGROUND_REMOVE) }
            }
        }
    }
    private fun pauseReading() { generation?.cancel(); token = UUID.randomUUID(); player.pause(); runtime.update { it.copy(playing = false, preparing = false, highlight = null, status = "Paused") }; runtime.persistPosition(); stopForeground(STOP_FOREGROUND_DETACH) }
    fun stopReading() { generation?.cancel(); token = UUID.randomUUID(); player.stop(); loadedKey = null; clip = null; currentFile?.delete(); currentFile = null; runtime.update { it.copy(playing = false, preparing = false, highlight = null) } }
    fun setSpeed(speed: Float) { player.setPlaybackSpeed(speed) }
    private fun advance(delta: Int, active: Boolean) {
        val next = runtime.state.value.index + delta
        stopReading()
        if (next >= runtime.passages.size) { runtime.update { it.copy(status = "Finished", index = 0) }; stopForeground(STOP_FOREGROUND_DETACH); return }
        runtime.move(delta); if (active) playReading()
    }
    private fun tick() {
        if (!player.isPlaying) return
        if (runtime.sleepDeadline > 0 && System.currentTimeMillis() >= runtime.sleepDeadline) { runtime.sleep(0); pauseReading(); return }
        val state = runtime.state.value; val passage = runtime.passages.getOrNull(state.index) ?: return
        val time = player.currentPosition / 1000.0
        val word = clip?.words?.firstOrNull { time >= it.start && time < it.end }
        val range = if (state.highlightWords && word != null) WordRange(passage.start + word.offset, passage.start + word.offset + word.length) else null
        if (range != state.highlight) runtime.update { it.copy(highlight = range) }
        if (player.currentPosition % 5000 < 60) runtime.persistPosition()
    }
    override fun onTaskRemoved(rootIntent: Intent?) { if (!player.playWhenReady && !runtime.state.value.preparing) stopSelf() }
    override fun onDestroy() {
        runtime.persistPosition(); scope.cancel(); session?.release(); player.release(); currentFile?.delete(); runtime.service = null; super.onDestroy()
    }
}
