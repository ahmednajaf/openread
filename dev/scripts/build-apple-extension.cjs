// Build a Safari-specific variant. Chrome keeps its existing helper transport.
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const destination = path.join(root, 'app/apple/SafariExtension/Resources');
fs.mkdirSync(destination, { recursive: true });
for (const name of ['core.js','extract.js','player.js','highlighter.js','content.js','popup.html','popup.js','settings.js','glass.js','popup.css','reader.css','icons']) {
  fs.cpSync(path.join(root, 'extension', name), path.join(destination, name), { recursive: true });
}
fs.copyFileSync(path.join(root, 'app/apple/SafariExtension/background.js'), path.join(destination, 'background.js'));
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'extension/manifest.json')));
manifest.version = '0.6.4';
manifest.permissions.push('nativeMessaging');
delete manifest.host_permissions;
manifest.background = { scripts: ['background.js'], persistent: false };
fs.writeFileSync(path.join(destination, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
const voices = JSON.parse(fs.readFileSync(path.join(root, 'extension/voices.json'))).map(v => ({...v, pack: v.id.startsWith('kitten:') ? 'kitten' : 'kokoro'}));
voices.push(...JSON.parse(fs.readFileSync(path.join(root, 'app/mobile/shared/kitten2-voices.json'))));
const player = path.join(destination, 'player.js');
fs.appendFileSync(player, '\n' + fs.readFileSync(path.join(root, 'app/apple/SafariExtension/app-player.js'), 'utf8'));
const core = path.join(destination, 'core.js');
fs.writeFileSync(core, fs.readFileSync(core, 'utf8').replace(/const voices = \[[^\n]*\];/u, 'const voices = ' + JSON.stringify(voices) + ';').replace('`Kokoro · ${voice.detail}`', "(voice.pack === 'kitten2' ? `Kitten 2 · ${voice.detail.split(' · ')[0]}` : `Kokoro · ${voice.detail}`)"));
const settings = path.join(destination, 'settings.js');
fs.writeFileSync(settings, fs.readFileSync(settings, 'utf8').replace('Library &amp; tools', 'OpenRead library').replace('Preparing on your Mac…', 'Preparing on this device…')
  .replace('Natural voices · On-device', 'Natural voices · On-device')
  .replace('Save this reading<span', 'Open page in OpenRead<span')
  .replace('<div class="option"><label for="source">', '<p class="reader-help">Download Kitten or Kokoro voices in the OpenRead app first.</p><div class="option"><label for="source">'));
const content = path.join(destination, 'content.js');
fs.writeFileSync(content, fs.readFileSync(content, 'utf8').replace('Start the local helper, then open http://127.0.0.1:8765.', 'Open the OpenRead app to view your library.').replace('Start the local helper to save this reading.', 'OpenRead could not save this page. Open the app and try again.').replace(/Run Set Up OpenRead\.command[^']*|Run Set Up OpenRead\.command and restart the helper[^']*|The featured Kitten voices need the updated helper\.[^']*/gu, 'Open the OpenRead app and download natural voices first.'));
console.log('Safari native resources ready: app/apple/SafariExtension/Resources');

const popup = path.join(destination, 'popup.js');
fs.writeFileSync(popup, fs.readFileSync(popup, 'utf8').replace('http://127.0.0.1:8765/', 'openread://library').replace('Open library & tools', 'OpenRead library'));

fs.writeFileSync(settings, fs.readFileSync(settings, 'utf8').replaceAll("voice.pack ? 'English' : voice.detail.split(' · ')[0]", "voice.pack === 'kitten' ? 'Kitten' : voice.detail.split(' · ')[0]"));

// The app-owned playback engine supports 0.5–2×. Reflect the actual rate.
fs.writeFileSync(content, fs.readFileSync(content, 'utf8')
  .replace('phase = state;', "phase = state; if (preferences.voice.startsWith('kitten2:')) preferences.rate = Math.min(2, state.rate || preferences.rate);")
  .replace('Math.min(5, Number(value)', "Math.min(preferences.voice.startsWith('kitten2:') ? 2 : 5, Number(value)"));
fs.writeFileSync(settings, fs.readFileSync(settings, 'utf8')
  .replace('this.speed(preferences.rate);', "this.$('#speed').max = preferences.voice.startsWith('kitten2:') ? 2 : 5; this.$('.speed-labels span:last-child').textContent = this.$('#speed').max + '×'; this.speed(preferences.rate);")
  .replace('(rate - .5) / 4.5', "(rate - .5) / (Number(this.$('#speed').max) - .5)")
  .replace('Download Kitten or Kokoro voices in the OpenRead app first.', 'Download voices in OpenRead first. Kitten TTS 2 opens the app for playback; return to Safari to follow the highlighted words.'));

fs.writeFileSync(content, fs.readFileSync(content, 'utf8')
  .replace("let error = '';", "let error = ''; let playbackNotice = '';")
  .replace("error,\n      title:", "error, notice: playbackNotice,\n      title:")
  .replace('function notice(text =', "function playbackMessage(text = '') { playbackNotice = text; publish(); }\n  function notice(text =")
  .replace('onError: message =>', 'onNotice: playbackMessage, onError: message =>'));
fs.writeFileSync(settings, fs.readFileSync(settings, 'utf8')
  .replace("state.error || ''", "state.error || state.notice || ''")
  .replace('!state.error;', '!(state.error || state.notice);'));
