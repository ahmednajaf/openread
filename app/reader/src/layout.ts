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
    let text = ''; const offsets: number[] = [];
    for (const token of p.matchAll(/\s+|[^\s]/gu)) {
      const value = /^\s/u.test(token[0]) ? ' ' : token[0];
      for (let i = 0; i < value.length; i++) offsets.push(token.index + i);
      text += value;
    }
    offsets.push(p.length); return { text, offsets };
  });
  const cursors = paragraphs.map(() => 0);
  const items = chunks.map(chunk => {
    const paragraph = chunk.paragraph || 0;
    const start = normalized[paragraph]?.text.indexOf(chunk.text, cursors[paragraph]) ?? -1;
    if (start < 0) throw new Error('This reading could not be mapped to its source text.');
    cursors[paragraph] = start + chunk.text.length;
    return { ...chunk, paragraph, start: normalized[paragraph].offsets[start], offsets: normalized[paragraph].offsets.slice(start, start + chunk.text.length + 1) };
  });
  return { paragraphs, items };
}
