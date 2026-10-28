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
  const voices = [{"id":"kitten:kiki","name":"Kiki","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten","embedding":"expr-voice-5-f"},{"id":"kitten:rosie","name":"Rosie","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten","embedding":"expr-voice-4-f"},{"id":"kitten:jasper","name":"Jasper","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten","embedding":"expr-voice-2-m"},{"id":"kitten:luna","name":"Luna","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten","embedding":"expr-voice-3-f"},{"id":"kitten:bruno","name":"Bruno","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten","embedding":"expr-voice-3-m"},{"id":"kitten:hugo","name":"Hugo","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten","embedding":"expr-voice-4-m"},{"id":"kitten:leo","name":"Leo","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten","embedding":"expr-voice-5-m"},{"id":"kitten:bella","name":"Bella","detail":"Kitten Mini · English","lang":"en-us","pack":"kitten","embedding":"expr-voice-2-f"},{"id":"af_heart","name":"Heart","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"af_bella","name":"Bella","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"af_nicole","name":"Nicole","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"af_alloy","name":"Alloy","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"af_aoede","name":"Aoede","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"af_jessica","name":"Jessica","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"af_kore","name":"Kore","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"af_nova","name":"Nova","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"af_river","name":"River","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"af_sarah","name":"Sarah","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"af_sky","name":"Sky","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"am_michael","name":"Michael","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"am_adam","name":"Adam","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"am_echo","name":"Echo","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"am_eric","name":"Eric","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"am_fenrir","name":"Fenrir","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"am_liam","name":"Liam","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"am_onyx","name":"Onyx","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"am_puck","name":"Puck","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"am_santa","name":"Santa","detail":"American","lang":"en-us","pack":"kokoro"},{"id":"bf_emma","name":"Emma","detail":"British","lang":"en-gb","pack":"kokoro"},{"id":"bf_alice","name":"Alice","detail":"British","lang":"en-gb","pack":"kokoro"},{"id":"bf_isabella","name":"Isabella","detail":"British","lang":"en-gb","pack":"kokoro"},{"id":"bf_lily","name":"Lily","detail":"British","lang":"en-gb","pack":"kokoro"},{"id":"bm_george","name":"George","detail":"British","lang":"en-gb","pack":"kokoro"},{"id":"bm_daniel","name":"Daniel","detail":"British","lang":"en-gb","pack":"kokoro"},{"id":"bm_fable","name":"Fable","detail":"British","lang":"en-gb","pack":"kokoro"},{"id":"bm_lewis","name":"Lewis","detail":"British","lang":"en-gb","pack":"kokoro"},{"id":"ef_dora","name":"Dora","detail":"Spanish","lang":"es","pack":"kokoro"},{"id":"em_alex","name":"Alex","detail":"Spanish","lang":"es","pack":"kokoro"},{"id":"em_santa","name":"Santa","detail":"Spanish","lang":"es","pack":"kokoro"},{"id":"ff_siwis","name":"Siwis","detail":"French","lang":"fr-fr","pack":"kokoro"},{"id":"hf_alpha","name":"Alpha","detail":"Hindi","lang":"hi","pack":"kokoro"},{"id":"hf_beta","name":"Beta","detail":"Hindi","lang":"hi","pack":"kokoro"},{"id":"hm_omega","name":"Omega","detail":"Hindi","lang":"hi","pack":"kokoro"},{"id":"hm_psi","name":"Psi","detail":"Hindi","lang":"hi","pack":"kokoro"},{"id":"if_sara","name":"Sara","detail":"Italian","lang":"it","pack":"kokoro"},{"id":"im_nicola","name":"Nicola","detail":"Italian","lang":"it","pack":"kokoro"},{"id":"pf_dora","name":"Dora","detail":"Portuguese","lang":"pt-br","pack":"kokoro"},{"id":"pm_alex","name":"Alex","detail":"Portuguese","lang":"pt-br","pack":"kokoro"},{"id":"pm_santa","name":"Santa","detail":"Portuguese","lang":"pt-br","pack":"kokoro"}];
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
      const group = voice.pack === 'kitten' ? (['kitten:kiki', 'kitten:rosie', 'kitten:jasper'].includes(voice.id) ? 'Featured · Kitten' : 'More Kitten voices') : `Kokoro · ${voice.detail}`;
      if (!groups.has(group)) groups.set(group, []);
      groups.get(group).push(voice);
    }
    return [...groups].map(([label, voices]) => ({ label, voices }));
  }
  const core = { normalize, words, passages, chunks, voices, samples, defaultVoice, voiceGroups };
  globalThis.OpenReadCore = core;
  if (typeof module !== "undefined") module.exports = core;
})();
