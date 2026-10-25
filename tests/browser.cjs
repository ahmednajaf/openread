/* Integration checks use an isolated WebKit instance and the real local voice. */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
if (!process.env.PLAYWRIGHT_BROWSERS_PATH && fs.existsSync(path.join(root, '.local/browsers'))) process.env.PLAYWRIGHT_BROWSERS_PATH = path.join(root, '.local/browsers');
const { webkit, chromium } = require('playwright');
const useChromium = process.env.BROWSER === 'chromium';
const engine = useChromium ? 'Chromium' : 'WebKit';
(async () => {
  const browser = await (useChromium ? chromium : webkit).launch({ headless: true, ...(useChromium ? { executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' } : {}) });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 1 });
  if (useChromium) await page.context().grantPermissions(['local-network-access'], { origin: 'http://127.0.0.1:4173' });
  const errors = []; const requests = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => { if (request.url().endsWith('/synthesize')) requests.push(request.postDataJSON()); });
  await page.addInitScript(() => {
    const play = HTMLMediaElement.prototype.play; window.testMedia = [];
    HTMLMediaElement.prototype.play = function () { if (!window.testMedia.includes(this)) window.testMedia.push(this); return play.call(this); };
  });
  const out = path.join(root, 'test-results'); fs.mkdirSync(out, { recursive: true });
  try {
    await page.goto('http://127.0.0.1:4173');
    const popover = page.getByRole('region', { name: 'OpenRead settings' }); await popover.waitFor();
    await page.waitForFunction(() => {
      const surface = document.querySelector('[data-openread-host]').shadowRoot.querySelector('.popover');
      return surface?.dataset.openreadMaterial === 'preview' && getComputedStyle(surface).backdropFilter.includes('blur');
    });
    assert.equal(await popover.locator('.document-title').textContent(), 'Athene Visits Telemachus');
    assert.equal(await popover.locator('#voice option').count(), 49);
    assert.equal(await popover.locator('.reading-text').count(), 0);
    assert.equal(await popover.locator('.listen').getAttribute('data-openread-material'), 'control');
    // Drag the actual thumb: the filled track must follow every input event.
    const speed = popover.getByRole('slider', { name: 'Reading speed' });
    const track = await speed.boundingBox();
    const currentRate = Number(await speed.inputValue());
    await page.mouse.move(track.x + 10 + (track.width - 20) * (currentRate - .5) / 4.5, track.y + track.height / 2);
    await page.mouse.down();
    for (const fraction of [.8, .2, .6]) {
      await page.mouse.move(track.x + 10 + (track.width - 20) * fraction, track.y + track.height / 2, { steps: 5 });
      const fill = await speed.evaluate(input => ({ rate: Number(input.value), progress: input.style.getPropertyValue('--speed-progress'), gradient: getComputedStyle(input).backgroundImage }));
      assert.ok(Math.abs(parseFloat(fill.progress) - (fill.rate - .5) / 4.5 * 100) < .01);
      assert.ok(Math.abs(parseFloat(fill.gradient.match(/([\d.]+)%/u)[1]) - parseFloat(fill.progress)) < .01, `Track fill did not follow ${fill.rate}`);
      assert.ok(Math.abs(fill.rate - (.5 + 4.5 * fraction)) <= .05);
    }
    await page.mouse.up();
    await speed.focus(); await speed.press('Home');
    assert.equal(await speed.inputValue(), '0.5');
    assert.equal(await speed.evaluate(input => input.style.getPropertyValue('--speed-progress')), '0%');
    await speed.press('End');
    assert.equal(await speed.evaluate(input => input.style.getPropertyValue('--speed-progress')), '100%');
    await speed.evaluate(input => { input.value = '1'; input.dispatchEvent(new Event('input', { bubbles: true })); });
    await page.screenshot({ path: path.join(out, 'glass-settings-desktop.png') });
    const original = await page.locator('article').innerHTML();
    await popover.getByRole('button', { name: 'Listen to page', exact: true }).click();
    await page.waitForFunction(() => {
      const root = document.querySelector('[data-openread-host]').shadowRoot;
      return root.querySelector('.popover').hidden && root.querySelectorAll('.word-marker').length;
    }, null, { timeout: 90000 });
    await page.waitForFunction(() => window.testMedia.some(a => a.currentTime > .15 && !a.paused && a.duration > 1));
    const highlighted = await page.evaluate(() => [...document.querySelector('[data-openread-host]').shadowRoot.querySelectorAll('.word-marker')].map(mark => { const r = mark.getBoundingClientRect(); return { insideArticle: !!document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2)?.closest('article') }; }));
    assert.ok(highlighted.length && highlighted.every(r => r.insideArticle));
    assert.equal(await page.locator('article').innerHTML(), original);
    await page.screenshot({ path: path.join(out, 'in-page-listening.png') });
    await page.locator('#launch').click(); await popover.waitFor();
    await popover.getByRole('button', { name: 'Pause', exact: true }).click();
    assert.equal(await popover.locator('.session-label').textContent(), 'Paused');
    assert.equal(await page.evaluate(() => window.testMedia.every(a => a.paused)), true);
    const clock = await page.evaluate(() => window.testMedia.at(-1).currentTime);
    await popover.locator('#speed').evaluate(input => { input.value = '1.5'; input.dispatchEvent(new Event('input', { bubbles: true })); });
    assert.equal(await page.evaluate(() => window.testMedia.at(-1).currentTime), clock);
    assert.equal(await page.evaluate(() => window.testMedia.at(-1).playbackRate), 1.5);
    await popover.locator('#voice').selectOption('bf_emma');
    await popover.getByRole('button', { name: 'Resume listening', exact: true }).click();
    await page.waitForFunction(() => document.querySelector('[data-openread-host]').shadowRoot.querySelector('.popover').hidden, null, { timeout: 90000 });
    assert.ok(requests.some(r => r.voice === 'bf_emma'));
    await page.locator('#launch').click(); await popover.waitFor(); await popover.getByRole('button', { name: 'Stop', exact: true }).click();
    assert.equal(await page.evaluate(() => CSS.highlights.has('openread-word')), false);
    await popover.getByRole('button', { name: 'Reading options' }).click();
    assert.equal(await popover.getByRole('switch', { name: 'Skip links' }).count(), 0);
    if (!useChromium) {
      await popover.getByRole('button', { name: 'Safari Reader', exact: true }).click();
      assert.match(await popover.locator('.reader-help').textContent(), /cannot switch/);
    } else assert.equal(await popover.locator('.reader-option').isVisible(), false);
    await popover.getByRole('button', { name: 'Paste text', exact: true }).click();
    await popover.locator('#paste').fill('<img src=x onerror="window.injected=true"> Test text.');
    await popover.getByRole('button', { name: 'Use this text' }).click();
    assert.equal(await popover.locator('.document-title').textContent(), 'Your text');
    assert.equal(await page.evaluate(() => window.injected), undefined);
    await popover.getByRole('button', { name: 'Hide settings' }).click();
    await page.locator('#launch').click(); await popover.waitFor();
    assert.equal(await popover.locator('#voice').inputValue(), 'bf_emma');
    await popover.getByRole('button', { name: 'Reading options' }).click();
    await page.setViewportSize({ width: 390, height: 844 });
    const box = await popover.boundingBox(); assert.ok(box.x >= 0 && box.x + box.width <= 391 && box.height < 820);
    await page.screenshot({ path: path.join(out, 'glass-settings-narrow.png') });
    await page.emulateMedia({ colorScheme: 'dark' });
    await page.waitForFunction(() => document.querySelector('[data-openread-host]').shadowRoot.querySelector('.shell').dataset.appearance === 'dark');
    assert.equal(await popover.locator('#appearance').count(), 0);
    await page.screenshot({ path: path.join(out, 'glass-settings-dark.png') });
    await page.emulateMedia({ colorScheme: 'light' });
    await page.waitForFunction(() => document.querySelector('[data-openread-host]').shadowRoot.querySelector('.shell').dataset.appearance === 'light');
    await popover.press('Escape'); assert.equal(await popover.isVisible(), false);
    assert.deepEqual(errors, []);
    console.log(`${engine}: independent preview material, actual slider drag and blue fill, keyboard speed, automatic device appearance, natural voices, real media-clock highlighting, hidden playback UI, pause, stop, paste escaping, narrow/dark layouts.`);

    const extraction = await browser.newPage();
    await extraction.setContent(`<html lang="en"><body><header>Website brand</header><nav><a href="#">Home link</a></nav><main><article><div>Unnecessary pre-title content</div><header><h1>Reading <em>well</em></h1><div class="byline">Author biography</div></header><div>4 minutes</div><span data-testid="estimatedReadingTime">7 min read</span><p>Estimated reading time: 5 minutes</p><p id="inline">One   <strong>bold</strong> idea <a href="https://example.com">linked words</a> remains. https://example.com/raw Next.</p><p>Wait <span>4 minutes</span> before continuing.</p><h2>4 minutes</h2><ul><li>Parent intro<ul><li>Child one.</li><li><p>Child two.</p><p>Second child paragraph.</p></li></ul>Parent ending.</li><li>Sibling item.</li><li><code>&lt;h2&gt;</code></li></ul><div class="monaco-editor"><span>Editor chrome</span></div><p aria-hidden="true">Hidden secret</p><div style="display:none"><p>Hidden container</p></div><p>Visible <span style="visibility:hidden">ghost</span> ending.</p><aside><p>Related promo</p></aside><footer>Share story</footer></article></main></body></html>`);
    await extraction.addScriptTag({ path: path.join(root, 'extension/core.js') });
    await extraction.addScriptTag({ path: path.join(root, 'extension/extract.js') });
    const result = await extraction.evaluate(() => {
      const before = document.querySelector('article').innerHTML;
      const data = OpenReadExtract();
      const item = data.items.find(i => i.text.includes('bold'));
      const rangeText = OpenReadRanges(item, item.text.indexOf('bold'), 4).map(r => r.toString()).join('');
      const withLinks = OpenReadExtract(document, { skipLinks: true }).text;
      const range = document.createRange(); const node = document.querySelector('strong').firstChild; range.setStart(node, 1); range.setEnd(node, 3);
      const selected = OpenReadExtract(document, { selection: range });
      document.querySelector('strong').firstChild.data = 'changed';
      const linkItem = data.items.find(i => i.text.includes('linked words'));
      const linkedRange = OpenReadRanges(linkItem, linkItem.text.indexOf('linked words'), 12).map(r => r.toString()).join('');
      return { linkedRange, blocks: data.blocks.map(b => b.text), kind: data.items.filter(i => i.kind === 'list').length, rangeText, withLinks, selected: selected.text,
        stale: OpenReadRanges(item, item.text.indexOf('bold'), 4).length, originalUnmodified: before.replace('<strong>bold</strong>', '<strong>changed</strong>') === document.querySelector('article').innerHTML };
    });
    assert.deepEqual(result.blocks, ['Reading well', 'One bold idea linked words remains. Next.', 'Wait 4 minutes before continuing.', '4 minutes', 'Parent intro', 'Child one.', 'Child two.', 'Second child paragraph.', 'Parent ending.', 'Sibling item.', '<h2>', 'Visible ending.']);
    assert.equal(result.linkedRange, 'linked words'); assert.equal(result.rangeText, 'bold'); assert.equal(result.kind, 7); assert.equal(result.selected, 'ol');
    assert.ok(result.withLinks.includes('linked words')); assert.ok(!result.withLinks.includes('https://')); assert.equal(result.stale, 0); assert.equal(result.originalUnmodified, true);
    await extraction.close();
    console.log('Extraction: nested bullets and parent endings, separate list paragraphs, hidden elements, headers, inline link preservation, reading-time metadata and URL filtering, inline markup, partial selection, exact DOM ranges, stale-text detection; no page text mutations.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });
