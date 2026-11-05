(() => {
  if (globalThis.__mailAlertRunning) return;
  globalThis.__mailAlertRunning = true;
  let detector, timer, lastHeartbeat = 0, busy = false, active = true;
  const started = Date.now(), session = crypto.randomUUID(), pending = new Map();
  function onMessage(message,sender,reply) {if(message.type === 'stop-monitor') {stop();reply({ok:true});}}
  function stop() {if(!active)return;active=false;clearInterval(timer);chrome.runtime.onMessage.removeListener(onMessage);globalThis.__mailAlertRunning = false;}
  async function scan() {
    if (!active || !detector || busy) return;
    busy = true;
    try {
      const text = (document.body?.innerText || '').slice(0,500000);
      if (Date.now() - started < 4000) return;
      for (const event of detector.scan(text)) {
        const eventId = session + ':' + event.id;
        pending.set(eventId,{type:'alert-event',eventId,keyword:event.keyword,createdAt:new Date().toISOString()});
      }
      for (const [id,event] of pending) {
        if(!active)return;
        const reply = await chrome.runtime.sendMessage(event);
        if(!active)return;
        if (reply?.queued || reply?.stopped) pending.delete(id);
      }
      if (Date.now() - lastHeartbeat > 15000) {
        lastHeartbeat = Date.now();
        const r = await chrome.runtime.sendMessage({type:'heartbeat',readable:text.trim().length,canvas:!!document.querySelector('canvas')});
        if (r?.stopped) stop();
      }
    } catch { stop(); } finally {busy=false;}
  }
  chrome.runtime.onMessage.addListener(onMessage);
  chrome.runtime.sendMessage({type:'get-monitor'}).then(r => {
    if(!active)return;
    if (!r?.enabled) {stop(); return;}
    detector = new BrowserAlertCore.Detector({keywords:r.keywords,stableScans:2});
    timer = setInterval(scan,1000);
  }).catch(stop);
})();
