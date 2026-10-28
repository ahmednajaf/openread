const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
function host() {
  let listener; const requests = []; const tabs = [];
  const browser = { runtime: { onMessage: { addListener(fn) { listener = fn; } }, async sendNativeMessage(id, value) { requests.push(value); return {ok:true}; } },
    tabs: { async create(value) { tabs.push(value); } }, action: { async setBadgeText() {}, async setTitle() {} }, commands: { onCommand: { addListener() {} } } };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../../app/apple/SafariExtension/background.js'), 'utf8'), {browser});
  const send = (message, sender = {tab:{id:1,url:'https://example.com/article'}}) => new Promise(resolve => {
    const waiting = listener(message, sender, resolve); if (!waiting) resolve(undefined);
  });
  return {requests,tabs,send};
}
test('Safari native speech accepts only its own page request and supported voice', async () => {
  const h = host(); await h.send({type:'synthesize',text:'Read this.',voice:'kitten:kiki'});
  assert.equal(h.requests[0].text,'Read this.');
  await h.send({type:'synthesize',text:'x'.repeat(1601),voice:'kitten:kiki'});
  await h.send({type:'synthesize',text:'Read this.',voice:'https://remote.example'});
  await h.send({type:'synthesize',text:'Read this.',voice:'kitten:kiki'},{});
  assert.equal(h.requests.length,1);
});
test('Safari saves with the browser-provided page source, without a localhost request', async () => {
  const h=host(); await h.send({type:'saveDocument',title:'Reading',text:'Read this.',source:'https://forged.example'});
  assert.equal(h.requests[0].source,'https://example.com/article');
  assert.equal(h.tabs[0].url,'openread://library');
  await h.send({type:'unsupported',text:'private text'});
  assert.equal(h.requests.length,1);
});

test('Safari forwards English Kokoro voices and keeps Qwen app-only', async () => {
  const h = host();
  await h.send({type:'synthesize',text:'Read this.',voice:'af_heart'});
  await h.send({type:'synthesize',text:'Read this.',voice:'bf_emma'});
  assert.deepEqual(h.requests.map(r => r.voice), ['af_heart','bf_emma']);
  await h.send({type:'synthesize',text:'Read this.',voice:'qwen:ryan'});
  assert.equal(h.requests.length, 2);
});
