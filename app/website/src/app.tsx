import * as React from 'react';
import { createRoot } from 'react-dom/client';
import { ArrowDown, ArrowDownToLine, ArrowRight, ArrowUpRight, AudioLines, Check, ChevronRight, Code2, Coffee, Headphones, LockKeyhole, Monitor, Pause, Play, Volume2, X } from 'lucide-react';
import GlassHeadlineHero from '@/app/shared/components/ui/glass-headline-hero';
import sample from './sample.json';

const REPO = 'https://github.com/ahmednajaf/openread';
const DOWNLOAD = REPO + '/archive/refs/heads/master.zip';
const SUPPORT = 'https://ko-fi.com/pickledjones';
const words = Array.from(sample.text.matchAll(/\S+|\s+/gu));
const palette = ['#100D20', '#FF794F', '#E9A2CC', '#4541CF', '#FFE2B5'];

function Brand() { return <a className="brand" href="#top" aria-label="OpenRead home"><img src="/icon.png" width="31" height="31" alt=""/><span>openread<span className="brand-dot">.</span></span></a>; }

function App() {
  const audio = React.useRef<HTMLAudioElement>(null); const video = React.useRef<HTMLVideoElement>(null); const dialog = React.useRef<HTMLDialogElement>(null);
  const [playing, setPlaying] = React.useState(false); const [time, setTime] = React.useState(0); const [error, setError] = React.useState(''); const [showVideo, setShowVideo] = React.useState(false);
  const [browser, setBrowser] = React.useState<'safari' | 'chrome'>('chrome');
  React.useEffect(() => {
    if (!playing) return;
    let frame: number;
    const paint = () => { setTime(audio.current?.currentTime || 0); frame = requestAnimationFrame(paint); }; paint();
    return () => cancelAnimationFrame(frame);
  }, [playing]);
  React.useEffect(() => {
    if (!showVideo) return;
    audio.current?.pause(); const node = dialog.current!; node.showModal();
    return () => { video.current?.pause(); node.close(); };
  }, [showVideo]);
  const toggle = async () => {
    const player = audio.current!; setError('');
    if (!player.paused) player.pause();
    else { if (player.ended || player.currentTime >= sample.duration) player.currentTime = 0; try { await player.play(); } catch { setError('The sample could not play. Try the video instead.'); } }
  };
  const current = playing ? sample.words.slice().reverse().find(w => time >= w.start && time < w.end) : null;
  const minutes = (value: number) => `0:${Math.floor(value).toString().padStart(2, '0')}`;
  return <>
    <div className="hero-shell" id="top">
      <header className="navigation glass"><Brand/><nav aria-label="Main navigation"><a href="#demo" className="nav-link">Hear it</a><a className="nav-github" href={REPO} target="_blank" rel="noreferrer" aria-label="GitHub repository"><Code2 size={18}/></a><a className="nav-install" href="#install">Get OpenRead <ArrowDownToLine size={14}/></a></nav></header>
      <GlassHeadlineHero className="public-hero" title="Your words. Your rhythm." eyebrow="Free, by design" description="A natural voice. A little more focus. Reading support that belongs to you, without another subscription." primaryAction={{ label:'Install on Chrome', href:'#install' }} secondaryAction={{ label:'Hear it for yourself', href:'#demo' }} colors={palette} height="max(760px, 100svh)"/>
      <div className="hero-foot"><span><LockKeyhole size={12}/> On your device</span><i/><span>Safari & Chrome on Mac</span><i/><a href={REPO} target="_blank" rel="noreferrer">Free & open source <ArrowUpRight size={12}/></a></div>
      <a className="scroll-cue" href="#demo" aria-label="Explore OpenRead"><ArrowDown size={16}/></a>
    </div>

    <main>
      <section className="demo-section section-wrap" id="demo" aria-labelledby="demo-heading">
        <div className="section-intro"><span className="eyebrow">A LITTLE LESS EFFORT</span><h2 id="demo-heading">Let the words<br/><em>come to you.</em></h2><p>Hear Kiki read the opening of The Odyssey.<br/>No installation needed for this recorded sample.</p></div>
        <div className="sample-stage">
          <div className="sample-aura" aria-hidden="true"/>
          <article className="sample-paper"><div className="sample-book"><span className="book-spine">I</span><span>THE ODYSSEY<small>Homer · Book I</small></span><Headphones size={18}/></div><h3>Athene Visits<br/>Telemachus</h3><p className="sample-text">{words.map(m => /^\s+$/u.test(m[0]) ? m[0] : <span key={m.index} className={current?.offset === m.index ? 'read-word current-word' : 'read-word'}>{m[0]}</span>)}</p><span className="sample-end" aria-hidden="true">✧</span></article>
          <div className="sample-player glass"><div className="sample-voice"><span className="voice-orb"><AudioLines size={22}/></span><span><strong>Kiki <span>· Kitten TTS</span></strong><small>Recorded on a Mac, using OpenRead</small></span></div><button className="sample-play" aria-label={playing ? 'Pause Kiki sample' : 'Play Kiki sample'} onClick={() => void toggle()}>{playing ? <Pause size={19} fill="currentColor"/> : <Play size={19} fill="currentColor"/>}</button><div className="sample-progress"><label className="sr-only" htmlFor="sample-seek">Sample position</label><input id="sample-seek" type="range" min="0" max={sample.duration} step="0.01" value={Math.min(time,sample.duration)} style={{ '--progress': `${Math.min(time/sample.duration,1)*100}%` } as React.CSSProperties} onChange={e => { const value=Number(e.target.value); if (audio.current?.readyState) audio.current.currentTime=value; setTime(value); }}/><span>{minutes(time)}<span>{minutes(sample.duration)}</span></span></div><Volume2 className="volume-icon" size={17}/></div>
          <audio ref={audio} preload="none" src="/kiki-sample.m4a" onPlay={() => setPlaying(true)} onPause={() => setPlaying(false)} onEnded={() => { setPlaying(false); setTime(sample.duration); }} onError={() => setError('The audio sample is unavailable. You can still watch the demo.')}/>
          {error && <p className="sample-error" role="status">{error}</p>}
        </div>
        <div className="demo-note"><span>Actual local voice. Approximate word timings.</span><button className="text-button" onClick={() => setShowVideo(true)}><Play size={13} fill="currentColor"/> Watch the 27-second demo <ArrowUpRight size={14}/></button></div>
      </section>

      <section className="principles section-wrap" aria-label="What OpenRead does"><div><span className="feature-symbol"><AudioLines/></span><h3>A voice that feels right.</h3><p>Expressive Kitten voices and more local options. Find a voice and a pace you like.</p></div><div><span className="feature-symbol"><Headphones/></span><h3>Keep your place.</h3><p>Follow each word on the page as it’s spoken. Pause, wander, come back.</p></div><div><span className="feature-symbol"><LockKeyhole/></span><h3>Keep your words, too.</h3><p>Webpages, documents and optional AI tools, processed on your own Mac.</p></div></section>

      <section className="installation" id="install" aria-labelledby="install-heading"><div className="section-wrap"><div className="install-intro"><div><span className="eyebrow">MAKE YOURSELF AT HOME</span><h2 id="install-heading">A few steps.<br/><em>Then, your own pace.</em></h2></div><div className="download-card glass"><span className="release-label"><span/> Free early release · macOS</span><a className="download-button" href={DOWNLOAD}><ArrowDownToLine size={18}/> Download OpenRead <ArrowUpRight size={15}/></a><p>Source ZIP · Safari & Chrome<br/>Manual installation. No account or payment.</p></div></div>
        <div className="requirements"><Monitor size={16}/><p>You’ll need a Mac and <a href="https://www.python.org/downloads/macos/" target="_blank" rel="noreferrer">Python 3.11–3.13</a>. First setup downloads about 436 MB of local models, plus packages. Python 3.14 isn’t supported yet.</p></div>
        <ol className="install-steps"><li><span className="step-number">01</span><div><h3>Download. Unzip.</h3><p>Download the folder above and double-click the ZIP. Keep the whole OpenRead folder together.</p></div></li><li><span className="step-number">02</span><div><h3>Set up your voices.</h3><p>Inside the folder, double-click <code>Set Up OpenRead.command</code>. Let the one-time setup finish. Then double-click <code>Start OpenRead.command</code> and leave its window open while you listen.</p><details><summary>First time opening a .command file?</summary><p>If macOS blocks the launcher, inspect the downloaded source and follow macOS’s Privacy &amp; Security prompt to allow that file. The <a href={REPO+'/blob/master/GETTING_STARTED.md'} target="_blank" rel="noreferrer">full installation guide</a> covers Python setup and common problems.</p></details></div></li><li className="browser-step"><span className="step-number">03</span><div><h3>Add it to your browser.</h3><div className="browser-tabs" role="tablist" aria-label="Installation browser">{(['chrome','safari'] as const).map(value => <button key={value} role="tab" aria-selected={browser === value} aria-controls={'install-'+value} id={'tab-'+value} tabIndex={browser===value ? 0 : -1} onClick={() => setBrowser(value)} onKeyDown={e=>{if(['ArrowLeft','ArrowRight'].includes(e.key)){e.preventDefault();const next=value==='chrome'?'safari':'chrome';setBrowser(next);document.getElementById('tab-'+next)?.focus();}}}>{value==='chrome'?'Chrome':'Safari'}{browser===value&&<Check size={13}/>}</button>)}</div>
          {browser==='chrome'?<div className="browser-instructions" role="tabpanel" id="install-chrome" aria-labelledby="tab-chrome"><ol><li>Type <code>chrome://extensions</code> into Chrome’s address bar.</li><li>Turn on <strong>Developer mode</strong>, then click <strong>Load unpacked</strong>.</li><li>Select the <code>extension</code> folder inside OpenRead.</li><li>Pin OpenRead from the puzzle-piece menu. Open an article, click its book icon and choose <strong>Listen to page</strong>.</li></ol><p>Chrome may ask to connect to the local voice helper on your Mac.</p></div>:<div className="browser-instructions" role="tabpanel" id="install-safari" aria-labelledby="tab-safari"><ol><li>In Safari, open <strong>Settings → Developer → Add Temporary Extension…</strong></li><li>Select the <code>extension</code> folder inside OpenRead and complete Safari’s extension prompts.</li><li>Enable OpenRead in <strong>Settings → Extensions</strong> for your Safari profile.</li><li>Open an article, click its book icon and choose <strong>Listen to page</strong>.</li></ol><p>Temporary extensions may need adding again after Safari restarts. If your Safari doesn’t offer this option, use the <a href={REPO+'/blob/master/docs/DEVELOPMENT.md#add-to-safari'} target="_blank" rel="noreferrer">Xcode installation route</a>, or try Chrome.</p></div>}
        </div></li></ol><div className="install-footer"><p><Check size={14}/> No Node.js or coding needed for the folder install.</p><a className="text-button" href={REPO+'/blob/master/GETTING_STARTED.md'} target="_blank" rel="noreferrer">Full guide & troubleshooting <ArrowUpRight size={14}/></a></div>
      </div></section>

      <section className="questions section-wrap" aria-labelledby="questions-heading"><div><span className="eyebrow">BEFORE YOU SETTLE IN</span><h2 id="questions-heading">A little clarity.</h2></div><div className="question-list"><details><summary>Is it really free?<span>+</span></summary><p>Yes. OpenRead’s source is free to use, modify and share under GPL-3.0-or-later. Every feature is available without a subscription. Donations are entirely optional.</p></details><details><summary>Does my reading leave my Mac?<span>+</span></summary><p>The installed app processes your reading locally. Voices run on your Mac, and the optional AI features use local models. This public website plays a prerecorded sample; it doesn’t upload your documents or connect to your local library.</p></details><details><summary>Can I use it without installing anything?<span>+</span></summary><p>You can try the recorded voice sample and watch the demo here. Full webpage reading, imports and word highlighting require the extension and local helper.</p></details><details><summary>What about PDFs, summaries and audio overviews?<span>+</span></summary><p>The local library imports PDFs, EPUBs, Word documents and scans. Reading tools include optional local summaries, questions, two-voice conversations and dictation. Extra AI setup lives in the <code>setup</code> folder and is explained in the installation guide.</p></details><details><summary>Does it work on Windows or mobile?<span>+</span></summary><p>This release is designed for Mac with Safari or Chrome. The Chrome extension does not make the whole setup Windows-ready. Other platforms are welcome contributions, but aren’t a supported one-click install yet.</p></details></div></section>

      <section className="community section-wrap" aria-labelledby="community-heading"><span className="eyebrow">YOURS TO USE. OURS TO IMPROVE.</span><h2 id="community-heading">Useful software.<br/><em>A little less rent.</em></h2><p>Built by Ahmed Najaf because reading support shouldn’t need another monthly bill. Open source, so anyone can help make it better.</p><div className="community-links"><a className="community-primary" href={REPO} target="_blank" rel="noreferrer"><Code2 size={17}/> Explore the source <ArrowUpRight size={14}/></a><a className="community-secondary" href={SUPPORT} target="_blank" rel="noreferrer"><Coffee size={17}/> Buy me a coffee <ArrowUpRight size={14}/></a></div><span className="support-note">Code, feedback, documentation or a coffee.<br/>Contributions are welcome. Donations are completely optional.</span></section>
    </main>
    <footer className="site-footer section-wrap"><Brand/><span>Free, by design.</span><nav aria-label="Footer"><a href={REPO+'/blob/master/LICENSE'} target="_blank" rel="noreferrer">GPL-3.0-or-later</a><a href={REPO+'/blob/master/THIRD_PARTY.md'} target="_blank" rel="noreferrer">Credits</a><a href="/privacy.html">Privacy</a><a href={REPO+'/issues'} target="_blank" rel="noreferrer">Feedback <ArrowUpRight size={12}/></a></nav></footer>
    {showVideo && <dialog ref={dialog} className="video-dialog" aria-label="OpenRead product demo" onCancel={()=>setShowVideo(false)} onClick={e=>{if(e.target===dialog.current){const r=e.currentTarget.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)setShowVideo(false);}}}><header><span>OpenRead, in 27 seconds.</span><button onClick={()=>setShowVideo(false)} aria-label="Close demo"><X size={19}/></button></header><video ref={video} controls autoPlay playsInline preload="none" poster="/demo-cover.png" src="/openread-demo.mp4"/><p>Real local Kiki narration · OpenRead 0.4</p></dialog>}
  </>;
}
createRoot(document.getElementById('root')!).render(<App/>);
