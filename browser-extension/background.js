'use strict';
const endpoint = 'http://127.0.0.1:17368';
let serial = Promise.resolve();
let controlGeneration = 0;
let pendingStart = null;
let drainPromise = null;
let drainRequested = false;
// Protect short state transitions only; never hold this lock across network I/O.
const locked = task => {
  const result = serial.then(task);
  serial = result.catch(() => {});
  return result;
};
async function api(path, data) {
  const { token } = await chrome.storage.local.get('token');
  if (!/^[a-f0-9]{64}$/.test(token || '')) throw Error('请先填写本机配对码');
  const response = await fetch(endpoint + path, {
    method: data ? 'POST' : 'GET',
    headers: { 'X-Monitor-Token': token, ...(data ? { 'Content-Type': 'application/json' } : {}) },
    body: data ? JSON.stringify(data) : undefined,
    signal: AbortSignal.timeout(20000)
  });
  return { ...await response.json(), httpStatus: response.status };
}
async function badge(text, color = '#22734d') {
  await chrome.action.setBadgeText({ text });
  await chrome.action.setBadgeBackgroundColor({ color });
}
async function claimEvent() {
  return locked(async () => {
    const { queue = [], monitor } = await chrome.storage.session.get(['queue', 'monitor']);
    const now = Date.now();
    const pending = queue.filter(event => now - Date.parse(event.createdAt) <= 120000 && (event.attempts || 0) < 3);
    if (pending.length !== queue.length) {
      await chrome.storage.session.set({ queue: pending, lastResult: '告警未能确认送达，请检查接收端和推送设置' });
      if (monitor) await badge('!', '#b45309');
    }
    const event = pending.find(item => !(item.nextAt > now));
    if (!event) return null;
    event.attempts = (event.attempts || 0) + 1;
    event.nextAt = now + 10000;
    // Persist identity and attempt before the worker can be terminated.
    await chrome.storage.session.set({ queue: pending });
    return { ...event };
  });
}
async function finishEvent(event, result) {
  return locked(async () => {
    const { queue = [], monitor } = await chrome.storage.session.get(['queue', 'monitor']);
    const index = queue.findIndex(item => item.eventId === event.eventId && item.attempts === event.attempts);
    // Stop, navigation or a new session may have cancelled this event already.
    if (index < 0) return;
    let lastResult;
    if (result.status === 'Success') {
      lastResult = '推送服务已接受告警，请以手机实际收件为准';
      queue.splice(index, 1);
    } else if (result.status === 'Uncertain') {
      lastResult = '发送结果不确定，请检查手机；已停止自动重发';
      queue.splice(index, 1);
    } else if (result.status === 'RetryableFailure') {
      lastResult = '发送暂时失败，稍后重试';
    } else if (result.status === 'ReplaySameId') {
      // Receiver journals Sending before external delivery. A restart replays the
      // receipt as Uncertain; this is never a newly generated delivery identity.
      lastResult = '本机接收端未响应，将使用同一事件编号查询处理结果';
    } else {
      lastResult = result.message || '推送配置错误，请重新设置';
      queue.splice(index, 1);
    }
    await chrome.storage.session.set({ queue, lastResult });
    if (monitor) {
      const accepted = result.status === 'Success' && !queue.length;
      await badge(accepted ? 'ON' : '!', accepted ? '#22734d' : '#b45309');
    }
  });
}
async function runDrain() {
  // Only deliveries are serial. Controls and content messages keep using the lock.
  for (let count = 0; count < 100; count++) {
    const event = await claimEvent();
    if (!event) return;
    let result;
    try {
      result = await api('/trigger', { eventId: event.eventId, keyword: event.keyword, createdAt: event.createdAt });
    } catch {
      result = { status: 'ReplaySameId' };
    }
    await finishEvent(event, result);
  }
}
function requestDrain() {
  drainRequested = true;
  if (drainPromise) return drainPromise;
  drainPromise = (async () => {
    do {
      drainRequested = false;
      await runDrain();
    } while (drainRequested);
  })().catch(() => {}).finally(() => { drainPromise = null; });
  return drainPromise;
}
async function stopState({ tabId, message, badgeText = '' } = {}) {
  return locked(async () => {
    const { monitor } = await chrome.storage.session.get('monitor');
    const targetmonitor = tabId === undefined || monitor?.tabId === tabId;
    const targetsStart = tabId !== undefined && pendingStart?.tabId === tabId;
    if (!targetmonitor && !targetsStart) return null;
    controlGeneration++;
    pendingStart = null;
    // Cancelling a different pending target must not stop an existing monitor.
    if (!targetmonitor) return null;
    await chrome.storage.session.remove(['monitor', 'queue', 'heartbeat']);
    if (message) await chrome.storage.session.set({ lastResult: message });
    await badge(badgeText, badgeText ? '#b45309' : '#22734d');
    return monitor;
  });
}
async function handleMessage(message, sender) {
  if (!message || typeof message !== 'object') throw Error('无效操作');
  const fromPopup = !sender.tab && sender.url === chrome.runtime.getURL('popup.html');
  if (message.type === 'get-monitor' || message.type === 'heartbeat' || message.type === 'alert-event') {
    return locked(async () => {
      const { monitor } = await chrome.storage.session.get('monitor');
      const enabled = !!monitor && sender.tab?.id === monitor.tabId;
      if (message.type === 'get-monitor') return { enabled, keywords: enabled ? monitor.keywords : [] };
      if (!enabled) return { stopped: true };
      if (message.type === 'heartbeat') {
        await chrome.storage.session.set({ heartbeat: { time: Date.now(), readable: message.readable, canvas: !!message.canvas } });
        return { ok: true };
      }
      if (!monitor.keywords.some(k => k.name === message.keyword) || !/^[a-f0-9-]{36}:\d{1,8}$/.test(message.eventId || '') || !Number.isFinite(Date.parse(message.createdAt))) throw Error('无效告警');
      const { queue = [] } = await chrome.storage.session.get('queue');
      if (queue.some(event => event.eventId === message.eventId)) return { queued: true };
      if (queue.length >= 100) return { queued: false };
      queue.push({ eventId: message.eventId, keyword: message.keyword, createdAt: message.createdAt, attempts: 0, nextAt: 0 });
      await chrome.storage.session.set({ queue });
      await chrome.alarms.create('delivery', { periodInMinutes: 0.5 });
      setTimeout(requestDrain, 0);
      return { queued: true };
    });
  }
  if (!fromPopup) throw Error('仅设置窗口可执行此操作');
  if (message.type === 'pair') {
    if (!/^[a-f0-9]{64}$/.test(message.token || '')) throw Error('配对码应为64位');
    await locked(() => chrome.storage.local.set({ token: message.token }));
    return api('/status');
  }
  if (message.type === 'status') {
    let receiver;
    try { receiver = await api('/status'); } catch (error) { receiver = { message: error.message }; }
    return { ...await chrome.storage.session.get(['monitor', 'lastResult', 'heartbeat', 'queue']), receiver };
  }
  if (message.type === 'stop') {
    const monitor = await stopState();
    if (monitor) await chrome.tabs.sendMessage(monitor.tabId, { type: 'stop-monitor' }).catch(() => {});
    return { ok: true };
  }
  if (message.type === 'start') {
    const generation = await locked(() => ++controlGeneration);
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!/^https?:\/\//.test(tab?.url || '')) throw Error('请在邮箱网页中开启监控');
    const selected = await locked(() => {
      if (generation !== controlGeneration) return false;
      pendingStart = { generation, tabId: tab.id };
      return true;
    });
    if (!selected) return { cancelled: true };
    try {
    const status = await api('/status');
    if (!status.configured || !status.keywords?.length) throw Error(status.message || '请先配置微信、QQ邮箱或钉钉推送');
    const starting = await locked(async () => {
      if (generation !== controlGeneration) return null;
      const { monitor } = await chrome.storage.session.get('monitor');
      await chrome.storage.session.set({ monitor: { tabId: tab.id, keywords: status.keywords }, queue: [], lastResult: '等待页面加载并建立基线' });
      return { previous: monitor };
    });
    if (!starting) return { cancelled: true };
    if (starting.previous) await chrome.tabs.sendMessage(starting.previous.tabId, { type: 'stop-monitor' }).catch(() => {});
    if (generation !== controlGeneration) return { cancelled: true };
    try {
      await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['core.js', 'content.js'] });
    } catch (error) {
      await locked(async () => {
        if (generation === controlGeneration) await chrome.storage.session.remove(['monitor', 'queue', 'heartbeat']);
      });
      throw error;
    }
    if (generation !== controlGeneration) return { cancelled: true };
    await badge('ON');
    return { ok: true };
    } finally {
      await locked(() => { if (pendingStart?.generation === generation) pendingStart = null; });
    }
  }
  throw Error('未知操作');
}
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  handleMessage(message, sender).then(reply, error => reply({ error: error.message || '操作失败' }));
  return true;
});
chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name === 'delivery') requestDrain(); });
chrome.tabs.onRemoved.addListener(tabId => { stopState({ tabId, message: '邮箱标签页关闭，监控已停止', badgeText: 'OFF' }).catch(() => {}); });
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === 'loading') stopState({ tabId, message: '页面已刷新或跳转，请重新开启本页监控', badgeText: 'OFF' }).catch(() => {});
});
// Restore delivery wakeups when this ephemeral worker is reconstructed.
chrome.storage.session.get('queue').then(async ({ queue = [] }) => {
  if (queue.length) {
    await chrome.alarms.create('delivery', { periodInMinutes: 0.5 });
    requestDrain();
  }
}).catch(() => {});
