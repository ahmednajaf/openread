/* Neural speech only. The media clock drives word highlighting. */
(() => {
  class Player {
    constructor({ request, AudioClass, onChange = () => {}, onWord = () => {}, onWordClear = () => {}, onError = () => {}, validate = () => {}, frame, cancelFrame, preloadAudio = typeof document !== 'undefined' }) {
      Object.assign(this, { request, AudioClass, onChange, onWord, onWordClear, onError, validate });
      this.frame = frame || globalThis.requestAnimationFrame?.bind(globalThis) || ((fn) => setTimeout(fn, 30));
      this.cancelFrame = cancelFrame || globalThis.cancelAnimationFrame?.bind(globalThis) || clearTimeout;
      this.preloadAudio = preloadAudio;
      this.items = []; this.index = 0; this.status = 'idle'; this.rate = 1; this.voice = 'af_heart';
      this.generation = 0; this.session = 0; this.cache = new Map(); this.clock = null; this.ready = false; this.wordIndex = -1;
    }
    load(items, lang = 'en') { this.stop(); this.session++; this.items = items; this.lang = lang; this.index = 0; this.cache.clear(); this.emit(); }
    emit() { this.onChange({ index: this.index, status: this.status, total: this.items.length, needsPageGesture: !!this.needsPageGesture }); }
    cancel() {
      this.generation++; this.cancelFrame(this.clock); this.clock = null;
      this.ready = false; this.wordIndex = -1; this.needsPageGesture = false; this.onWordClear();
      // Safari grants autoplay per element. Keep the gesture-authorized element
      // across passages: https://webkit.org/blog/7734/auto-play-policy-changes-for-macos/
      if (this.audio) { this.audio.onended = null; this.audio.onerror = null; this.audio.pause(); }
      if (this.standby) { this.standby.onended = null; this.standby.onerror = null; this.standby.pause(); }
    }
    stop() { this.cancel(); this.status = 'idle'; this.emit(); }
    pause() {
      if (!['playing', 'loading'].includes(this.status)) return;
      if (this.status === 'loading') this.cancel(); else this.audio?.pause();
      this.cancelFrame(this.clock); this.clock = null; this.wordIndex = -1; this.onWordClear(); this.status = 'paused'; this.emit();
    }
    async play() {
      if (!this.items.length || ['playing', 'loading'].includes(this.status)) return;
      try { this.validate(this.items[this.index]); } catch (error) { this.fail(error.message); return; }
      if (this.status === 'ended') this.index = 0;
      if (this.status === 'paused' && this.ready && this.audio) {
        const generation = this.generation; const audio = this.audio;
        try { await audio.play(); if (generation !== this.generation) return;
          this.status = 'playing'; this.emit(); this.startClock(generation);
        } catch (error) { if (generation === this.generation) this.playbackFailure(error); }
        return;
      }
      await this.speak();
    }
    seek(index, autoplay = ['playing', 'loading'].includes(this.status)) {
      this.cancel(); this.index = Math.max(0, Math.min(this.items.length - 1, index)); this.status = 'paused'; this.emit();
      if (autoplay && this.items.length) void this.speak();
    }
    configure({ rate = this.rate, voice = this.voice }) {
      this.rate = Math.max(.5, Math.min(5, Number(rate) || 1));
      if (voice === this.voice) { if (this.audio) this.audio.playbackRate = this.rate; if (this.standby) this.standby.playbackRate = this.rate; this.emit(); return; }
      const active = ['playing', 'loading'].includes(this.status);
      const previousStatus = this.status;
      this.cancel(); this.voice = voice; this.cache.clear(); this.status = active ? 'paused' : previousStatus; this.emit(); if (active) void this.speak();
    }
    async generate(index) {
      this.validate(this.items[index]);
      const key = `${this.session}:${this.voice}:${index}`;
      if (this.cache.has(key)) return this.cache.get(key);
      const pending = this.request({ type: 'synthesize', text: this.items[index].text, voice: this.voice }).then((result) => {
        if (!result?.ok || !result.audio) throw new Error(result?.error || 'The natural voice is unavailable.');
        if (!result.words?.length) throw new Error('Update and restart the local voice helper to enable word highlighting.');
        return result;
      });
      this.cache.set(key, pending); while (this.cache.size > 3) this.cache.delete(this.cache.keys().next().value);
      try { return await pending; } catch (error) { if (this.cache.get(key) === pending) this.cache.delete(key); throw error; }
    }
    startClock(generation) {
      this.cancelFrame(this.clock);
      const tick = () => {
        if (generation !== this.generation || this.status !== 'playing' || !this.audio) return;
        const time = this.audio.currentTime || 0; let low = 0; let high = this.timings.length - 1; let index = -1;
        while (low <= high) { const mid = (low + high) >> 1; if (this.timings[mid].start <= time) { index = mid; low = mid + 1; } else high = mid - 1; }
        if (index >= 0 && time >= this.timings[index].end) index = -1;
        if (index !== this.wordIndex) {
          this.wordIndex = index;
          if (index >= 0) { const word = this.timings[index]; this.onWord(word.offset, word.length, word); }
          else this.onWordClear();
        }
        this.clock = this.frame(tick);
      }; tick();
    }
    async speak() {
      const prime = !this.audio || this.needsPageGesture;
      this.cancel(); const generation = this.generation; const current = () => generation === this.generation;
      if (!this.items[this.index]) return;
      this.status = 'loading'; this.emit();
      try {
        this.validate(this.items[this.index]);
        const key = this.audioKey(this.index);
        const prepared = this.queued?.key === key ? this.queued : null;
        const previous = this.audio;
        const audio = prepared?.audio || this.audio || new this.AudioClass();
        if (prepared) { this.standby = previous; this.queued = null; }
        this.audio = audio;
        if (prime) {
          audio.src = 'data:audio/wav;base64,UklGRiYAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQIAAAAAAA==';
          void audio.play().catch(() => {});
          if (this.preloadAudio && !this.standby) {
            // Authorize both elements in the original gesture. The next WAV is
            // decoded in the spare element while the current passage plays.
            const spare = new this.AudioClass(); this.standby = spare;
            spare.src = audio.src; spare.preload = 'auto'; spare.preservesPitch = true;
            void spare.play().then(() => { if (this.audio !== spare) spare.pause(); }).catch(() => {});
          }
        }
        const result = prepared?.result || await this.generate(this.index); if (!current()) return;
        this.validate(this.items[this.index]);
        this.timings = result.words; this.wordIndex = -1; this.ready = true;
        if (!prepared) audio.src = `data:audio/wav;base64,${result.audio}`; audio.playbackRate = this.rate; audio.preservesPitch = true;
        audio.onended = () => {
          // A queued ended event from the unlock sound or a replaced source
          // must not skip the new passage before its own audio has ended.
          if (!current() || audio.ended === false) return;
          this.cancelFrame(this.clock); this.wordIndex = -1; this.onWordClear();
          if (this.index + 1 >= this.items.length) { this.status = 'ended'; this.emit(); return; }
          this.index++; void this.speak();
        };
        audio.onerror = () => { if (current()) this.fail('The voice audio could not be played. Try again.'); };
        await audio.play(); if (!current()) return;
        this.status = 'playing'; this.emit(); this.startClock(generation);
        if (this.index + 1 < this.items.length) void this.prefetchNext(generation);
      } catch (error) { if (current()) this.playbackFailure(error); }
    }
    audioKey(index) { return `${this.session}:${this.voice}:${index}`; }
    async prefetchNext(generation) {
      const index = this.index + 1, key = this.audioKey(index);
      try {
        const result = await this.generate(index);
        if (generation !== this.generation || !this.standby) return;
        const audio = this.standby;
        audio.onended = null; audio.onerror = null; audio.preload = 'auto';
        audio.src = `data:audio/wav;base64,${result.audio}`;
        audio.playbackRate = this.rate; audio.preservesPitch = true;
        audio.load(); this.queued = { key, audio, result };
      } catch { /* The foreground request reports a failure if it is needed. */ }
    }
    playbackFailure(error) {
      const gesture = error?.name === 'NotAllowedError';
      this.fail(gesture ? 'Your browser needs one click on the webpage to enable audio. Click Start listening.' : error.message, gesture);
    }
    fail(message, needsPageGesture = false) { this.cancel(); this.needsPageGesture = needsPageGesture; this.status = 'paused'; this.emit(); this.onError(message); }
    destroy() { this.stop(); if (this.audio) { this.audio.removeAttribute('src'); this.audio.load(); this.audio = null; } if (this.standby) { this.standby.removeAttribute('src'); this.standby.load(); this.standby = null; } this.queued = null; this.items = []; this.cache.clear(); }
  }
  globalThis.OpenReadPlayer = Player; if (typeof module !== 'undefined') module.exports = Player;
})();

