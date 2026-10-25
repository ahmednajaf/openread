/* Full app workflow against real local models and a disposable saved library. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
process.env.PLAYWRIGHT_BROWSERS_PATH ||= path.join(root, '.local/browsers');
const { webkit, chromium } = require('playwright');
const origin = 'http://127.0.0.1:8766';
(async () => {
  const helper = spawn(path.join(root, '.venv/bin/python'), [path.join(root, 'dev/tests/workspace_server.py')], { cwd: root, stdio: 'ignore' });
  let browser;
  try {
    for (let i = 0; i < 80; i++) {
      try { if ((await fetch(origin + '/health', { headers: { 'X-OpenRead': '1' } })).ok) break; } catch {}
      await new Promise(r => setTimeout(r, 250));
    }
    assert.equal((await fetch(origin + '/library')).status, 403);
    assert.equal((await fetch(origin + '/library', { headers: { 'X-OpenRead': '1', Origin: 'https://example.com' } })).status, 403);
    browser = await (process.env.BROWSER === 'chromium' ? chromium : webkit).launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1320, height: 1000 }, colorScheme: 'light', acceptDownloads: true });
    const errors = []; page.on('pageerror', e => errors.push(e.message));
    const button = name => page.getByRole('button', { name, exact: true });
    const options = () => button('More reading options').click();
    await page.goto(origin);
    await button('Bring your own text').click();
    await page.getByRole('textbox', { name: 'Title', exact: true }).fill('A local reading');
    await page.getByRole('textbox', { name: 'Text to read', exact: true }).fill('Reading should be accessible to everyone. A natural voice can help us follow the words.\n\nOpenRead keeps the text on your own device. There is no subscription or account.');
    await button('Open reading').click();
    assert.equal(await page.locator('.reader-text p').count(), 2);
    await button('Choose voice, currently Kiki').click();
    assert.equal(await page.locator('.voice-option').count(), 49);
    await button('Close Find your voice').click();
    await options(); await button('Save to library').click();
    await page.waitForURL(/id=/);
    await button('Listen to reading').click();
    await page.locator('.word-layer i').first().waitFor({ timeout: 120000 });
    await button('Pause reading').click();
    assert.equal(await page.locator('.word-layer i').count(), 0);
    await button('Reading speed, 1 times').click();
    await page.getByRole('slider', { name: 'Reading speed', exact: true }).fill('1.5');
    assert.match(await page.getByRole('slider').getAttribute('style'), /22\.222/);
    await button('Close Your pace').click();
    await button('Next passage').click(); await options(); await button('Bookmark this passage').click(); await button('Close Reading options').click();
    await page.reload();
    await button('Remove bookmark OpenRead keeps the text on your own device. There is no subscription or acc').waitFor();
    assert.equal(await button('Next passage').isEnabled(), false);
    assert.equal(await button('Reading speed, 1.5 times').count(), 1);
    await button('Open library').click();
    const downloading = page.waitForEvent('download'); await button('Download library backup').click();
    const backup = JSON.parse(fs.readFileSync(await (await downloading).path(), 'utf8'));
    assert.equal(backup.documents.length, 1); assert.equal(backup.documents[0].position, 1); assert.equal(backup.documents[0].bookmarks.length, 1);
    await button('Close Your library').click(); await options();
    const exporting = page.waitForEvent('download', { timeout: 180000 }); await button('Export audio').click();
    assert.equal(fs.readFileSync(await (await exporting).path()).toString('ascii', 0, 4), 'RIFF');
    await page.locator('input[aria-label="Import a document"]').setInputFiles({ name: 'linked.html', mimeType: 'text/html', buffer: Buffer.from('<nav>Unwanted navigation</nav><p>Keep the <a href="https://example.com">linked words</a> here.</p><ul><li>First point</li><li>Second point</li></ul><script>window.bad=true</script>') });
    await page.getByRole('heading', { name: 'linked', exact: true }).waitFor();
    assert.match(await page.locator('.reader-text').innerText(), /linked words/);
    assert.doesNotMatch(await page.locator('.reader-text').innerText(), /Unwanted navigation|window.bad/);
    await button('Reading tools').click();
    await page.getByRole('tab', { name: 'Ask', exact: true }).click();
    await page.getByRole('tab', { name: 'Ask', exact: true }).press('ArrowRight');
    assert.equal(await page.getByRole('tab', { name: 'Discuss', exact: true }).getAttribute('aria-selected'), 'true');
    await page.getByRole('tab', { name: 'Dictate', exact: true }).click();
    assert.equal(await button('Start recording').count(), 1);
    await button('Close A little more understanding').click();
    await options(); await button('Setup & privacy').click();
    await page.getByText('✓ PDF import', { exact: true }).waitFor();
    await button('Close Setup & privacy').click();
    for (const scheme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme: scheme });
      for (const width of [1320, 538, 390, 320]) {
        await page.setViewportSize({ width, height: 900 });
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
        assert.match(await page.locator('.player-dock').evaluate(e => getComputedStyle(e).backdropFilter || getComputedStyle(e).webkitBackdropFilter), /blur\(28px\)/);
      }
    }
    assert.deepEqual(errors, []);
    console.log('Reading app: real voices/highlights, pause cleanup, speed fill, save/resume/bookmarks, backup, WAV export, linked/list import, keyboard tabs, dictation entry, setup and responsive light/dark UI.');
  } finally { await browser?.close(); helper.kill('SIGINT'); }
})().catch(error => { console.error(error); process.exitCode = 1; });
