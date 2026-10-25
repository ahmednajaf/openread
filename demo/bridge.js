// Development adapter only. The shipped extension uses browser.* APIs.
(() => {
  // Native-extension smoke test: the toolbar injects the real extension here.
  if (new URLSearchParams(location.search).has('extension')) {
    document.querySelector('#launch').hidden = true;
    return;
  }
  // Let browser tests inspect the fixture; production uses a closed shadow root.
  const attachShadow = Element.prototype.attachShadow;
  Element.prototype.attachShadow = function (options) { return attachShadow.call(this, this.hasAttribute("data-openread-host") ? { ...options, mode: "open" } : options); };
  const prefix = "openread-demo-";
  window.browser = {
    runtime: {
      getURL: (file) => `/extension/${file}`,
      sendMessage: async (message) => {
        if (['playbackState', 'openread:state'].includes(message.type)) return { ok: true };
        if (message.type === 'openWorkspace') { window.open('http://127.0.0.1:8765/', '_blank'); return { ok: true }; }
        if (message.type === 'saveDocument') {
          try {
            const response = await fetch('http://127.0.0.1:8765/library/save', { method: 'POST', headers: { 'X-OpenRead': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ title: message.title, text: message.text, source: location.href }) });
            const result = await response.json(); if (response.ok) window.open('http://127.0.0.1:8765/?id=' + encodeURIComponent(result.id), '_blank');
            return { ok: response.ok, ...result };
          } catch { return { ok: false, error: 'Start the local helper to save this reading.' }; }
        }
        try {
          const response = await fetch(`http://127.0.0.1:8765/${message.type === "health" ? "health" : "synthesize"}`, {
            method: message.type === "health" ? "GET" : "POST",
            headers: { "X-OpenRead": "1", "Content-Type": "application/json" },
            ...(message.type !== "health" ? { body: JSON.stringify({ text: message.text, voice: message.voice || 'af_heart' }) } : {}),
            signal: AbortSignal.timeout(message.type === "health" ? 2500 : 90000)
          });
          return { ok: response.ok, ...await response.json() };
        } catch { return { ok: false, error: "Natural voices aren't connected. Start .venv/bin/python voice/server.py --allow-preview." }; }
      }
    },
    storage: { local: {
      get: async (key) => ({ [key]: JSON.parse(localStorage.getItem(prefix + key) || "null") }),
      set: async (values) => { for (const [key, value] of Object.entries(values)) localStorage.setItem(prefix + key, JSON.stringify(value)); }
    } }
  };
  function launch() { const script = document.createElement("script"); script.src = "/extension/content.js"; document.head.append(script); script.onload = () => script.remove(); }
  document.querySelector("#launch").addEventListener("click", launch);
  window.addEventListener("DOMContentLoaded", launch, { once: true });
})();
