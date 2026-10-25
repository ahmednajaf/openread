type Voice = { id: string; name: string; lang: string; detail: string; pack?: string };
type Passage = { text: string; paragraph?: number; start?: number; offsets?: number[] };
type Phase = { index: number; total: number; status: string };
type Word = { offset: number; length: number; start: number; end: number };
type Speech = { ok: boolean; audio: string; words: Word[]; error?: string };
type LocalPlayer = {
  items: Passage[]; index: number; status: string; audio?: HTMLAudioElement; rate: number; ready: boolean;
  load(items: Passage[], lang?: string): void; play(): Promise<void>; pause(): void;
  seek(index: number, autoplay?: boolean): void; stop(): void; destroy(): void;
  configure(options: { voice?: string; rate?: number }): void;
};
declare const OpenReadCore: { voices: Voice[]; defaultVoice: string; passages(text: string, lang?: string): Passage[]; words(text: string): number; voiceGroups(): { label: string; voices: Voice[] }[] };
declare const OpenReadPlayer: { new(options: { request: (message: { text: string; voice: string }) => Promise<Speech>; AudioClass: typeof Audio; onChange?: (phase: Phase) => void; onWord?: (offset: number, length: number) => void; onWordClear?: () => void; onError: (message: string) => void }): LocalPlayer };
