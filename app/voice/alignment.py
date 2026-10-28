"""Map model phoneme times to original UTF-16 source ranges."""
from difflib import SequenceMatcher
import re


def align_words(text, phonemes, timings, duration):
    """Align source words to model phonemes, including expansions like '2026'.

    Offsets are UTF-16 code units for DOM Range/JavaScript compatibility. A
    contextual pronunciation can differ from an isolated word; sequence
    alignment handles that without assuming one phoneme group per source word.
    """
    tokens = list(re.finditer(r'\S+', text))
    target = []; owners = []
    for index, sound in enumerate(phonemes):
        for character in sound:
            if not character.isspace():
                target.append(character); owners.append(index)
    actual = [timing for timing in timings if not timing.phoneme.isspace()]
    matches = [[] for _ in tokens]
    matcher = SequenceMatcher(None, target, [t.phoneme for t in actual], autojunk=False)
    for block in matcher.get_matching_blocks():
        for delta in range(block.size):
            matches[owners[block.a + delta]].append(actual[block.b + delta])
    # Missing runs share the gap between real duration anchors. Assigning the
    # whole gap to each missing word would freeze one highlight or overlap it.
    lexical = [i for i, token in enumerate(tokens) if any(c.isalnum() for c in token.group())]
    bounds = {}
    cursor = 0
    while cursor < len(lexical):
        index = lexical[cursor]
        if matches[index]:
            bounds[index] = (matches[index][0].start, matches[index][-1].end)
            cursor += 1
            continue
        end = cursor + 1
        while end < len(lexical) and not matches[lexical[end]]:
            end += 1
        begin_time = bounds[lexical[cursor - 1]][1] if cursor else 0.0
        end_time = max(begin_time, matches[lexical[end]][0].start if end < len(lexical) else duration)
        weights = [max(1, len(phonemes[i])) for i in lexical[cursor:end]]
        total = sum(weights)
        elapsed = 0
        for owner, weight in zip(lexical[cursor:end], weights):
            bounds[owner] = (begin_time + (end_time - begin_time) * elapsed / total,
                             begin_time + (end_time - begin_time) * (elapsed + weight) / total)
            elapsed += weight
        cursor = end
    words = []
    for index in lexical:
        token = tokens[index]
        start, end = bounds[index]
        start = max(words[-1]['end'] if words else 0.0, min(duration, start))
        words.append({
            'offset': len(text[:token.start()].encode('utf-16-le')) // 2,
            'length': len(token.group().encode('utf-16-le')) // 2,
            'start': round(start, 4), 'end': round(max(start, min(duration, end)), 4),
            'estimated': not bool(matches[index]),
        })
    return words
