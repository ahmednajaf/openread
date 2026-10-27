"""Offline English pronunciation choices from sentence context, not text rewrites.

The shared compact encoder and its training/data licences live in
app/mobile/shared/pronunciation. Uncertain decisions keep eSpeak's original
pronunciation. No inference request leaves this machine.
"""
import json
import math
from pathlib import Path
import re
import unicodedata

ASSETS = Path(__file__).resolve().parents[1] / 'mobile/shared/pronunciation'
PUNCTUATION = ';:,.!?"\'“”‘’()[]{}«»—…'


class WordPiece:
    def __init__(self, vocab):
        self.vocab = {word: i for i, word in enumerate(vocab.splitlines())}

    def encode(self, text):
        cleaned = ''.join(' ' if c.isspace() else c for c in text if unicodedata.category(c) not in ('Cc', 'Cf') or c.isspace())
        cleaned = ''.join(c for c in unicodedata.normalize('NFD', cleaned.lower()) if unicodedata.category(c) != 'Mn')
        basic = []; current = ''
        for char in cleaned:
            code = ord(char)
            punctuation = (33 <= code <= 47 or 58 <= code <= 64 or 91 <= code <= 96 or 123 <= code <= 126 or unicodedata.category(char).startswith('P'))
            chinese = any(a <= code <= b for a, b in [(0x4e00,0x9fff),(0x3400,0x4dbf),(0x20000,0x2a6df),(0x2a700,0x2b73f),(0x2b740,0x2b81f),(0x2b820,0x2ceaf),(0xf900,0xfaff),(0x2f800,0x2fa1f)])
            if char.isspace() or punctuation or chinese:
                if current: basic.append(current); current = ''
                if not char.isspace(): basic.append(char)
            else: current += char
        if current: basic.append(current)
        result = []
        for word in basic:
            if len(word) > 100: result.append(100); continue
            start = 0; pieces = []
            while start < len(word):
                end = len(word)
                while end > start and (('##' if start else '') + word[start:end]) not in self.vocab: end -= 1
                if end == start: pieces = [100]; break
                pieces.append(self.vocab[('##' if start else '') + word[start:end]]); start = end
            result.extend(pieces)
        return result


class ContextPronunciation:
    def __init__(self, assets=ASSETS):
        self.assets = assets
        self.data = json.loads((assets / 'lexicon.json').read_text())
        self.tokenizer = WordPiece((assets / 'vocab.txt').read_text())
        self.session = None

    def choices(self, text):
        import numpy as np
        candidates = []
        for index, match in enumerate(re.finditer(r'\S+', text)):
            token = match.group(); word = token.strip(PUNCTUATION).lower()
            if word not in self.data['words']: continue
            a = match.start() + len(token) - len(token.lstrip(PUNCTUATION)); b = a + len(word)
            ids = [101] + self.tokenizer.encode(text[:a])[-55:] + [1] + self.tokenizer.encode(text[a:b]) + [2] + self.tokenizer.encode(text[b:])[:55] + [102]
            candidates.append((index, word, ids))
            if len(candidates) == 64: break
        if not candidates: return {}
        if self.session is None:
            import onnxruntime as ort
            ort.disable_telemetry_events()
            options = ort.SessionOptions(); options.intra_op_num_threads = 2
            options.enable_cpu_mem_arena = False
            self.session = ort.InferenceSession(str(self.assets / 'context.ort'), sess_options=options, providers=['CPUExecutionProvider'])
        choices = {}
        # Keep activation memory bounded even for repeated ambiguous words.
        for start in range(0, len(candidates), 8):
            batch = candidates[start:start+8]; width = max(len(r[2]) for r in batch)
            ids = np.zeros((len(batch), width), dtype=np.int64)
            for i, (_, _, tokens) in enumerate(batch): ids[i, :len(tokens)] = tokens
            logits, grammar = self.session.run(None, {'input_ids': ids, 'attention_mask': (ids != 0).astype(np.int64)})
            for (owner, word, _), values, tags in zip(batch, logits, grammar):
                entries = self.data['words'][word]
                scores = np.asarray([values[e['id']] for e in entries], dtype=np.float64)
                mass = np.ones(len(entries))
                if all(e['tags'] for e in entries):
                    tags = np.exp(tags.astype(np.float64) - max(tags)); tags /= tags.sum()
                    mass = np.asarray([sum(tags[t] for t in e['tags']) for e in entries])
                    scores += np.log(np.maximum(.01, mass))
                probabilities = np.exp(scores - max(scores)); probabilities /= probabilities.sum()
                selected = int(probabilities.argmax()); entry = entries[selected]
                if probabilities[selected] >= self.data['confidence'] and mass[selected] >= self.data['grammar_confidence'] and entry['ipa']:
                    choices[owner] = entry['ipa']
        return choices


def _sound(char):
    return 'a' <= char <= 'z' or 'A' <= char <= 'Z' or 0x250 <= ord(char) <= 0x2af or 0x1d00 <= ord(char) <= 0x1dbf


def apply_choices(text, baseline, isolated, choices):
    """Align whole-sentence phones conservatively, preserving other words/prosody."""
    if not choices: return baseline
    expected = []; owners = []
    for i, phonemes in enumerate(isolated):
        for char in phonemes:
            if _sound(char): expected.append(char); owners.append(i)
    heard = []; groups = []; group_of = []
    for i, match in enumerate(re.finditer(r'\S+', baseline)):
        groups.append(match)
        for char in match.group():
            if _sound(char): heard.append(char); group_of.append(i)
    if len(expected) > 2048 or len(heard) > 2048: return baseline
    width = len(heard) + 1
    from array import array
    dp = [array('H', [0]) * width for _ in range(len(expected)+1)]
    for i in range(len(expected)-1, -1, -1):
        for j in range(len(heard)-1, -1, -1):
            dp[i][j] = 1 + dp[i+1][j+1] if expected[i] == heard[j] else max(dp[i+1][j], dp[i][j+1])
    assigned = [-1] * len(heard); i = j = 0
    while i < len(expected) and j < len(heard):
        if expected[i] == heard[j]: assigned[j] = owners[i]; i += 1; j += 1
        elif dp[i+1][j] >= dp[i][j+1]: i += 1
        else: j += 1
    changes = []
    for group, match in enumerate(groups):
        sounds = [k for k, value in enumerate(group_of) if value == group]
        mapped = {assigned[k] for k in sounds if assigned[k] >= 0}
        if len(sounds) < 2 or len(mapped) != 1: continue
        owner = next(iter(mapped))
        if owner not in choices or assigned[sounds[0]] != owner or assigned[sounds[-1]] != owner: continue
        raw = match.group(); a = match.start()+len(raw)-len(raw.lstrip(PUNCTUATION)); b = match.end()-(len(raw)-len(raw.rstrip(PUNCTUATION)))
        changes.append((a,b,choices[owner]))
    for a,b,ipa in reversed(changes): baseline = baseline[:a]+ipa+baseline[b:]
    return baseline


class EnglishFrontend:
    def __init__(self, backend):
        self.backend = backend
        self.context = None

    def phonemize(self, text):
        baseline = self.backend.phonemize([text])[0]
        try:
            if self.context is None: self.context = ContextPronunciation()
            choices = self.context.choices(text)
        except Exception:
            # Optional context inference must never prevent ordinary playback.
            return baseline
        if not choices: return baseline
        isolated = self.backend.phonemize(re.findall(r'\S+', text))
        return apply_choices(text, baseline, isolated, choices)
