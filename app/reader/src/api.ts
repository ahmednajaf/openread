const prefix = document.querySelector<HTMLMetaElement>('meta[name="openread-api-prefix"]')?.content === '/api' ? '/api' : '';
export async function api<T = any>(path: string, body?: unknown, signal?: AbortSignal): Promise<T> {
  const response = await fetch(prefix + path, {
    method: body === undefined ? 'GET' : 'POST', signal,
    headers: { 'X-OpenRead': '1', ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Your local helper is unavailable.');
  return data;
}
export async function job(path: string, body: unknown, progress: (text: string) => void, signal?: AbortSignal) {
  const { id } = await api(path, body, signal);
  const cancel = () => { void api('/jobs/cancel', { id }).catch(() => {}); };
  signal?.addEventListener('abort', cancel, { once: true });
  try {
    while (!signal?.aborted) {
      const state = await api('/jobs/' + id, undefined, signal);
      progress(state.message || 'Working on your device…');
      if (state.status === 'done') { await api('/jobs/' + id + '?consume=1'); return state.result; }
      if (state.status === 'error' || state.status === 'cancelled') throw new Error(state.message);
      await new Promise(resolve => setTimeout(resolve, 650));
    }
    throw new Error('Cancelled.');
  } finally { signal?.removeEventListener('abort', cancel); }
}
