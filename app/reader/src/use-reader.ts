import { useEffect, useMemo, useRef, useState } from 'react';
import { api } from './api';
import { readingLayout } from './layout';
export type Reading = { id?: string; title: string; text: string; source?: string; position?: number; author?: string; book?: string; chapter?: string; sample?: boolean; bookmarks?: { position: number; label: string }[] };
export function useReader(reading: Reading, voice: string, rate: number, follow: boolean, highlight: boolean) {
  const player = useRef<LocalPlayer | null>(null);
  const layout = useMemo(() => readingLayout(reading.text, OpenReadCore.passages(reading.text)), [reading.text]);
  const article = useRef<HTMLElement | null>(null);
  const options = useRef({ follow, highlight }); options.current = { follow, highlight };
  const [phase, setPhase] = useState<Phase>({ index: 0, total: 0, status: 'idle' });
  const owner = useRef(reading); const [phaseReading, setPhaseReading] = useState<Reading | null>(null);
  const [rects, setRects] = useState<{ left: number; top: number; width: number; height: number }[]>([]);
  const [error, setError] = useState(''); const [progress, setProgress] = useState(0);
  const range = useRef<Range | null>(null);
  const paint = () => setRects(!options.current.highlight || !range.current ? [] : [...range.current.getClientRects()].map(r => ({ left: r.left - 2, top: r.top + 1, width: r.width + 4, height: r.height - 2 })));
  useEffect(() => {
    let alive = true;
    const clear = () => { range.current = null; if (alive) setRects([]); };
    player.current = new OpenReadPlayer({ AudioClass: Audio,
      request: async message => ({ ok: true, ...await api<Omit<Speech, 'ok'>>('/synthesize', { text: message.text, voice: message.voice }) }),
      onChange: state => { if (alive) { setPhase(state); setPhaseReading(owner.current); } if (state.status !== 'playing') clear(); },
      onWordClear: clear, onError: message => { if (alive) setError(message); },
      onWord: (offset, length) => {
        const item = player.current?.items[player.current.index];
        if (!item) return;
        const start = item.offsets?.[offset] ?? (item.start || 0) + offset;
        const end = item.offsets?.[offset + length] ?? start + length;
        const p = article.current?.children[item.paragraph || 0]; const node = p?.firstChild;
        if (!node || node.nodeType !== Node.TEXT_NODE || end > (node.textContent?.length || 0)) return;
        const next = document.createRange(); next.setStart(node, start); next.setEnd(node, end); range.current = next; paint();
        const rect = next.getBoundingClientRect();
        if (options.current.follow && (rect.top < 120 || rect.bottom > innerHeight - 150)) window.scrollBy({ top: rect.top - innerHeight * .4, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' });
      },
    });
    const reposition = () => paint(); window.addEventListener('scroll', reposition, { passive: true }); window.addEventListener('resize', reposition);
    return () => { alive = false; player.current?.destroy(); window.removeEventListener('scroll', reposition); window.removeEventListener('resize', reposition); };
  }, []);
  useEffect(() => { owner.current = reading; setError(''); player.current?.load(layout.items); if (reading.position) player.current?.seek(Math.min(reading.position, layout.items.length - 1), false); setProgress(0); }, [layout, reading.id]);
  useEffect(() => { player.current?.configure({ voice, rate }); }, [voice, rate]);
  useEffect(() => { paint(); }, [highlight]);
  useEffect(() => {
    const interval = setInterval(() => {
      const p = player.current; const a = p?.audio;
      const fraction = p && ['playing', 'paused'].includes(p.status) && p.ready && a?.duration ? Math.min(1, a.currentTime / a.duration) : 0;
      setProgress(p?.status === 'ended' ? 1 : p?.items.length ? (p.index + fraction) / p.items.length : 0);
    }, 250); return () => clearInterval(interval);
  }, []);
  return { article, player, phase, rects, error, setError, progress, isCurrent: phaseReading?.text === reading.text && phaseReading?.id === reading.id, paragraphs: layout.paragraphs,
    toggle() { setError(''); if (['playing', 'loading'].includes(player.current?.status || '')) player.current?.pause(); else void player.current?.play(); },
  };
}
