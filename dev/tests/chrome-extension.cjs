/* Actual MV3 package and transport in a disposable Chromium profile.
   Chromium exposes native toolbar popups as CDP `other` targets, not tabs. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
process.env.PLAYWRIGHT_BROWSERS_PATH ||= path.join(root, '.local/browsers');
const { chromium } = require('playwright');
const wait = ms => new Promise(resolve=>setTimeout(resolve,ms));
(async () => {
  const profile=fs.mkdtempSync(path.join(os.tmpdir(),'openread-chrome-test-'));let context;
  try {
    const extensionPath=path.join(root,'build/chrome/OpenRead');
    context=await chromium.launchPersistentContext(profile,{channel:'chromium',headless:true,viewport:{width:1280,height:900},args:[`--disable-extensions-except=${extensionPath}`,`--load-extension=${extensionPath}`,'--enable-unsafe-extension-debugging','--enable-automation']});
    const worker=context.serviceWorkers()[0]||await context.waitForEvent('serviceworker');const id=worker.url().split('/')[2];
    const page=await context.newPage();await page.goto('http://127.0.0.1:4173/?extension=1');await page.bringToFront();
    const cdp=await context.browser().newBrowserCDPSession();
    const tabs=await cdp.send('Target.getTargets',{filter:[{type:'tab',exclude:false},{exclude:true}]});
    const tab=tabs.targetInfos.find(t=>t.url.includes('127.0.0.1:4173'));assert.ok(tab);
    let sequence=0;const pending=new Map();
    cdp.on('Target.receivedMessageFromTarget',event=>{const result=JSON.parse(event.message);const request=pending.get(result.id);if(request){pending.delete(result.id);result.error?request.reject(new Error(result.error.message)):request.resolve(result.result);}});
    function send(sessionId,method,params={}){const requestId=++sequence;return new Promise((resolve,reject)=>{pending.set(requestId,{resolve,reject});void cdp.send('Target.sendMessageToTarget',{sessionId,message:JSON.stringify({id:requestId,method,params})}).catch(reject);});}
    async function openPopup(){
      const before=await cdp.send('Target.getTargets',{filter:[{}]});const known=new Set(before.targetInfos.map(t=>t.targetId));
      await cdp.send('Extensions.triggerAction',{id,targetId:tab.targetId});
      let target;
      for(let i=0;i<50;i++){const targets=await cdp.send('Target.getTargets',{filter:[{}]});target=targets.targetInfos.find(t=>t.type==='other'&&!known.has(t.targetId));if(target)break;await wait(100);}
      assert.ok(target,'native popup target missing');const{sessionId}=await cdp.send('Target.attachToTarget',{targetId:target.targetId,flatten:false});
      const evaluate=async expression=>{const result=await send(sessionId,'Runtime.evaluate',{expression,returnByValue:true});if(result.exceptionDetails)throw new Error(result.exceptionDetails.text);return result.result.value;};
      for(let i=0;i<100;i++){if(await evaluate('!!document.querySelector(".document-title")'))break;await wait(100);}
      return{targetId:target.targetId,sessionId,evaluate};
    }
    let popup=await openPopup();
    const view=await popup.evaluate('({count:document.querySelectorAll("#voice option").length,voice:document.querySelector("#voice").value,max:document.querySelector("#speed").max,platform:document.documentElement.className,title:document.querySelector(".document-title").textContent})');
    assert.equal(view.count,49);assert.equal(view.voice,'kitten:kiki');assert.equal(view.max,'5');assert.equal(view.platform,'chrome-popup');assert.match(view.title,/Athene Visits Telemachus/);
    const image=await send(popup.sessionId,'Page.captureScreenshot');fs.writeFileSync(path.join(root,'test-results/chrome-extension-popup.png'),Buffer.from(image.data,'base64'));
    const tabId=await worker.evaluate(async()=>{const[t]=await chrome.tabs.query({active:true,currentWindow:true});return t.id;});
    const command=(action,value)=>worker.evaluate(({tabId,action,value})=>chrome.tabs.sendMessage(tabId,{type:'openread:command',action,value}),{tabId,action,value});
    const state=()=>worker.evaluate(id=>chrome.tabs.sendMessage(id,{type:'openread:get-state'}),tabId);
    await command('toggle-playback');let playback;
    for(let i=0;i<150;i++){playback=await state();if(playback.status==='playing'||playback.needsPageGesture)break;await wait(300);}
    try{await cdp.send('Target.closeTarget',{targetId:popup.targetId});}catch{}
    if(playback.needsPageGesture){await page.mouse.click(640,854);for(let i=0;i<100;i++){playback=await state();if(playback.status==='playing')break;await wait(300);}}
    assert.equal(playback.status,'playing',JSON.stringify(playback));assert.equal(playback.error,'');
    popup=await openPopup();assert.equal(await popup.evaluate('document.querySelector(".listen").getAttribute("aria-label")'),'Pause');
    await command('set-rate',5);await command('set-sleep',15);await command('stop');
    const stopped=await state();assert.equal(stopped.status,'idle');assert.equal(stopped.preferences.rate,5);assert.equal(stopped.sleepMinutes,15);
    assert.equal(await popup.evaluate('document.querySelector("#speed").style.getPropertyValue("--speed-progress")'),'100%');
    assert.equal(await popup.evaluate('document.querySelector(".reader-option").hidden'),true);
    assert.equal(await page.locator('[data-openread-host]').count(),1);
    console.log('Actual Chrome extension: real toolbar/activeTab grant and popup, Kitten-first picker, service-worker speech, playback surviving popup close/reopen, live 5× slider, timer and stop — passed.');
  }finally{await context?.close();fs.rmSync(profile,{recursive:true,force:true});}
})().catch(error=>{console.error(error);process.exitCode=1;});
