/* Extract speech and retain an exact map back to the original DOM. */
(() => {
  const SKIP = 'nav,aside,footer,form,script,style,noscript,button,textarea,input,select,pre,svg,canvas,[hidden],[aria-hidden="true"],[inert],[contenteditable="true"],[role="textbox"],[role="button"],a[rel~="author"],.monaco-editor,.CodeMirror,.cm-editor,[role="navigation"],[role="menu"],[role="toolbar"],[role="dialog"],[role="complementary"],[data-openread-host],[data-nosnippet]';
  const BLOCK = 'h1,h2,h3,h4,h5,h6,p,li,blockquote,td,dt,dd,figcaption';
  const NOISE = /(?:^|[-_\s])(?:advert(?:isement)?|ad-slot|cookie|newsletter|social|share|related|recommended|breadcrumbs?|pagination|subscribe|promo|byline|author|metadata|(?:article|post|entry)-meta|reading-time|read-time|reading-duration|kicker|eyebrow|dateline)(?:$|[-_\s])/iu;
  const READ_TIME = /^(?:(?:estimated\s+)?(?:reading\s+time|time\s+to\s+read)\s*[:·—–-]?\s*)?(?:\d+(?:[.,]\d+)?|one|two|three|four|five|six|seven|eight|nine|ten)\s*(?:min(?:ute)?s?|hours?|hrs?)\s*(?:(?:to\s+)?read(?:ing)?)?\s*[.!]?$/iu;
  const URL = /(?:https?:\/\/|www\.)[^\s]+/giu;
  // WhatsApp's DOM is private and can change. Fail closed to an empty chat,
  // rather than falling back to reading navigation or another conversation.
  const CHAT_SKIP = 'button,input,textarea,select,script,style,svg,[role="button"],[role="textbox"],[contenteditable="true"],[data-testid="quoted-message"],[data-testid="quoted-message-container"],[data-testid="quoted-msg"],[data-testid="msg-meta"],[data-testid="reactions"],[data-icon],[hidden],[aria-hidden="true"],[inert]';
  const chatAvailable = doc => doc.location?.hostname === 'web.whatsapp.com';
  function chatIdentity(doc) {
    const root = doc.querySelector('#main');
    const heading = root?.querySelector('header [data-testid="conversation-info-header-chat-title"]')
      || root?.querySelector('header span[title]') || root?.querySelector('header [dir="auto"]');
    return { root, title: globalThis.OpenReadCore.normalize(heading?.getAttribute('title') || heading?.textContent || 'WhatsApp conversation') };
  }
  function extract(doc = document, options = {}) {
    const { normalize, words, chunks } = globalThis.OpenReadCore;
    const { selection = null, mode = 'page', announceSenders = true } = options;
    const chat = mode === 'chat';
    const view = doc.defaultView; const visibility = new WeakMap();
    function metadata(el) {
      const label = `${el.id} ${el.getAttribute('class') || ''} ${el.getAttribute('data-testid') || ''}`.replace(/([a-z\d])([A-Z])/gu, '$1-$2');
      if (NOISE.test(label)) return true;
      // Only discard a standalone duration label, never words inside prose such
      // as "wait 4 minutes", nor headings or list content about durations.
      if (el.matches('h1,h2,h3,h4,h5,h6,li,blockquote,td') || el.querySelector(BLOCK)) return false;
      const text = normalize(el.textContent);
      if (text.length > 90 || !READ_TIME.test(text)) return false;
      const prose = el.parentElement?.closest('p,li,blockquote,td');
      return !prose || normalize(prose.textContent) === text;
    }
    function eligible(el) {
      if (!el || el === doc.documentElement) return true;
      if (visibility.has(el)) return visibility.get(el);
      const header = el.tagName === 'HEADER' && !el.closest('article,main,[role="main"]');
      const style = view.getComputedStyle(el);
      const okay = !el.matches(chat ? CHAT_SKIP : SKIP) && (chat || !header) && (chat || selection || !metadata(el))
        && style.display !== 'none' && style.visibility !== 'hidden' && style.visibility !== 'collapse'
        && style.opacity !== '0' && style.contentVisibility !== 'hidden' && eligible(el.parentElement);
      visibility.set(el, okay); return okay;
    }
    function collect(root, range) {
      const groups = []; const walker = doc.createTreeWalker(root, chat ? 5 : 4); let group;
      const heading = !chat && !range && [...root.querySelectorAll('h1')].find(eligible);
      while (walker.nextNode()) {
        const node = walker.currentNode;
        if (node.nodeType === 1) {
          if (eligible(node) && group && (node.tagName === 'BR' || node.matches('div,p,li'))) group.pieces.push({ lineBreak: true });
          continue;
        }
        if (!eligible(node.parentElement) || !node.parentElement.getClientRects().length) continue;
        if (heading && !heading.contains(node) && (node.compareDocumentPosition(heading) & 4)) continue;
        if (range && !range.intersectsNode(node)) continue;
        const from = range?.startContainer === node ? range.startOffset : 0;
        const to = range?.endContainer === node ? range.endOffset : node.length;
        if (from >= to) continue;
        const block = chat ? root : node.parentElement.closest(BLOCK) || node.parentElement;
        // Consecutive groups preserve parent text, nested bullets and trailing text.
        if (!group || group.element !== block) {
          group = { element: block, pieces: [], kind: block.closest('li') ? 'list' : 'prose' }; groups.push(group);
        }
        const value = node.data.slice(from, to); let cursor = 0;
        for (const match of value.matchAll(URL)) {
          if (match.index > cursor) group.pieces.push({ node, from: from + cursor, to: from + match.index });
          cursor = match.index + match[0].length;
        }
        if (cursor < value.length) group.pieces.push({ node, from: from + cursor, to });
      }
      return groups.map((group) => {
        let text = ''; const runs = []; let gap = null;
        for (const piece of group.pieces) {
          if (piece.lineBreak) { if (text) gap = { node: null }; continue; }
          const value = piece.node.data.slice(piece.from, piece.to);
          for (const match of value.matchAll(/\s+|\S+/gu)) {
            const from = piece.from + match.index;
            if (/^\s/u.test(match[0])) { if (text) gap = { node: piece.node, from, to: from + 1 }; continue; }
            if (gap) { if (gap.node) runs.push({ ...gap, start: text.length, end: text.length + 1, snapshot: gap.node.data }); text += ' '; gap = null; }
            runs.push({ node: piece.node, from, to: from + match[0].length, start: text.length, end: text.length + match[0].length, snapshot: piece.node.data });
            text += match[0];
          }
        }
        return { text, runs, element: group.element, kind: group.kind };
      }).filter((group) => group.text && /[\p{L}\p{N}]/u.test(group.text));
    }
    let root; let groups; let identity; let messageCount = 0;
    if (chat) {
      identity = chatIdentity(doc); root = identity.root; groups = [];
      if (chatAvailable(doc) && root && eligible(root)) {
        // DOM order is the conversation order. Only loaded message bodies are
        // collected: no sidebar, date separators, receipts, captions on buttons,
        // composer drafts, or quoted copies of an earlier message.
        const envelopes = [...root.querySelectorAll('[data-pre-plain-text]')]
          .filter(el => !el.parentElement.closest('[data-pre-plain-text]') && eligible(el));
        for (const envelope of envelopes) {
          const bodies = [...envelope.querySelectorAll('.selectable-text')]
            .filter(el => !el.parentElement.closest('.selectable-text') && eligible(el));
          const parts = bodies.flatMap(body => collect(body));
          if (!parts.length) continue;
          const header = envelope.getAttribute('data-pre-plain-text') || '';
          const name = normalize(header.match(/^\[[^\]]*\]\s*([\s\S]+):\s*$/u)?.[1] || '');
          const sender = envelope.closest('.message-out') ? 'You' : name;
          const prefix = announceSenders ? sender === 'You' ? 'You said: ' : sender ? `${sender} says: ` : 'Message: ' : '';
          let text = prefix; const runs = [];
          for (const part of parts) {
            if (text.length > prefix.length) text += ' ';
            const shift = text.length;
            runs.push(...part.runs.map(run => ({ ...run, start: run.start + shift, end: run.end + shift })));
            text += part.text;
          }
          messageCount++;
          groups.push({ text, runs, element: envelope, kind: 'chat', sender, chatHeader: header, speechPrefixLength: prefix.length });
        }
      }
    } else if (selection && !selection.collapsed) {
      root = selection.commonAncestorContainer.nodeType === 3 ? selection.commonAncestorContainer.parentElement : selection.commonAncestorContainer;
      groups = collect(root, selection);
    } else {
      const roots = [...doc.querySelectorAll('article,main,[role="main"]')].filter(eligible);
      const scored = roots.map((candidate) => {
        const groups = collect(candidate);
        return { root: candidate, groups, score: words(groups.map((g) => g.text).join(' ')) * (candidate.tagName === 'ARTICLE' ? 1.2 : 1) };
      }).sort((a, b) => b.score - a.score);
      root = scored[0]?.score > 0 ? scored[0].root : doc.body;
      groups = scored[0]?.score > 0 ? scored[0].groups : collect(root);
    }
    const heading = root?.querySelector?.('h1') || doc.querySelector('h1');
    const title = chat ? identity.title : selection ? 'Selected text' : normalize(heading?.innerText || heading?.textContent || doc.title || 'This page');
    const lang = root?.lang || doc.documentElement.lang || 'en';
    const items = groups.flatMap((block, paragraph) => chunks(block.text, lang).map((chunk) => ({
      ...chunk, paragraph, kind: block.kind, element: block.element, runs: block.runs,
      blockStart: chunk.start, blockEnd: chunk.end, ...(chat ? { speechPrefixLength: block.speechPrefixLength, chatHeader: block.chatHeader } : {})
    })));
    return { title, lang, source: chat ? 'chat' : selection ? 'selection' : 'page', text: groups.map((g) => g.text).join('\n\n'), items, blocks: groups,
      ...(chat ? { messageCount, chatRoot: identity.root } : {}) };
  }
  function rangesFor(item, offset, length, doc = document) {
    const start = item.blockStart + offset; const end = Math.min(item.blockEnd, start + length); const ranges = [];
    for (const run of item.runs || []) {
      const a = Math.max(run.start, start); const b = Math.min(run.end, end);
      if (a >= b) continue;
      if (!run.node.isConnected || run.node.data !== run.snapshot) return [];
      const range = doc.createRange();
      range.setStart(run.node, run.from + a - run.start); range.setEnd(run.node, run.from + b - run.start); ranges.push(range);
    }
    return ranges;
  }
  globalThis.OpenReadExtract = extract; globalThis.OpenReadRanges = rangesFor;
  globalThis.OpenReadChat = { available: chatAvailable, identity: chatIdentity };
})();
