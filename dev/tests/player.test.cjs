const { test } = require('node:test');
const assert = require('node:assert/strict');
const Player = require('../../extension/player.js');
const result = { ok: true, audio: 'audio', words: [{ offset: 0, length: 5, start: .1, end: .8 }, { offset: 6, length: 9, start: .9, end: 1.8 }] };
function fixture(overrides = {}) {
  const audio = []; const errors = []; const frames = new Map(); let sequence = 0;
  class Audio {
    constructor() { this.currentTime = 0; audio.push(this); }
    play() { this.playing = true; return Promise.resolve(); }
    pause() { this.playing = false; }
    load() {} removeAttribute() {}
  }
  const player = new Player({ AudioClass: Audio, request: async () => result, onError: (e) => errors.push(e),
    frame: (fn) => { const id = ++sequence; frames.set(id, fn); return id; }, cancelFrame: (id) => frames.delete(id), ...overrides });
  player.load([{ text: 'First paragraph.' }, { text: 'Second paragraph.' }]);
  const tick = () => { const scheduled = [...frames.values()]; frames.clear(); scheduled.forEach((fn) => fn()); };
  return { player, audio, errors, tick };
}
test('word highlights follow actual audio time and stay put while paused', async () => {
  const heard = []; const { player, audio, tick } = fixture({ onWord: (offset, length) => heard.push([offset, length]) });
  await player.play(); audio[0].currentTime = .2; tick(); assert.deepEqual(heard, [[0, 5]]);
  audio[0].currentTime = 1.1; tick(); assert.deepEqual(heard, [[0, 5], [6, 9]]);
  player.pause(); audio[0].currentTime = 0; tick(); assert.equal(heard.length, 2);
  await player.play(); assert.equal(audio.length, 1); player.stop();
});
test('cancelled neural request cannot start audio later', async () => {
  let resolve; const { player, audio } = fixture({ request: () => new Promise((r) => { resolve = r; }) });
  const playing = player.play(); assert.equal(player.status, 'loading'); player.stop(); resolve(result); await playing;
  assert.equal(player.status, 'idle'); assert.equal(audio[0].playing, false);
});
test('speed changes preserve the current audio position and pitch', async () => {
  const { player, audio } = fixture(); await player.play(); audio[0].currentTime = 1.1;
  player.configure({ rate: 1.5 }); assert.equal(audio.length, 1); assert.equal(audio[0].currentTime, 1.1);
  assert.equal(audio[0].playbackRate, 1.5); assert.equal(audio[0].preservesPitch, true); assert.equal(player.status, 'playing'); player.stop();
});
test('changing voice invalidates prefetched audio and uses the requested voice', async () => {
  const requests = []; const { player } = fixture({ request: async (m) => { requests.push(m); return result; } });
  await player.play(); player.configure({ voice: 'bf_emma' }); await new Promise(setImmediate);
  assert.deepEqual(requests.map((m) => m.voice), ['af_heart', 'af_heart', 'bf_emma', 'bf_emma']); player.stop();
});
test('stale audio callbacks cannot advance new text', async () => {
  const { player, audio } = fixture(); await player.play(); const ended = audio[0].onended;
  player.load([{ text: 'A new document.' }]); ended(); assert.equal(player.index, 0); assert.equal(player.status, 'idle');
});
test('prefetch is reused, pausing resumes, and completion can restart', async () => {
  let requests = 0; const { player, audio } = fixture({ request: async () => { requests++; return result; } });
  await player.play(); assert.equal(requests, 2); player.pause(); await player.play(); assert.equal(audio.length, 1);
  audio[0].onended(); await new Promise(setImmediate); assert.equal(player.index, 1); assert.equal(requests, 2);
  assert.equal(audio.length, 1); audio[0].onended(); assert.equal(player.status, 'ended'); await player.play(); assert.equal(player.index, 0); player.stop();
});
test('a whole page reuses the gesture-authorized element through every passage', async () => {
  let created = 0; const errors = []; const heard = []; let requests = 0;
  class GestureAudio {
    constructor() { this.allowed = ++created === 1; this.currentTime = 0; }
    play() { return this.allowed ? Promise.resolve() : Promise.reject(new Error('NotAllowedError')); }
    pause() {} load() {} removeAttribute() {}
  }
  const player = new Player({ AudioClass: GestureAudio, request: async () => { requests++; return result; },
    onError: e => errors.push(e), onChange: ({status,index}) => { if (status === 'playing') heard.push(index); } });
  player.load(Array.from({ length: 20 }, (_, i) => ({ text: `Passage ${i}.` })));
  await player.play();
  for (let i = 0; i < 20; i++) { player.audio.onended(); await new Promise(setImmediate); }
  assert.equal(player.status, 'ended'); assert.equal(created, 1); assert.equal(requests, 20);
  assert.deepEqual(heard, Array.from({ length: 20 }, (_, i) => i)); assert.deepEqual(errors, []); player.stop();
});
test('highlights clear in timing gaps, while loading, and at the end', async () => {
  let word = null; const { player, audio, tick } = fixture({ onWord: offset => { word = offset; }, onWordClear: () => { word = null; } });
  await player.play(); audio[0].currentTime = .2; tick(); assert.equal(word, 0);
  audio[0].currentTime = .85; tick(); assert.equal(word, null);
  audio[0].currentTime = 1; tick(); assert.equal(word, 6);
  audio[0].onended(); assert.equal(word, null); await new Promise(setImmediate);
  audio[0].currentTime = 1; tick(); assert.equal(word, 6);
  audio[0].onended(); assert.equal(word, null); assert.equal(player.status, 'ended');
});
test('a delayed old play promise cannot pause a newer passage on the shared element', async () => {
  const waiting = [];
  class SlowAudio {
    play() {
      this.playing = true;
      return this.src.endsWith(',audio') ? new Promise(resolve => waiting.push(resolve)) : Promise.resolve();
    }
    pause() { this.playing = false; } load() {} removeAttribute() {}
  }
  const { player } = fixture({ AudioClass: SlowAudio });
  const first = player.play(); await new Promise(setImmediate);
  player.configure({ voice: 'bf_emma' }); await new Promise(setImmediate);
  waiting[1](); await new Promise(setImmediate); assert.equal(player.status, 'playing');
  waiting[0](); await first; assert.equal(player.audio.playing, true); assert.equal(player.status, 'playing'); player.stop();
});
test('missing timing data asks for an updated helper instead of faking word timing', async () => {
  const { player, errors } = fixture({ request: async () => ({ ok: true, audio: 'old-helper' }) });
  await player.play(); assert.equal(player.status, 'paused'); assert.match(errors[0], /restart the local voice helper/);
});
test('helper failure is visible and never substitutes a system voice', async () => {
  const { player, errors } = fixture({ request: async () => ({ ok: false, error: 'Voice offline' }) });
  await player.play(); assert.equal(player.status, 'paused'); assert.deepEqual(errors, ['Voice offline']);
});
test('Safari gesture rejection exposes a retry on the same element without advancing', async () => {
  let allowed = false; let created = 0;
  class SafariAudio {
    constructor() { created++; }
    play() { return allowed ? Promise.resolve() : Promise.reject(Object.assign(new Error('blocked'), { name: 'NotAllowedError' })); }
    pause() {} load() {} removeAttribute() {}
  }
  const { player, errors } = fixture({ AudioClass: SafariAudio });
  await player.play(); assert.equal(player.needsPageGesture, true); assert.equal(player.index, 0);
  assert.equal(player.status, 'paused'); assert.match(errors[0], /one click on the webpage/);
  allowed = true; await player.play(); assert.equal(player.status, 'playing'); assert.equal(player.needsPageGesture, false); assert.equal(created, 1); player.stop();
});
test('an old unlock-source ended event cannot skip a playing passage', async () => {
  const { player, audio } = fixture(); await player.play();
  audio[0].ended = false; audio[0].onended(); assert.equal(player.index, 0); assert.equal(player.status, 'playing');
  audio[0].ended = true; audio[0].onended(); await new Promise(setImmediate); assert.equal(player.index, 1);
  audio[0].ended = false; audio[0].onended(); assert.equal(player.index, 1); assert.equal(player.status, 'playing'); player.destroy();
});

