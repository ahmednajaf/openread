/* Package a clean, unpacked MV3 extension. No Safari wrapper or runtime tools. */
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const destination = path.join(root, 'build/chrome/OpenRead');
fs.mkdirSync(destination, { recursive: true });
fs.cpSync(path.join(root, 'extension'), destination, { recursive: true });
const manifestPath = path.join(destination, 'manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
manifest.minimum_chrome_version = '120';
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
if (process.platform !== 'win32') {
  const archive = path.join(root, 'build/chrome/OpenRead-chrome.zip');
  fs.rmSync(archive, { force: true });
  const zipped = spawnSync('zip', ['-qr', archive, '.'], { cwd: destination });
  if (zipped.status !== 0) console.warn('ZIP unavailable; use the OpenRead folder with Load unpacked.');
}
console.log('Chrome extension ready: build/chrome/OpenRead');
console.log('Open chrome://extensions → Developer mode → Load unpacked → choose that folder.');
