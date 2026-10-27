const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { transformSync } = require('esbuild');

function backupClient() {
  const calls = [];
  const load = name => {
    const scope = { exports: {} };
    vm.runInNewContext(transformSync(fs.readFileSync(path.join(__dirname, '../../app/reader/src/', name + '.ts'), 'utf8'), { loader: 'ts', format: 'cjs' }).code, {
      module: scope, exports: scope.exports,
      require: name => name === './layout' ? load('layout') : { api: async (...args) => { calls.push(args); } },
    });
    return scope.exports;
  };
  return { calls, restore: documents => load('files').restoreLibrary({ size: 1000, text: async () => JSON.stringify({ format: 'openread-library-v1', documents }) }) };
}

test('backup restoration checks every chapter list before saving any reading', async () => {
  const client = backupClient();
  const good = { id: 'book', title: 'Book', text: 'First.\n\nSecond.', chapters: [{ id: 'one', title: 'First', paragraph: 0 }, { id: 'two', title: 'Second', paragraph: 1 }] };
  const bad = { ...good, id: 'bad', chapters: [{ id: 'one', title: 'Missing opening', paragraph: 1 }] };
  await assert.rejects(client.restore([good, bad]), /invalid chapters/);
  assert.equal(client.calls.length, 0);
  await client.restore([good]);
  assert.deepEqual(JSON.parse(JSON.stringify(client.calls[0][1].chapters)), good.chapters);
});

test('backups made before chapter navigation can still be restored', async () => {
  const client = backupClient();
  await client.restore([{ title: 'Old reading', text: 'Saved before chapters existed.' }]);
  assert.equal(client.calls.length, 1);
});
