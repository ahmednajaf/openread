import * as React from 'react';
import { api, job } from './api';
import { filePayload } from './files';
import { Button } from '@/app/shared/components/ui/button';

async function referenceWav(file: File) {
  if (file.size > 20 * 1024 * 1024) throw new Error('Choose an audio sample under 20 MB.');
  const context = new AudioContext();
  try {
    const decoded = await context.decodeAudioData(await file.arrayBuffer());
    if (decoded.duration < 3 || decoded.duration > 30) throw new Error('Choose a voice sample between 3 and 30 seconds.');
    const offline = new OfflineAudioContext(1, Math.ceil(decoded.duration * 24000), 24000);
    const source = offline.createBufferSource(); source.buffer = decoded; source.connect(offline.destination); source.start();
    const audio = (await offline.startRendering()).getChannelData(0);
    const data = new ArrayBuffer(44 + audio.length * 2); const view = new DataView(data);
    const ascii = (at: number, value: string) => [...value].forEach((letter, index) => view.setUint8(at + index, letter.charCodeAt(0)));
    ascii(0, 'RIFF'); view.setUint32(4, data.byteLength - 8, true); ascii(8, 'WAVEfmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true); view.setUint32(24, 24000, true); view.setUint32(28, 48000, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true); ascii(36, 'data'); view.setUint32(40, audio.length * 2, true);
    audio.forEach((sample, index) => view.setInt16(44 + index * 2, Math.max(-1, Math.min(1, sample)) * 32767, true));
    return filePayload(new File([data], 'reference.wav', { type: 'audio/wav' }));
  } finally { await context.close(); }
}

export function QwenVoices({ health, direction, setDirection, changed, choose, pause }: { health: any; direction: string; setDirection: (value: string) => void; changed: () => Promise<void>; choose: (voice: string) => void; pause: () => void }) {
  const [busy, setBusy] = React.useState(''); const [error, setError] = React.useState(''); const [draft, setDraft] = React.useState(direction);
  const [name, setName] = React.useState(''); const [transcript, setTranscript] = React.useState(''); const [sample, setSample] = React.useState<File | null>(null); const [permission, setPermission] = React.useState(false);
  const run = async (operation: () => Promise<void>) => { pause(); setError(''); try { await operation(); await changed(); } catch (error) { setError((error as Error).message); } finally { setBusy(''); } };
  return <details className="qwen-tools"><summary>Optional Qwen voice packs & personal voices</summary><p className="setting-note">Optional expressive narration and personal voices. Generated locally, with larger downloads and higher memory use. Word highlighting is estimated.</p>
    <div className="library-actions"><Button disabled={!!busy} onClick={() => void run(async () => { setBusy('Preparing Qwen…'); await job('/qwen/setup', { pack: 'expressive' }, setBusy); })}>Add expressive voices · up to 1.44 GB</Button><Button disabled={!!busy} onClick={() => void run(async () => { setBusy('Preparing Qwen…'); await job('/qwen/setup', { pack: 'clone' }, setBusy); })}>Add voice cloning · up to 884 MB</Button></div>
    <label className="field-label" htmlFor="qwen-direction">Narration direction</label><input id="qwen-direction" className="text-input" value={draft} onChange={e => setDraft(e.target.value)} maxLength={500} placeholder="Warm, unhurried storytelling"/><Button disabled={!!busy} onClick={() => { pause(); setDirection(draft); }}>Apply direction</Button>
    <h3>Create a personal voice</h3><form onSubmit={event => { event.preventDefault(); if (!sample) return; void run(async () => { setBusy('Preparing your voice sample…'); const payload = await referenceWav(sample); const profile = await job('/qwen/clone', { ...payload, title: name, transcript, permission }, setBusy); await changed(); choose(profile.id); setName(''); setTranscript(''); setSample(null); setPermission(false); }); }}>
      <label className="field-label" htmlFor="qwen-name">Voice name</label><input id="qwen-name" className="text-input" value={name} onChange={e => setName(e.target.value)} maxLength={80} required/>
      <label className="field-label" htmlFor="qwen-sample">A clear 3–30 second audio sample</label><input id="qwen-sample" type="file" accept="audio/*" onChange={e => setSample(e.target.files?.[0] || null)} required/>
      <label className="field-label" htmlFor="qwen-transcript">Optional transcript · closer delivery, slower</label><textarea id="qwen-transcript" value={transcript} onChange={e => setTranscript(e.target.value)} maxLength={2000}/>
      <label className="setting-note"><input type="checkbox" checked={permission} onChange={e => setPermission(e.target.checked)} required/> This is my voice, or I have permission to clone it.</label>
      <p className="setting-note">Leave the transcript blank for faster reading. Add the exact words for closer reference delivery, which takes longer. Your sample is processed locally. OpenRead keeps the prepared voice profile and discards its temporary audio copy.</p>
      <Button type="submit" disabled={!!busy || !sample || !permission || !name.trim()}>Create personal voice</Button>
    </form>
    {(health?.voices || []).filter((voice: any) => voice.pack === 'qwen-clone').map((voice: any) => <div className="library-actions" key={voice.id}><Button onClick={() => choose(voice.id)}>{voice.name}</Button><Button disabled={!!busy} onClick={() => void run(async () => { setBusy('Removing voice…'); await api('/qwen/delete', { id: voice.id }); })}>Delete voice</Button></div>)}
    {!!busy && <p role="status" className="setting-note">{busy}</p>}{!!error && <p role="alert" className="setting-note">{error}</p>}
  </details>;
}
