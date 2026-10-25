import * as React from 'react';
import { Mic, Upload, Copy, BookOpen, Sparkles, Square } from 'lucide-react';
import { Button } from '@/app/shared/components/ui/button';
import { job } from './api';
import { filePayload } from './files';
import type { Reading } from './use-reader';

export function Dictation({ report, openReading, beforeAudio, active }: { report: (text: string) => void; openReading: (r: Reading) => void; beforeAudio: () => void; active: boolean }) {
  const [transcript, setTranscript] = React.useState(''); const [notes, setNotes] = React.useState('');
  const [busy, setBusy] = React.useState(''); const [recording, setRecording] = React.useState(false);
  const recorder = React.useRef<MediaRecorder | null>(null); const abort = React.useRef<AbortController | null>(null);
  const timer = React.useRef<ReturnType<typeof setTimeout> | null>(null); const input = React.useRef<HTMLInputElement>(null);
  React.useEffect(() => { if (!active && recorder.current?.state === 'recording') recorder.current.stop(); }, [active]);
  React.useEffect(() => () => { abort.current?.abort(); if (timer.current) clearTimeout(timer.current); if (recorder.current) { recorder.current.onstop = null; if (recorder.current.state === 'recording') recorder.current.stop(); recorder.current.stream.getTracks().forEach(t => t.stop()); } }, []);
  const transcribe = async (file: File) => {
    const controller = new AbortController(); abort.current = controller; setBusy('Transcribing locally…');
    try { const result = await job('/transcribe', await filePayload(file), setBusy, controller.signal); setTranscript(result.text); setNotes(''); }
    catch (e) { if (!controller.signal.aborted) report((e as Error).message); } finally { setBusy(''); }
  };
  const record = async () => {
    if (recorder.current?.state === 'recording') { recorder.current.stop(); return; }
    try {
      if (!navigator.mediaDevices?.getUserMedia || !globalThis.MediaRecorder) throw new Error('Recording is unavailable here. Import an audio file instead.');
      beforeAudio(); const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      try {
        const mimeType = ['audio/webm;codecs=opus', 'audio/mp4'].find(t => MediaRecorder.isTypeSupported(t));
        const capture = new MediaRecorder(stream, mimeType ? { mimeType } : {}); recorder.current = capture;
        const chunks: Blob[] = []; let size = 0;
        capture.ondataavailable = e => { chunks.push(e.data); size += e.data.size; if (size > 19 * 1024 * 1024 && capture.state === 'recording') capture.stop(); };
        capture.onstop = () => { if (timer.current) clearTimeout(timer.current); stream.getTracks().forEach(t => t.stop()); setRecording(false); void transcribe(new File(chunks, mimeType?.includes('mp4') ? 'recording.m4a' : 'recording.webm', { type: capture.mimeType })); };
        capture.onerror = () => { capture.onstop = null; stream.getTracks().forEach(t => t.stop()); setRecording(false); report('Recording failed. Try importing audio.'); };
        capture.start(1000); setRecording(true); timer.current = setTimeout(() => { if (capture.state === 'recording') capture.stop(); }, 3600000);
      } catch (e) { stream.getTracks().forEach(t => t.stop()); throw e; }
    } catch (e) { report((e as Error).message); }
  };
  const makeNotes = async () => {
    const controller = new AbortController(); abort.current = controller; setBusy('Finding the main points…');
    try { const result = await job('/ai', { mode: 'notes', text: transcript }, setBusy, controller.signal); setNotes(result.text); }
    catch (e) { if (!controller.signal.aborted) report((e as Error).message); } finally { setBusy(''); }
  };
  return <div><div className="tool-intro"><span className="tool-symbol"><Mic size={28}/></span><h3>Start with your voice.</h3><p>Record or import audio. Local Whisper turns it into text.</p></div><div className="library-actions"><Button disabled={!!busy} onClick={() => void record()}>{recording ? <Square size={15}/> : <Mic size={15}/>} {recording ? 'Stop recording' : 'Start recording'}</Button><Button disabled={!!busy || recording} onClick={() => input.current?.click()}><Upload size={15}/> Import audio</Button></div><input ref={input} hidden type="file" accept="audio/*,.mp4,.webm,.m4a,.wav,.mp3" aria-label="Import audio file" onChange={e => { if (e.target.files?.[0]) void transcribe(e.target.files[0]); e.target.value = ''; }}/>{busy && <div className="job-progress"><p>{busy}</p><button onClick={() => abort.current?.abort()}>Cancel</button></div>}{transcript && <div className="tool-result"><p>{transcript}</p><div className="result-actions"><Button onClick={() => void navigator.clipboard.writeText(transcript).then(() => report('Transcript copied.')).catch(() => report('Select the text to copy it.'))}><Copy size={14}/> Copy</Button><Button onClick={() => openReading({ title: 'Your transcript', text: transcript, source: 'Local dictation' })}><BookOpen size={14}/> Read</Button><Button disabled={!!busy} onClick={() => void makeNotes()}><Sparkles size={14}/> Meeting notes</Button></div></div>}{notes && <div className="tool-result"><p>{notes}</p></div>}<p className="panel-footnote">Up to 20 MB / one hour. Closing this panel stops recording.</p></div>;
}
