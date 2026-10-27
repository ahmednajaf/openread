(() => {
  const normalize = (text) => String(text || "").replace(/\s+/gu, " ").trim();
  const words = (text) => (text.match(/\S+/gu) || []).length;

  function chunks(text, locale = 'en') {
    const value = String(text || ''); const result = []; const limit = 550;
    let sentences;
    try { sentences = [...new Intl.Segmenter(locale, { granularity: 'sentence' }).segment(value)].map(s => s.index + s.segment.length); }
    catch { sentences = [...value.matchAll(/[^.!?]+[.!?]*\s*|[.!?]+/gu)].map(s => s.index + s[0].length); }
    if (!sentences.length && value) sentences = [value.length];
    const push = (from, to) => {
      while (from < to && /\s/u.test(value[from])) from++;
      while (to > from && /\s/u.test(value[to - 1])) to--;
      if (to > from) result.push({ text: value.slice(from, to), start: from, end: to });
    };
    let start = 0; let end = 0;
    for (const sentenceEnd of sentences) {
      if (sentenceEnd - start > limit && end > start) { push(start, end); start = end; }
      while (sentenceEnd - start > limit) {
        let cut = value.lastIndexOf(' ', start + limit);
        if (cut < start + 100) cut = start + limit;
        if (/[\uD800-\uDBFF]/u.test(value[cut - 1])) cut--;
        push(start, cut); start = cut;
        while (start < sentenceEnd && /\s/u.test(value[start])) start++;
      }
      end = sentenceEnd;
    }
    push(start, end);
    return result;
  }

  function passages(text, locale = 'en') {
    return String(text || '').split(/\n\s*\n/u).map(normalize).filter(Boolean)
      .flatMap((value, paragraph) => chunks(value, locale).map(({ text }) => ({ text, paragraph })));
  }
  // Generated from voices.json by dev/scripts/build-ui.cjs.
  const voices = [{"id":"kitten:kiki","name":"Kiki","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten"},{"id":"kitten:rosie","name":"Rosie","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten"},{"id":"kitten:jasper","name":"Jasper","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten"},{"id":"kitten:luna","name":"Luna","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten"},{"id":"kitten:bruno","name":"Bruno","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten"},{"id":"kitten:hugo","name":"Hugo","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten"},{"id":"kitten:leo","name":"Leo","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten"},{"id":"kitten:bella","name":"Bella","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten"}];
  const samples = {
    'en-us': 'Welcome to OpenRead. Choose a voice and a pace that works for you. Your words stay on your device.',
    'en-gb': 'Welcome to OpenRead. Choose a voice and a pace that works for you. Your words stay on your device.',
    es: 'Un poco de espacio para pensar. Una voz para acompañarte. Lee a tu propio ritmo, una idea a la vez.',
    'fr-fr': 'Un peu de place pour réfléchir. Une voix pour vous accompagner. Prenez le temps de lire, une idée à la fois.',
    hi: 'सोचने के लिए थोड़ा समय। एक आवाज़ जो आपका साथ दे। अपनी गति से पढ़िए, एक समय में एक विचार।',
    it: 'Un po’ di spazio per pensare. Una voce per farti compagnia. Leggi al tuo ritmo, un pensiero alla volta.',
    'pt-br': 'Um pouco de espaço para pensar. Uma voz para acompanhar você. Leia no seu ritmo, uma ideia de cada vez.'
  };
  const defaultVoice = 'kitten:kiki';
  function voiceGroups() {
    const groups = new Map();
    for (const voice of voices) {
      const group = voice.pack === 'qwen' ? 'Qwen · Expressive' : voice.pack === 'qwen-clone' ? 'Your voices' : voice.pack === 'kitten' ? (['kitten:kiki', 'kitten:rosie', 'kitten:jasper'].includes(voice.id) ? 'Featured · Kitten' : 'More Kitten voices') : `Kokoro · ${voice.detail}`;
      if (!groups.has(group)) groups.set(group, []);
      groups.get(group).push(voice);
    }
    return [...groups].map(([label, voices]) => ({ label, voices }));
  }
  const core = { normalize, words, passages, chunks, voices, samples, defaultVoice, voiceGroups };
  globalThis.OpenReadCore = core;
  if (typeof module !== "undefined") module.exports = core;
})();
