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
manifest.version = '0.5.1';
manifest.permissions.push('nativeMessaging');
delete manifest.host_permissions;
manifest.background = { scripts: ['background.js'], persistent: false };
fs.writeFileSync(path.join(destination, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
const voices = JSON.parse(fs.readFileSync(path.join(root, 'extension/voices.json'))).filter(v => v.id.startsWith('kitten:'));
const core = path.join(destination, 'core.js');
fs.writeFileSync(core, fs.readFileSync(core, 'utf8').replace(/const voices = \[[^\n]*\];/u, 'const voices = ' + JSON.stringify(voices) + ';'));
const settings = path.join(destination, 'settings.js');
fs.writeFileSync(settings, fs.readFileSync(settings, 'utf8').replace('Library &amp; tools', 'OpenRead library').replace('Preparing on your Mac…', 'Preparing on this device…'));
const content = path.join(destination, 'content.js');
fs.writeFileSync(content, fs.readFileSync(content, 'utf8').replace('Start the local helper, then open http://127.0.0.1:8765.', 'Open the OpenRead app to view your library.').replace('Start the local helper to save this reading.', 'OpenRead could not save this page. Open the app and try again.').replace(/Run Set Up OpenRead\.command[^']*|Run Set Up OpenRead\.command and restart the helper[^']*|The featured Kitten voices need the updated helper\.[^']*/gu, 'Open the OpenRead app and download natural voices first.'));
console.log('Safari native resources ready: app/apple/SafariExtension/Resources');

const popup = path.join(destination, 'popup.js');
fs.writeFileSync(popup, fs.readFileSync(popup, 'utf8').replace('http://127.0.0.1:8765/', 'openread://library').replace('Open library & tools', 'OpenRead library'));
