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
