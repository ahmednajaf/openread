/* EPUB navigation through the full app, real speech and a disposable library. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
process.env.PLAYWRIGHT_BROWSERS_PATH ||= path.join(root, '.local/browsers');
const { webkit, chromium } = require('playwright');
const origin = 'http://127.0.0.1:8766';
const headers = { 'X-OpenRead': '1', 'Content-Type': 'application/json' };
(async () => {
  const fixture = spawnSync(path.join(root, '.venv/bin/python'), [path.join(__dirname, 'epub_fixture.py')]);
  assert.equal(fixture.status, 0, fixture.stderr.toString());
  const helper = spawn(path.join(root, '.venv/bin/python'), [path.join(__dirname, 'workspace_server.py')], { cwd: root, stdio: 'pipe' });
  let serverOutput = ''; helper.stderr.on('data', value => { serverOutput += value; });
  let browser;
  try {
    for (let i = 0; i < 120; i++) {
      try { if ((await fetch(origin + '/health', { headers })).ok) break; } catch {}
      if (helper.exitCode !== null) throw new Error(serverOutput);
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    browser = await (process.env.BROWSER === 'chromium' ? chromium : webkit).launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1320, height: 1000 }, colorScheme: 'light', acceptDownloads: true });
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    const button = name => page.getByRole('button', { name, exact: true });
    const chapter = number => page.getByRole('button', { name: new RegExp(`^Choose chapter, ${number} of 3:`) });
    const api = async (route, payload) => {
      const response = await fetch(origin + route, { headers, ...(payload ? { method: 'POST', body: JSON.stringify(payload) } : {}) });
      assert.ok(response.ok, await response.clone().text()); return response.json();
    };
    await page.goto(origin);
    await page.locator('input[aria-label="Import a document"]').setInputFiles({ name: 'chapters.epub', mimeType: 'application/epub+zip', buffer: fixture.stdout });
    await page.getByRole('heading', { name: 'A Chaptered Book', exact: true }).waitFor();
    console.log('Imported EPUB with three chapters.');
    assert.equal(await page.locator('.reader-text p').count(), 6);
    assert.equal(await button('Previous chapter').isEnabled(), false);
    await button('Open chapters').click();
    assert.equal(await page.locator('.chapter-list button').count(), 3);
    assert.equal(await button('Go to chapter 1: First & foremost').getAttribute('aria-current'), 'location');
    await button('Go to chapter 2: Second chapter').press('Enter');
    await chapter(2).waitFor();
    assert.equal(await button('Listen to reading').count(), 1); // Selecting chapters does not start audio.
    assert.equal(await page.locator('.word-layer i').count(), 0);
    await button('Next chapter').click(); await chapter(3).waitFor();
    assert.equal(await button('Next chapter').isEnabled(), false);
    await button('Previous chapter').click(); await chapter(2).waitFor();
    await button('Listen to reading').click();
    await page.locator('.word-layer i').first().waitFor({ timeout: 120000 });
    assert.match(await page.locator('.dock-caption').innerText(), /passage [34] of 6/);
    await button('Next chapter').click(); await chapter(3).waitFor();
    await page.waitForFunction(() => document.querySelector('.dock-caption').textContent.includes('Listening · passage 5 of 6'));
    await page.locator('.word-layer i').first().waitFor();
    await button('Pause reading').click();
    assert.equal(await page.locator('.word-layer i').count(), 0);
    await button('Previous chapter').click(); await chapter(2).waitFor();
    await button('More reading options').click(); await button('Save to library').click();
    await page.waitForURL(/id=/);
    const id = new URL(page.url()).searchParams.get('id');
    const saved = await api('/library/' + id);
    assert.equal(saved.position, 2); assert.equal(saved.chapters.length, 3);
    await page.reload(); await chapter(2).waitFor();
    await button('Open chapters').click();
    assert.equal(await button('Go to chapter 2: Second chapter').getAttribute('aria-current'), 'location');
    await button('Close Chapters').click();
    await button('Open library').click();
    const downloading = page.waitForEvent('download'); await button('Download library backup').click();
    const backup = fs.readFileSync(await (await downloading).path());
    assert.deepEqual(JSON.parse(backup).documents[0].chapters, saved.chapters);
    await button('Close Your library').click();
    // Restore through the UI after removing the test book from the disposable library.
    await button('More reading options').click(); await button('Delete reading').click();
    await page.getByRole('dialog', { name: 'Delete this reading?' }).getByRole('button', { name: 'Delete reading', exact: true }).click();
    await button('Try with The Odyssey').waitFor();
    await button('Library').click();
    await page.locator('input[aria-label="Restore library backup"]').setInputFiles({ name: 'backup.json', mimeType: 'application/json', buffer: backup });
    await button('Restore library').click();
    await page.getByRole('status').filter({ hasText: 'Library restored.' }).waitFor();
    console.log('Playback, save/resume and backup/restore passed.');
    await button('Library').click();
    await page.getByRole('button', { name: 'A Chaptered Book Saved on this device', exact: false }).click();
    await chapter(2).waitFor();
    // Natural playback advances the chapter indicator as well as passage transport.
    await button('Previous chapter').click(); await chapter(1).waitFor();
    await button('Listen to reading').click(); await chapter(2).waitFor({ timeout: 120000 });
    await button('Pause reading').click();
    for (const scheme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme: scheme });
      for (const width of [1320, 538, 390, 320]) {
        await page.setViewportSize({ width, height: 900 });
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `${scheme} ${width}px overflow`);
        await button('Open chapters').click();
        assert.equal(await page.locator('.chapter-list button').count(), 3);
        // Check the scrollable content; the decorative glass border extends 1px.
        const dimensions = await page.locator('.chapter-list').evaluate(e => ({ scroll: e.scrollWidth, client: e.clientWidth }));
        if (dimensions.scroll > dimensions.client && process.env.SCREENSHOT) await page.screenshot({ path: process.env.SCREENSHOT });
        assert.ok(dimensions.scroll <= dimensions.client, `${scheme} ${width}px chapter dialog overflow: ${JSON.stringify(dimensions)}`);
        await button('Close Chapters').click();
      }
    }
    await page.setViewportSize({ width: 1320, height: 1000 });
    if (process.env.SCREENSHOT) {
      await page.emulateMedia({ colorScheme: 'light' });
      await page.evaluate(() => window.scrollTo(0, 0));
      await button('Open chapters').click(); await page.screenshot({ path: process.env.SCREENSHOT, animations: 'disabled' });
    }
    assert.deepEqual(errors, []);
    console.log('EPUB chapters: import, contents keyboard selection, paused/playing jumps, natural advancement, boundaries, saved resume, backup/restore and responsive light/dark UI.');
  } finally { await browser?.close(); helper.kill('SIGINT'); }
})().catch(error => { console.error(error); process.exitCode = 1; });
