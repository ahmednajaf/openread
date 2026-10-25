const { test } = require("node:test");
const assert = require("node:assert/strict");
const { passages, chunks, normalize, words } = require("../extension/core.js");

test("paragraphs remain separate and short sentences keep their prosody context", () => {
  const result = passages("First thought. Second thought.\n\nNext paragraph.");
  assert.deepEqual(result, [{ text: "First thought. Second thought.", paragraph: 0 }, { text: "Next paragraph.", paragraph: 1 }]);
});
test("very long sentences are bounded without losing words", () => {
  const text = "reading ".repeat(600).trim();
  const result = passages(text);
  assert.ok(result.every((p) => p.text.length <= 550));
  assert.equal(result.map((p) => p.text).join(" "), text);
});
test("unbroken unicode cannot leave lone surrogate halves", () => {
  const text = "🙂".repeat(800);
  const result = passages(text, "invalid_locale");
  assert.ok(result.every((p) => p.text.length <= 550 && p.text.isWellFormed()));
  assert.equal(result.map((p) => p.text).join(""), text);
});
test("empty input, unicode spaces and invalid locale are safe", () => {
  assert.deepEqual(passages("   \n\n "), []);
  assert.equal(normalize(" A\u00a0 B\t\n C "), "A B C");
  assert.equal(words("one two\nthree"), 3);
  assert.deepEqual(passages("Hello.", "definitely_invalid_locale"), [{ text: "Hello.", paragraph: 0 }]);
});
test('chunk offsets preserve adjacent sentences and source whitespace exactly', () => {
  for (const text of ['你好。再见。', 'Hello!Next sentence.', 'First.\nSecond.', 'First.\u00a0Second.', '🙂'.repeat(800)]) {
    const result = chunks(text, 'en');
    assert.ok(result.length);
    assert.ok(result.every(c => c.text === text.slice(c.start, c.end) && c.text.length <= 550 && c.text.isWellFormed()));
    assert.equal(result.map(c => c.text).join('').replace(/\s/gu, ''), text.replace(/\s/gu, ''));
  }
});

test('every offered voice matches the helper catalog and the featured default exists', () => {
  const catalog = require('../extension/voices.json');
  const core = require('../extension/core.js');
  assert.deepEqual(core.voices, catalog);
  assert.equal(core.voices.find(voice => voice.id === core.defaultVoice)?.pack, 'kitten');
  assert.equal(core.voiceGroups()[0].voices[0].id, core.defaultVoice);
});
