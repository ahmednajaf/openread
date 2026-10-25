(() => {
  class Highlighter {
    constructor({ layer, follow = true, onStale = () => {} }) {
      Object.assign(this, { layer, follow, onStale }); this.lastScroll = 0; this.current = null;
      // A single overlay avoids Safari retaining old CSS Custom Highlight paints.
      // It never wraps or edits the page's text and owns only the current word.
      globalThis.CSS?.highlights?.delete('openread-word');
      this.reposition = () => { if (this.current) this.paint(this.current); };
      window.addEventListener('scroll', this.reposition, { passive: true, capture: true }); window.addEventListener('resize', this.reposition);
    }
    show(item, offset, length) {
      // Spoken sender introductions have no corresponding words in the bubble.
      if (item.kind === 'chat' && item.blockStart + offset < item.speechPrefixLength) { this.clear(); return; }
      const ranges = globalThis.OpenReadRanges(item, offset, length);
      if (!ranges.length) { this.clear(); if (item.runs?.length) this.onStale(); return; }
      this.current = ranges;
      this.paint(ranges);
      const rect = ranges[0].getBoundingClientRect();
      if (this.follow && (rect.top < 70 || rect.bottom > window.innerHeight - 70) && Date.now() - this.lastScroll > 800) {
        this.lastScroll = Date.now();
        if (item.kind === 'chat') ranges[0].startContainer.parentElement?.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        else window.scrollBy({ top: rect.top - window.innerHeight * .42, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' });
      }
    }
    paint(ranges) {
      const fragment = document.createDocumentFragment();
      for (const range of ranges) for (const rect of range.getClientRects()) {
        if (!rect.width || !rect.height) continue;
        const mark = document.createElement('span'); mark.className = 'word-marker';
        Object.assign(mark.style, { left: `${rect.left - 2}px`, top: `${rect.top}px`, width: `${rect.width + 4}px`, height: `${rect.height}px` }); fragment.append(mark);
      }
      this.layer.replaceChildren(fragment);
    }
    clear() { this.current = null; globalThis.CSS?.highlights?.delete('openread-word'); this.layer.replaceChildren(); }
    destroy() { this.clear(); window.removeEventListener('scroll', this.reposition, true); window.removeEventListener('resize', this.reposition); }
  }
  globalThis.OpenReadHighlighter = Highlighter;
})();
