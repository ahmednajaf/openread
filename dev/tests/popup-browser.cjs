/* Exercise the actual toolbar document with a controlled WebExtension transport. */
const assert = require('node:assert/strict');
const path = require('node:path');
process.env.PLAYWRIGHT_BROWSERS_PATH ||= path.resolve(__dirname, '../../.local/browsers');
const { webkit } = require('playwright');
(async () => {
  const browser = await webkit.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 354, height: 600 }, colorScheme: 'light' });
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.addInitScript(() => {
    window.popupListeners = []; window.popupCommands = []; window.popupScripts = []; window.closedByPopup = false;
    window.close = () => { window.closedByPopup = true; };
    window.popupState = { status:'playing', index:3, total:6, preferences:{voice:'af_heart',rate:1,highlight:true,follow:true},source:'page',hasSelection:false,error:'',title:'An article',sourceName:'example.com',minutes:2,previewStatus:'idle' };
    window.browser = {
      runtime:{getURL:file=>`/extension/${file}`,onMessage:{addListener:fn=>popupListeners.push(fn)}},
      scripting:{executeScript:async value=>popupScripts.push(value.files)},
      tabs:{query:async()=>[{id:7,url:'https://example.com/article'}],sendMessage:async(id,message)=>{
        if(message.type==='openread:command'){
          popupCommands.push(message); const state=popupState;
          if(message.action==='toggle-playback')state.status=state.status==='playing'?'paused':'playing';
          if(message.action==='set-rate')state.preferences.rate=message.value;
          if(message.action==='stop')state.status='idle';
        }
        return structuredClone(popupState);
      }}
    };
  });
  try {
    await page.goto('http://127.0.0.1:4173/extension/popup.html');
    const view = page.getByRole('region',{name:'OpenRead settings'}); await view.waitFor();
    assert.equal(await view.getAttribute('data-liquid-glass'), null);
    assert.equal(await view.locator('#appearance').count(),0);
    assert.deepEqual(await view.evaluate(el=>({background:getComputedStyle(el).backgroundColor,shadow:getComputedStyle(el).boxShadow,backdrop:getComputedStyle(el).backdropFilter})),{background:'rgba(0, 0, 0, 0)',shadow:'none',backdrop:'none'});
    assert.equal(await view.locator('.document-title').evaluate(el=>getComputedStyle(el).color),'rgb(37, 36, 45)');
    await page.emulateMedia({colorScheme:'dark'});
    await page.waitForFunction(()=>document.querySelector('.shell').dataset.foreground==='dark');
    assert.equal(await view.locator('.document-title').evaluate(el=>getComputedStyle(el).color),'rgb(237, 234, 241)');
    await view.getByRole('button',{name:'Pause',exact:true}).click();
    await view.getByRole('button',{name:'Resume listening',exact:true}).waitFor();
    assert.equal(await page.evaluate(()=>closedByPopup),false);
    await view.locator('#speed').evaluate(el=>{el.value='1.5';el.dispatchEvent(new Event('input',{bubbles:true}));});
    assert.equal(await view.locator('#speed').evaluate(el=>el.style.getPropertyValue('--speed-progress')),'22.222%');
    await view.getByRole('button',{name:'Reading options',exact:true}).click();
    const box=await view.boundingBox(); assert.ok(box.height<=495);
    assert.ok(await view.locator('.glass-content').evaluate(el=>el.scrollHeight>el.clientHeight));
    await view.getByRole('button',{name:'Resume listening',exact:true}).click();
    await page.waitForFunction(()=>closedByPopup);
    assert.equal(await page.evaluate(()=>popupState.status),'playing');
    assert.deepEqual(await page.evaluate(()=>popupScripts),[]);
    assert.deepEqual(errors,[]);
    console.log('Toolbar popup: transparent native surface, automatic light/dark text, no appearance toggle, routed controls, bounded height, closing does not own or stop playback.');
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
