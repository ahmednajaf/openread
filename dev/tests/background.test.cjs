const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../extension/background.js'), 'utf8');

function request(response) {
  let handler;
  const browser = { runtime: { onMessage: { addListener: fn => { handler = fn; } } }, commands: { onCommand: { addListener() {} } } };
  vm.runInNewContext(source, { browser, AbortSignal, fetch: async () => {
    if (response instanceof Error) throw response;
    return response;
  } });
  return new Promise(resolve => handler({ type: 'synthesize', text: 'I', voice: 'kitten:rosie' }, { tab: { id: 1 } }, resolve));
}

test('voice rejection, busy helper and access errors are never described as disconnected', async () => {
  for (const [status, code, expected] of [
    [422, 'voice_alignment_failed', /could not align/],
    [422, 'voice_setup_required', /More Voices/],
    [429, null, /busy/], [403, null, /access/], [400, null, /request/], [500, null, /generate/]
  ]) {
    const result = await request({ ok: false, status, json: async () => ({ code, error: 'untrusted detail' }) });
    assert.equal(result.ok, false); assert.match(result.error, expected);
    assert.doesNotMatch(result.error, /aren't connected|untrusted detail/);
  }
  const invalidJson = await request({ ok: false, status: 500, json: async () => { throw new Error('bad response'); } });
  assert.match(invalidJson.error, /generate/);
});

test('network failure and timeouts have different recovery instructions', async () => {
  assert.match((await request(new TypeError('fetch failed'))).error, /aren't connected/);
  assert.match((await request(Object.assign(new Error(), { name: 'TimeoutError' }))).error, /took too long/);
  assert.match((await request({ ok: true, json: async () => { throw new Error('invalid JSON'); } })).error, /unreadable response/);
});

test('successful local speech still returns audio and timing data', async () => {
  const result = await request({ ok: true, json: async () => ({ audio: 'wav', words: [{ offset: 0, length: 1 }] }) });
  assert.equal(result.ok, true); assert.equal(result.audio, 'wav'); assert.equal(result.words.length, 1);
});
