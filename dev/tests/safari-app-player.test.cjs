const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
function fixture(request) {
  const context = {setTimeout() { return 1; },clearTimeout() {}};
  vm.createContext(context);
  for (const file of ['extension/player.js','app/apple/SafariExtension/app-player.js']) vm.runInContext(fs.readFileSync(path.join(__dirname,'../..',file),'utf8'),context);
  const words=[], errors=[], requests=[], notices=[];
  const player = new context.OpenReadPlayer({request: async value => { requests.push(value); return request(value); },
    AudioClass: class { constructor() { throw new Error('Remote playback must not create browser audio.'); } },
    onWord: (offset,length) => words.push([offset,length]),onNotice: notice => notices.push(notice),onError: error => errors.push(error)});
  player.load([{text:'🌊 حين نقرأ'},{text:'نقرأ مرة أخرى'}]);
  player.configure({voice:'kitten2:ArabicFalconer',rate:1.5});
  return {player,words,errors,requests,notices};
}
const flush = () => new Promise(setImmediate);
test('Safari follows native UTF16 word positions across items without browser synthesis', async () => {
  const offset='🌊 حين نقرأ'.length+2;
  const h=fixture(value => value.type==='startListening' ? {ok:true,id:'session'} : {ok:true,status:'playing',index:1,rate:1.5,word:{location:offset,length:4}});
  await h.player.play(); await flush();
  assert.equal(h.player.index,1);
  assert.deepEqual(h.words,[[0,4]]);
  assert.equal(h.requests[0].type,'startListening');
  assert.deepEqual(Array.from(h.requests[0].items),['🌊 حين نقرأ','نقرأ مرة أخرى']);
  h.player.configure({rate:5}); await flush();
  assert.equal(h.player.rate,2);
  assert.equal(h.requests.at(-1).rate,2);
  h.player.stop(); await flush();
  assert.equal(h.requests.at(-1).action,'stop');
  assert.deepEqual(h.errors,[]);
});
test('a cancelled handoff stops the late-created native session', async () => {
  let finish;
  const h=fixture(value => value.type==='startListening' ? new Promise(resolve => finish=resolve) : {ok:true});
  const start=h.player.play(); h.player.stop(); finish({ok:true,id:'late-session'});
  await start; await flush();
  assert.equal(h.player.remoteId,null);
  assert.equal(h.requests.at(-1).id,'late-session');
  assert.equal(h.requests.at(-1).action,'stop');
});
test('native failures stop app playback and report once instead of retaining a highlight', async () => {
  const h=fixture(value => value.type==='startListening' ? {ok:true,id:'session'} : value.type==='listeningState' ? {ok:true,status:'paused',index:0,rate:1,error:'Prepare the language.'} : {ok:true});
  await h.player.play(); await flush();
  assert.equal(h.player.status,'paused');
  assert.deepEqual(h.errors,['Prepare the language.']);
  assert.equal(h.requests.at(-1).action,'stop');
});

test('unavailable word timing remains a nonfatal notice and clears when playback stops', async () => {
  const h=fixture(value => value.type==='startListening' ? {ok:true,id:'session'} : {ok:true,status:'playing',index:0,rate:1,notice:'Word highlighting is unavailable.'});
  await h.player.play(); await flush();
  assert.equal(h.player.status,'playing');
  assert.deepEqual(h.errors,[]);
  assert.equal(h.notices.at(-1),'Word highlighting is unavailable.');
  const count=h.notices.length;
  await h.player.poll(h.player.generation);
  assert.equal(h.notices.length,count,'Repeated state polling must not republish an unchanged notice.');
  h.player.stop();
  assert.equal(h.notices.at(-1),'');
});
