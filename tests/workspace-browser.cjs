/* Real companion workflow against a disposable library and local models. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const root = path.resolve(__dirname, '..');
process.env.PLAYWRIGHT_BROWSERS_PATH ||= path.join(root, '.local/browsers');
const { webkit, chromium } = require('playwright');
const origin = 'http://127.0.0.1:8766';
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
(async () => {
  const helper = spawn(path.join(root, '.venv/bin/python'), [path.join(root, 'tests/workspace_server.py')], { cwd: root, stdio: 'ignore' });
  let browser;
  try {
    let connected = false;
    for (let i = 0; i < 50; i++) {
      try { const response = await fetch(origin + '/health', { headers: { 'X-OpenRead': '1' } }); if (response.ok) { connected = true; break; } } catch {}
      await wait(300);
    }
    assert.ok(connected, 'isolated helper did not start');
    assert.equal((await fetch(origin + '/library')).status, 403);
    assert.equal((await fetch(origin + '/library', {headers:{'X-OpenRead':'1',Origin:'https://example.com'}})).status, 403);
    assert.equal((await fetch(origin + '/../../README.md')).status, 403);
    const useChrome = process.env.BROWSER === 'chromium';
    browser = await (useChrome ? chromium : webkit).launch({headless:true,...(useChrome?{executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'}:{})});
    const page = await browser.newPage({viewport:{width:1320,height:1000},colorScheme:'light',acceptDownloads:true});
    const errors=[];page.on('pageerror',error=>errors.push(error.message));
    await page.goto(origin);
    assert.equal(await page.locator('#voice option').count(),49);
    await page.getByRole('textbox',{name:'Document title',exact:true}).fill('A local reading');
    await page.getByRole('textbox',{name:'Text to listen to',exact:true}).fill('Reading should be accessible to everyone. A natural voice can help us follow the words.\n\nOpenRead keeps the text on your own device. There is no subscription or account.');
    await page.getByRole('button',{name:'Use this text',exact:true}).click();
    assert.equal(await page.locator('#reading p').count(),2);
    await page.getByRole('button',{name:'Save to library',exact:true}).click();
    await page.locator('#library button').waitFor();
    await page.getByRole('button',{name:'Listen',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('#word-layer').children.length>0,null,{timeout:90000});
    await page.locator('#speed').fill('5');
    await page.waitForFunction(()=>document.querySelector('#speed-value').textContent==='5×');
    await page.getByRole('button',{name:'Pause',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('#word-layer').children.length===0);
    await page.getByRole('button',{name:'Next passage',exact:true}).click();
    await page.getByRole('button',{name:'＋ Bookmark',exact:true}).click();
    await page.getByRole('button',{name:'＋ New reading',exact:true}).click();
    await page.locator('#library button').click();
    await page.waitForFunction(()=>document.querySelector('#playback-status').textContent.includes('2 of 2'));
    assert.equal(await page.locator('#bookmarks span').count(),1);
    const backupDownload=page.waitForEvent('download'); await page.getByRole('button',{name:'Download library backup',exact:true}).click();
    const backup=JSON.parse(fs.readFileSync(await (await backupDownload).path(),'utf8')); assert.equal(backup.documents.length,1);assert.equal(backup.documents[0].position,1);
    const exportDownload=page.waitForEvent('download',{timeout:120000}); await page.getByRole('button',{name:'↓ Audio file',exact:true}).click();
    const wav=fs.readFileSync(await(await exportDownload).path());assert.equal(wav.toString('ascii',0,4),'RIFF');assert.ok(wav.length>1000);
    await page.locator('#import-file').setInputFiles({name:'linked.html',mimeType:'text/html',buffer:Buffer.from('<nav>Unwanted navigation</nav><h1>A new document</h1><p>Keep the <a href="https://example.com">linked words</a> here.</p><ul><li>First point</li><li>Second point</li></ul><script>window.bad=true</script>')});
    await page.waitForFunction(()=>document.querySelector('#title').value==='linked');
    assert.match(await page.locator('#reading').textContent(),/linked words/);assert.doesNotMatch(await page.locator('#reading').textContent(),/Unwanted navigation|window.bad/);
    await page.getByRole('tab',{name:'Ask a question',exact:true}).click();assert.equal(await page.getByRole('tab',{name:'Ask a question',exact:true}).getAttribute('aria-selected'),'true');
    await page.getByRole('tab',{name:'Ask a question',exact:true}).press('ArrowRight');assert.equal(await page.getByRole('tab',{name:'Audio overview',exact:true}).getAttribute('aria-selected'),'true');
    await page.getByRole('button',{name:'Setup & privacy',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('#capabilities').textContent.includes('PDF import'));
    assert.match(await page.locator('#capabilities').textContent(),/✓ PDF import/);
    await page.getByRole('button',{name:'Setup & privacy',exact:true}).click();
    await page.setViewportSize({width:390,height:844});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
    await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:path.join(root,'test-results/workspace-mobile-dark.png'),fullPage:true});
    await page.setViewportSize({width:1320,height:1000});await page.emulateMedia({colorScheme:'light'});await page.screenshot({path:path.join(root,'test-results/workspace-light.png'),fullPage:true});
    if(process.env.AI==='1'){
      await page.getByRole('button',{name:'Edit text',exact:true}).click();
      await page.getByRole('textbox',{name:'Text to listen to',exact:true}).fill('The community library is open from 9 am to 5 pm. Ada hosts a free reading club every Wednesday at 2 pm. Members bring one book. The group decided to keep the club free. Alex will upload the meeting notes by Friday. There is no membership fee.');
      await page.getByRole('button',{name:'Use this text',exact:true}).click();
      await page.getByRole('tab',{name:'Summary',exact:true}).click();await page.locator('#summarize').click();
      await page.waitForFunction(()=>document.querySelector('#summary').textContent.length>20,null,{timeout:300000});
      await page.getByRole('tab',{name:'Ask a question',exact:true}).click();await page.locator('#question').fill('When does the reading club meet?');await page.locator('#chat-form button[type=submit], #chat-form button.primary').click();
      await page.waitForFunction(()=>document.querySelector('#answer').textContent.toLowerCase().includes('wednesday'),null,{timeout:300000});
      assert.equal(await page.locator('#sources').isVisible(),true);
      await page.getByRole('tab',{name:'Audio overview',exact:true}).click();await page.locator('#podcast').click();
      await page.waitForFunction(()=>document.querySelector('#podcast-script').textContent.length>20,null,{timeout:600000});
      assert.equal(await page.locator('#podcast-sources').isVisible(),true);
      const podcastDownload=page.waitForEvent('download',{timeout:180000});await page.locator('#podcast-audio').click();
      const podcastWav=fs.readFileSync(await(await podcastDownload).path());assert.equal(podcastWav.toString('ascii',0,4),'RIFF');assert.ok(podcastWav.length>1000);
      assert.equal(await page.locator('#podcast-player').isVisible(),true);
      await page.getByRole('tab',{name:'Dictation & notes',exact:true}).click();await page.locator('#audio-file').setInputFiles(path.join(root,'test-results/dictation-fixture.wav'));
      await page.waitForFunction(()=>document.querySelector('#transcript').textContent.toLowerCase().includes('accessible'),null,{timeout:120000});
      assert.equal(await page.locator('#copy-transcript').isVisible(),true);
      await page.screenshot({path:path.join(root,'test-results/workspace-ai-verified.png'),fullPage:true});
      console.log('Real workspace AI: summary, cited chat, source-checked podcast script, Kitten two-host WAV/player and local audio transcription — passed.');
    }
    assert.deepEqual(errors,[]);
    console.log(`${useChrome?'Chrome':'WebKit'} workspace: real playback and word cleanup, 5× speed, library save/resume/bookmarks, backup, WAV export, HTML import, keyboard tabs, setup status, narrow/dark layouts, no page errors — passed.`);
  } finally {await browser?.close(); helper.kill('SIGINT');}
})().catch(error=>{console.error(error);process.exitCode=1;});
