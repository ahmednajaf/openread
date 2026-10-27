import { api } from './api';
import { validChapters } from './layout';

export function download(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a'); link.href = url;
  link.download = filename.replace(/[<>:"/\\|?*\u0000-\u001f]/g, '').slice(0, 120) || 'openread';
  link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}
export function audioBlob(audio: string) {
  return new Blob([Uint8Array.from(atob(audio), c => c.charCodeAt(0))], { type: 'audio/wav' });
}
export async function filePayload(file: File) {
  if (file.size > 100 * 1024 * 1024) throw new Error('Choose a file under 100 MB.');
  const data = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader(); reader.onload = () => resolve(String(reader.result).split(',')[1]); reader.onerror = reject; reader.readAsDataURL(file);
  });
  return { name: file.name, data };
}
export async function backupLibrary() {
  const { documents: entries } = await api('/library');
  const documents = [];
  for (const entry of entries) documents.push(await api('/library/' + entry.id));
  download(new Blob([JSON.stringify({ format: 'openread-library-v1', documents }, null, 2)], { type: 'application/json' }), 'openread-library.json');
}
export async function restoreLibrary(file: File) {
  if (file.size > 500 * 1024 * 1024) throw new Error('Choose a backup under 500 MB.');
  const backup = JSON.parse(await file.text());
  if (backup.format !== 'openread-library-v1' || !Array.isArray(backup.documents) || backup.documents.length > 200) throw new Error('This is not an OpenRead library backup.');
  // Validate the complete backup before writing any entries.
  for (const d of backup.documents) {
    if (!d || typeof d.text !== 'string' || !d.text.trim() || d.text.length > 20000000 || typeof d.title !== 'string' || d.title.length > 240 || (d.id !== undefined && (typeof d.id !== 'string' || d.id.length > 80)) || (d.source !== undefined && (typeof d.source !== 'string' || d.source.length > 1000)) || !Number.isInteger(d.position ?? 0) || (d.position ?? 0) < 0 || (d.position ?? 0) > 20000000 || !Array.isArray(d.bookmarks || []) || (d.bookmarks || []).length > 200 || (d.bookmarks || []).some((m: any) => !m || !Number.isInteger(m.position) || m.position < 0 || m.position > 20000000 || typeof m.label !== 'string' || m.label.length > 160)) throw new Error('The backup contains an invalid reading. Nothing has been restored.');
    if (!validChapters(d.chapters === undefined ? [] : d.chapters, d.text)) throw new Error('The backup contains invalid chapters. Nothing has been restored.');
  }
  for (const d of backup.documents) await api('/library/save', d);
}
