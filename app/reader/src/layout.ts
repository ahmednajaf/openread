export type Chapter = { id: string; title: string; paragraph: number };

export function validChapters(value: unknown, text: string): value is Chapter[] {
  if (!Array.isArray(value) || value.length > 2000) return false;
  const count = text.trim().split(/\n\s*\n/u).filter(p => p.trim()).length;
  let previous = -1;
  const ids = new Set<string>();
  for (const chapter of value) {
    if (!chapter || typeof chapter.id !== 'string' || !chapter.id || chapter.id.length > 80 || ids.has(chapter.id) || typeof chapter.title !== 'string' || !chapter.title.trim() || chapter.title.length > 240 || !Number.isInteger(chapter.paragraph) || chapter.paragraph <= previous || chapter.paragraph >= count) return false;
    previous = chapter.paragraph;
    ids.add(chapter.id);
  }
  return !value.length || value[0].paragraph === 0;
}

export function chapterLayout(chapters: Chapter[], items: { paragraph?: number }[]) {
  const starts = new Map<number, number>();
  items.forEach((item, index) => { if (!starts.has(item.paragraph || 0)) starts.set(item.paragraph || 0, index); });
  return chapters.map(chapter => ({ ...chapter, index: starts.get(chapter.paragraph) ?? 0 }));
}

// Retain source paragraphs while mapping smaller speech chunks into their text.
export function readingLayout(text: string, chunks: { text: string; paragraph?: number }[]) {
  const paragraphs = text.split(/\n\s*\n/u).map(p => p.trim()).filter(Boolean);
  // Keep list line breaks and original whitespace in the DOM, while speech
  // uses normalized spaces. Every spoken UTF-16 boundary maps back to source.
  const normalized = paragraphs.map(p => {
    let removed = 0;
    const changes: { at: number; removed: number }[] = [];
    for (const match of p.matchAll(/\s+/gu)) {
      if (match[0].length > 1) { const at = match.index - removed; removed += match[0].length - 1; changes.push({ at, removed }); }
    }
    const sourceOffset = (index: number) => {
      let lower = 0, upper = changes.length;
      while (lower < upper) { const middle = (lower + upper) >>> 1; if (changes[middle].at < index) lower = middle + 1; else upper = middle; }
      return index + (lower ? changes[lower - 1].removed : 0);
    };
    return { text: p.replace(/\s+/gu, ' '), sourceOffset };
  });
  const cursors = paragraphs.map(() => 0);
  const items = chunks.map(chunk => {
    const paragraph = chunk.paragraph || 0;
    const start = normalized[paragraph]?.text.indexOf(chunk.text, cursors[paragraph]) ?? -1;
    if (start < 0) throw new Error('This reading could not be mapped to its source text.');
    cursors[paragraph] = start + chunk.text.length;
    const sourceOffset = (offset: number) => normalized[paragraph].sourceOffset(start + offset);
    // Keep compatibility for external callers that inspect offsets, but allocate
    // that array only on demand. Playback uses the sparse whitespace mapping.
    return { ...chunk, paragraph, start: sourceOffset(0), sourceOffset,
      get offsets() { return Array.from({ length: chunk.text.length + 1 }, (_, index) => sourceOffset(index)); } };
  });
  return { paragraphs, items };
}