/* App-owned Kitten TTS 2 audio; Safari follows exact native source ranges. */
(() => {
  const Base = globalThis.OpenReadPlayer;
  class SafariPlayer extends Base {
    constructor(options) { super(options); this.onNotice = options.onNotice || (() => {}); }
    get remote() { return this.voice.startsWith('kitten2:'); }
    emit() { this.onChange({ index: this.index, status: this.status, total: this.items.length, rate: this.rate, needsPageGesture: !!this.needsPageGesture }); }
    async remoteCommand(action, values = {}) {
      if (!this.remoteId) return;
      const result = await this.request({ type: 'listeningCommand', id: this.remoteId, action, ...values });
      if (!result?.ok) throw new Error(result?.error || 'The OpenRead connection could not update. Start listening again.');
    }
    setNotice(notice = '') {
      if (notice === this.notice) return;
      this.notice = notice; this.onNotice(notice);
    }
    stop() {
      this.setNotice();
      if (!this.remote) { super.stop(); return; }
      void this.remoteCommand('stop').catch(() => {});
      this.generation++; clearTimeout(this.remoteTimer); this.remoteId = null;
      this.status = 'idle'; this.lastWord = ''; this.onWordClear(); this.emit();
    }
    pause() {
      if (!this.remote) { super.pause(); return; }
      if (!this.remoteId) { this.stop(); this.status = 'paused'; this.emit(); return; }
      void this.remoteCommand('pause').catch(error => this.remoteFailure(error));
      this.status = 'paused'; this.lastWord = ''; this.onWordClear(); this.emit();
    }
    async play() {
      if (!this.remote) { return super.play(); }
      if (!this.items.length || ['playing', 'loading'].includes(this.status)) return;
      try {
        this.validate(this.items[this.index]);
        if (this.remoteId && this.status !== 'ended') { await this.remoteCommand('play'); return; }
        if (this.status === 'ended') this.index = 0;
        const token = ++this.generation;
        this.status = 'loading'; this.emit();
        this.offsets = []; let offset = 0;
        for (const item of this.items) { this.offsets.push(offset); offset += item.text.length + 2; }
        const result = await this.request({ type: 'startListening', voice: this.voice, rate: this.rate, items: this.items.map(item => item.text),
          index: this.index, title: globalThis.document?.title || 'Safari reading' });
        if (!result?.ok || !result.id) throw new Error(result?.error || 'Open the OpenRead app and prepare Kitten TTS 2 first.');
        if (token !== this.generation) { void this.request({ type: 'listeningCommand', id: result.id, action: 'stop' }).catch(() => {}); return; }
        this.remoteId = result.id; this.remoteFailures = 0; this.poll(token);
      } catch (error) { this.remoteFailure(error); }
    }
    async poll(token) {
      if (token !== this.generation || !this.remoteId) return;
      try {
        const state = await this.request({ type: 'listeningState', id: this.remoteId });
        if (token !== this.generation) return;
        if (!state?.ok) throw new Error(state?.error || 'The OpenRead app could not update this reading.');
        this.remoteFailures = 0;
        if (!Number.isInteger(state.index) || !this.items[state.index] || !['playing', 'paused', 'loading', 'ended'].includes(state.status)) throw new Error('The playback position was invalid.');
        this.validate(this.items[state.index]);
        this.index = state.index; this.status = state.status; this.rate = Math.max(.5, Math.min(2, Number(state.rate) || 1));
        const word = state.status === 'playing' && state.word;
        const key = word ? `${this.index}:${word.location}:${word.length}` : '';
        if (key !== this.lastWord) {
          this.lastWord = key;
          const local = word && word.location - this.offsets[this.index];
          if (word && Number.isInteger(local) && local >= 0 && Number.isInteger(word.length) && word.length > 0 && local + word.length <= this.items[this.index].text.length) this.onWord(local, word.length);
          else this.onWordClear();
        }
        this.setNotice(state.notice || '');
        this.emit();
        if (state.error) { this.remoteFailure(new Error(state.error)); return; }
        if (state.status === 'ended') { this.onWordClear(); this.remoteId = null; return; }
      } catch (error) {
        if (token !== this.generation) return;
        this.onWordClear();
        if (++this.remoteFailures >= 3) { this.remoteFailure(error); return; }
      }
      this.remoteTimer = setTimeout(() => this.poll(token), 100);
    }
    seek(index, autoplay = ['playing', 'loading'].includes(this.status)) {
      if (!this.remote) { super.seek(index, autoplay); return; }
      this.index = Math.max(0, Math.min(this.items.length - 1, index)); this.onWordClear(); this.lastWord = '';
      if (this.remoteId) void this.remoteCommand('seek', { index: this.index, autoplay }).catch(error => this.remoteFailure(error));
      else { this.status = 'paused'; if (autoplay) void this.play(); }
      this.emit();
    }
    configure({ rate = this.rate, voice = this.voice }) {
      if (!this.remote && !voice.startsWith('kitten2:')) { super.configure({ rate, voice }); return; }
      const active = ['playing', 'loading'].includes(this.status);
      if (voice !== this.voice) {
        this.stop(); this.voice = voice; this.rate = Math.max(.5, Math.min(this.remote ? 2 : 5, Number(rate) || 1));
        this.emit(); if (active) void this.play();
      } else {
        this.rate = Math.max(.5, Math.min(2, Number(rate) || 1));
        if (this.remoteId) void this.remoteCommand('rate', { rate: this.rate }).catch(error => this.remoteFailure(error));
        this.emit();
      }
    }
    remoteFailure(error) { this.stop(); this.status = 'paused'; this.emit(); this.onError(error.message); }
  }
  globalThis.OpenReadPlayer = SafariPlayer;
})();
