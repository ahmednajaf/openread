const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { transformSync } = require('esbuild');
const core = require('../../extension/core.js');
const moduleScope = { exports: {} };
vm.runInNewContext(transformSync(fs.readFileSync(path.join(__dirname, '../../app/reader/src/layout.ts'), 'utf8'), { loader: 'ts', format: 'cjs' }).code, { module: moduleScope, exports: moduleScope.exports });
const { readingLayout, chapterLayout, validChapters } = moduleScope.exports;

test('speech chunks map forward through repeated phrases and retain Unicode offsets', () => {
  const text = 'One repeated phrase. One repeated phrase.\n\n🙂 Read this.';
  const chunks = [{ text: 'One repeated phrase.', paragraph: 0 }, { text: 'One repeated phrase.', paragraph: 0 }, { text: '🙂 Read this.', paragraph: 1 }];
  const layout = readingLayout(text, chunks);
  assert.equal(layout.paragraphs.length, 2);
  assert.equal(layout.items[1].start, 21);
  assert.equal(layout.paragraphs[1].slice(layout.items[2].start + 3, 7), 'Read');
});
test('the Odyssey keeps four source paragraphs while every speech chunk maps exactly', () => {
  const text = require('../../app/reader/src/data/odyssey.json').text;
  const chunks = core.passages(text);
  const layout = readingLayout(text, chunks);
  assert.equal(layout.paragraphs.length, 4);
  assert.ok(layout.items.length > layout.paragraphs.length);
  for (const item of layout.items) assert.equal(layout.paragraphs[item.paragraph].slice(item.start, item.start + item.text.length), item.text);
});
test('an unmappable chunk fails instead of highlighting unrelated text', () => {
  assert.throws(() => readingLayout('Real source.', [{ text: 'Different text.', paragraph: 0 }]), /could not be mapped/);
});

test('lists retain line breaks while word boundaries map through normalized whitespace', () => {
  const text = 'A list:\n• First  point\n• 🙂 Second point';
  const layout = readingLayout(text, core.passages(text));
  assert.equal(layout.paragraphs[0], text);
  for (const item of layout.items) {
    for (const word of item.text.matchAll(/\S+/gu)) {
      assert.equal(text.slice(item.offsets[word.index], item.offsets[word.index + word[0].length]), word[0]);
    }
  }
});

test('chapters seek to their first speech chunk after long and Unicode paragraphs', () => {
  const text = '🙂 A long sentence. '.repeat(70).trim() + '\n\nSecond heading\n\nFinal chapter.';
  const chapters = [{ id: 'one', title: 'First', paragraph: 0 }, { id: 'two', title: 'Second', paragraph: 1 }, { id: 'three', title: 'Final', paragraph: 2 }];
  const layout = readingLayout(text, core.passages(text));
  assert.ok(layout.items.filter(item => item.paragraph === 0).length > 1);
  assert.ok(validChapters(chapters, text));
  const mapped = chapterLayout(chapters, layout.items);
  assert.equal(mapped[0].index, 0);
  assert.equal(mapped[1].index, layout.items.findIndex(item => item.paragraph === 1));
  assert.equal(layout.items[mapped[2].index].text, 'Final chapter.');
});

test('chapter metadata rejects missing starts, duplicate IDs and invalid paragraph locations', () => {
  const text = 'First.\n\nSecond.';
  assert.ok(validChapters([], text)); // Older readings and backups still work.
  const first = { id: 'one', title: 'First', paragraph: 0 };
  for (const bad of [null, {}, [{ ...first, paragraph: 1 }], [{ ...first, paragraph: true }], [first, { ...first, paragraph: 1 }], [first, { id: 'two', title: 'Second', paragraph: 2 }], [{ ...first, title: ' ' }]]) {
    assert.equal(validChapters(bad, text), false);
  }
});