test('choosing a voice before playback keeps a fresh reading idle', () => {
  const player = new Player({ request: async () => ({}), AudioClass: class {} });
  player.load([{text:'A fresh reading.'}]); player.configure({voice:'kitten:kiki'});
  assert.equal(player.status,'idle'); assert.equal(player.voice,'kitten:kiki');
});

test('a changed chat cannot play a synthesis result that was already in flight', async () => {
  let resolve; let valid = true;
  const { player, audio, errors } = fixture({
    validate: () => { if (!valid) throw new Error('Conversation changed'); },
    request: () => new Promise(done => { resolve = done; })
  });
  const playing = player.play(); valid = false; resolve(result); await playing;
  assert.equal(player.status, 'paused'); assert.deepEqual(errors, ['Conversation changed']);
  assert.equal(audio[0].playing, false); player.destroy();
});

test('a cached chat passage is validated again before resuming', async () => {
  let valid = true;
  const { player, audio, errors } = fixture({ validate: () => { if (!valid) throw new Error('Conversation changed'); } });
  await player.play(); player.pause(); valid = false; await player.play();
  assert.equal(player.status, 'paused'); assert.equal(audio[0].playing, false);
  assert.deepEqual(errors, ['Conversation changed']); player.destroy();
});

test('preloaded passages alternate authorized elements without resetting their source', async () => {
  let word = null;
  const { player, audio, tick } = fixture({ preloadAudio: true, onWord: o => { word = o; }, onWordClear: () => { word = null; } });
  await player.play(); await new Promise(setImmediate);
  assert.equal(audio.length, 2); assert.equal(player.queued.audio, audio[1]);
  const preparedSource = audio[1].src;
  player.configure({rate: 2}); assert.equal(audio[1].playbackRate, 2);
  audio[0].currentTime = 1; tick(); assert.equal(word, 6);
  audio[0].onended(); await new Promise(setImmediate);
  assert.equal(player.audio, audio[1]); assert.equal(player.audio.src, preparedSource);
  assert.equal(player.index, 1); assert.equal(player.audio.preservesPitch, true);
  player.audio.currentTime = 1; tick(); assert.equal(word, 6);
  player.pause(); assert.equal(word, null);
  await player.play(); assert.equal(player.audio.currentTime, 1);
  player.audio.onended(); assert.equal(player.status, 'ended'); assert.equal(word, null);
  player.destroy();
});
test('a stale preloaded passage cannot cross a document or voice change', async () => {
  const { player } = fixture({preloadAudio: true}); await player.play(); await new Promise(setImmediate);
  const stale = player.queued.audio;
  player.configure({voice: 'kitten:kiki'}); await new Promise(setImmediate);
  assert.equal(player.voice, 'kitten:kiki'); assert.notEqual(player.audio, stale);
  player.load([{text:'Another document.'}]); await player.play();
  assert.equal(player.index, 0); assert.equal(player.status, 'playing'); player.destroy();
});
