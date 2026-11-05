'use strict';
// Execute the real background worker against in-memory Chrome/storage/fetch fakes.
// No browser instance, endpoint, user configuration or real clock delay is used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '..', '..', '..', 'browser-extension', 'background.js'), 'utf8');
const epoch = Date.parse('2026-09-07T12:00:00Z');
const keywords = [{ name: '告警抽查邮件', terms: ['告警抽查邮件'] }];
const id = number => `00000000-0000-4000-8000-000000000001:${number}`;
let assertions = 0;
const failures = [];
function check(value, label) { assertions++; assert.ok(value, label); }
function equal(actual, expected, label) { assertions++; assert.deepEqual(structuredClone(actual), expected, label); }
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
async function ticks(count = 100) { for (let i = 0; i < count; i++) await Promise.resolve(); }
async function responsive(promise, label) {
  let done = false, result, error;
  promise.then(value => { done = true; result = value; }, value => { done = true; error = value; });
  await ticks();
  check(done, label);
  if (error) throw error;
  return result;
}
function response(value, status = 200) { return { status, json: async () => structuredClone(value) }; }
function event(number, extra = {}) { return { eventId: id(number), keyword: keywords[0].name, createdAt: new Date(epoch).toISOString(), attempts: 0, nextAt: 0, ...extra }; }
function storage(initial) {
  return {
    async get(keys) {
      if (keys == null) return structuredClone(initial);
      const result = {};
      for (const key of typeof keys === 'string' ? [keys] : Array.isArray(keys) ? keys : Object.keys(keys)) {
        if (Object.hasOwn(initial, key)) result[key] = structuredClone(initial[key]);
        else if (keys && typeof keys === 'object' && !Array.isArray(keys)) result[key] = structuredClone(keys[key]);
      }
      return result;
    },
    async set(values) { Object.assign(initial, structuredClone(values)); },
    async remove(keys) { for (const key of Array.isArray(keys) ? keys : [keys]) delete initial[key]; }
  };
}
function harness({ persisted, fetcher, now = epoch } = {}) {
  const data = persisted || { local: { token: 'a'.repeat(64) }, session: { monitor: { tabId: 7, keywords } } };
  let time = now;
  let activeTab = { id: 7, url: 'https://mail.example.invalid/inbox' };
  const callbacks = {}, timers = [], requests = [], injections = [], tabMessages = [], badges = [], alarms = [];
  const listener = name => ({ addListener(fn) { callbacks[name] = fn; } });
  class FakeDate extends Date { constructor(...args) { super(...(args.length ? args : [time])); } static now() { return time; } }
  const chrome = {
    storage: { local: storage(data.local), session: storage(data.session) },
    runtime: { getURL: name => `chrome-extension://synthetic/${name}`, onMessage: listener('message') },
    action: { async setBadgeText(value) { badges.push(value.text); }, async setBadgeBackgroundColor() {} },
    alarms: { async create(name, value) { alarms.push({ name, ...value }); }, async clear() {}, onAlarm: listener('alarm') },
    tabs: {
      async query() { return [structuredClone(activeTab)]; },
      async sendMessage(tabId, message) { tabMessages.push({ tabId, ...message }); return { ok: true }; },
      onRemoved: listener('removed'), onUpdated: listener('updated')
    },
    scripting: { async executeScript(value) { injections.push(value); return []; } }
  };
  const context = {
    chrome, Date: FakeDate, console,
    AbortSignal: { timeout: ms => ({ syntheticTimeout: ms }) },
    setTimeout: fn => { timers.push(fn); return timers.length; }, clearTimeout() {},
    fetch: async (url, options) => {
      const request = { url, method: options.method, body: options.body ? JSON.parse(options.body) : null };
      requests.push(request);
      if (fetcher) return fetcher(request);
      return response(url.endsWith('/status') ? { configured: true, keywords } : { status: 'Success' });
    }
  };
  vm.runInNewContext(source, context, { filename: 'background.js' });
  return {
    data, requests, injections, tabMessages, badges, alarms,
    advance(ms) { time += ms; },
    selectTab(tab) { activeTab = tab; },
    async flush() { await ticks(); while (timers.length) { const current = timers.splice(0); for (const fn of current) fn(); await ticks(); } await ticks(); },
    message(message, sender = { tab: { id: 7 } }) { return new Promise(resolve => callbacks.message(message, sender, resolve)); },
    popup(message) { return this.message(message, { url: chrome.runtime.getURL('popup.html') }); },
    alarm() { callbacks.alarm({ name: 'delivery' }); },
    remove(tabId = 7) { callbacks.removed(tabId); },
    update(change, tabId = 7) { callbacks.updated(tabId, change); }
  };
}
async function test(name, run) {
  try { await run(); }
  catch (error) { failures.push(`${name}: ${error.message}`); }
}

(async () => {
  await test('pending network leaves heartbeat, enqueue and stop responsive', async () => {
    const gate = deferred();
    const h = harness({ fetcher: () => gate.promise });
    await responsive(h.message({ type: 'alert-event', ...event(1) }), 'initial event is accepted into the queue');
    await h.flush();
    equal(h.requests.length, 1, 'one request is in flight');
    equal(await responsive(h.message({ type: 'heartbeat', readable: 200, canvas: false }), 'heartbeat is not blocked by fetch'), { ok: true }, 'heartbeat acknowledges');
    equal(await responsive(h.message({ type: 'alert-event', ...event(2) }), 'new event queues while fetch is pending'), { queued: true }, 'new event queue ack');
    equal(h.data.session.queue.length, 2, 'in-flight and newly queued event coexist');
    equal(await responsive(h.popup({ type: 'stop' }), 'stop is not blocked by fetch'), { ok: true }, 'stop acknowledges');
    check(!h.data.session.monitor && !h.data.session.queue, 'stop clears monitor and pending events immediately');
    gate.resolve(response({ status: 'Success' }));
    await h.flush();
    check(!h.data.session.monitor && !h.data.session.queue, 'late network result does not resurrect stopped state');
    equal(h.requests.length, 1, 'stop prevents sending the second queued event');
  });

  await test('network failure replays the original id and stops after success', async () => {
    let calls = 0;
    const h = harness({ fetcher: async () => { if (++calls === 1) throw new TypeError('Synthetic lost response'); return response({ status: 'Success' }); } });
    await responsive(h.message({ type: 'alert-event', ...event(3) }), 'event queues');
    await h.flush();
    equal(h.data.session.queue[0].attempts, 1, 'first attempt is persisted before replay');
    h.advance(30000); h.alarm(); await h.flush();
    equal(h.requests.map(r => r.body.eventId), [id(3), id(3)], 'replay never creates a new event id');
    equal(h.data.session.queue.length, 0, 'success removes the event');
    h.advance(30000); h.alarm(); await h.flush();
    equal(h.requests.length, 2, 'terminal success is not replayed');
  });

  await test('receiver uncertain and permanent responses are terminal', async () => {
    for (const status of ['Uncertain', 'PermanentFailure']) {
      const h = harness({ fetcher: async () => response({ status }) });
      await responsive(h.message({ type: 'alert-event', ...event(4) }), 'event queues');
      await h.flush();
      equal(h.data.session.queue.length, 0, `${status} removes the event`);
      h.advance(30000); h.alarm(); await h.flush();
      equal(h.requests.length, 1, `${status} does not resend`);
    }
  });

  await test('definite failure remains retryable and respects attempt budget', async () => {
    const h = harness({ fetcher: async () => response({ status: 'RetryableFailure' }) });
    await responsive(h.message({ type: 'alert-event', ...event(5) }), 'event queues');
    await h.flush();
    h.alarm(); await h.flush();
    equal(h.requests.length, 1, 'alarm does not bypass retry cooldown');
    for (let i = 0; i < 4; i++) { h.advance(30000); h.alarm(); await h.flush(); }
    equal(h.requests.length, 3, 'network attempts are bounded at three');
    equal(h.data.session.queue.length, 0, 'exhausted event leaves the queue');
  });

  await test('worker reconstruction restores queue, attempts and enabled tab', async () => {
    const gate = deferred();
    const first = harness({ fetcher: () => gate.promise });
    await responsive(first.message({ type: 'alert-event', ...event(6) }), 'event queues before worker termination');
    await first.flush();
    equal(first.data.session.queue[0].attempts, 1, 'claimed attempt survives in session storage');
    // The old VM remains suspended and is never resumed, as with a terminated worker.
    const restarted = harness({ persisted: first.data, now: epoch + 30000 });
    await restarted.flush();
    restarted.alarm(); await restarted.flush();
    equal(restarted.data.session.monitor.tabId, 7, 'enabled tab survives worker reconstruction');
    equal(restarted.requests.map(r => r.body.eventId), [id(6)], 'restarted worker replays only the same id');
    equal(restarted.data.session.queue.length, 0, 'restored event reaches terminal success');
  });

  await test('closing or refreshing monitored tab stops queued delivery', async () => {
    for (const action of ['close', 'refresh']) {
      const gate = deferred();
      const h = harness({ fetcher: () => gate.promise });
      await responsive(h.message({ type: 'alert-event', ...event(7) }), 'event queues');
      await h.flush();
      if (action === 'close') h.remove(); else h.update({ status: 'loading' });
      await ticks();
      check(!h.data.session.monitor, `${action} stops monitor without waiting for fetch`);
      check(!h.data.session.queue, `${action} cancels remaining queue`);
      equal(await responsive(h.message({ type: 'alert-event', ...event(8) }), 'stopped page receives a response'), { stopped: true }, 'stopped tab cannot queue more events');
      gate.resolve(response({ status: 'Success' })); await h.flush();
      check(!h.data.session.queue, 'late response cannot resurrect cancelled events');
    }
  });

  await test('unrelated tab lifecycle and completed loads do not stop monitoring', async () => {
    const h = harness();
    h.remove(8); h.update({ status: 'loading' }, 8); h.update({ status: 'complete' });
    await h.flush();
    equal(h.data.session.monitor.tabId, 7, 'only the monitored tab loading or closing stops it');
    equal(await responsive(h.message({ type: 'get-monitor' }), 'monitor lookup responds'), { enabled: true, keywords }, 'enabled content keeps the configured keywords');
  });

  await test('stop cancels a pending start status request', async () => {
    const gate = deferred();
    const h = harness({ persisted: { local: { token: 'a'.repeat(64) }, session: {} }, fetcher: () => gate.promise });
    const start = h.popup({ type: 'start' }); await h.flush();
    await responsive(h.popup({ type: 'stop' }), 'stop responds while start is checking the receiver');
    gate.resolve(response({ configured: true, keywords }));
    await responsive(start, 'cancelled start eventually resolves'); await h.flush();
    check(!h.data.session.monitor, 'old start completion cannot restart monitoring after stop');
    equal(h.injections.length, 0, 'cancelled start does not inject a content script');
  });

  await test('receiver status probe does not block active-page events', async () => {
    const gate = deferred();
    const h = harness({ fetcher: request => request.url.endsWith('/status') ? gate.promise : response({ status: 'Success' }) });
    const status = h.popup({ type: 'status' }); await h.flush();
    equal(await responsive(h.message({ type: 'heartbeat', readable: 100 }), 'heartbeat responds while status probe is pending'), { ok: true }, 'active page stays responsive');
    gate.resolve(response({ configured: true, keywords }));
    await responsive(status, 'status response completes after network reply');
  });

  await test('start keeps the originally chosen tab during a slow receiver check', async () => {
    const gate = deferred();
    const h = harness({ persisted: { local: { token: 'a'.repeat(64) }, session: {} }, fetcher: () => gate.promise });
    const start = h.popup({ type: 'start' }); await h.flush();
    h.selectTab({ id: 8, url: 'https://other.example.invalid/' });
    gate.resolve(response({ configured: true, keywords }));
    await responsive(start, 'start finishes after receiver check');
    equal(h.data.session.monitor.tabId, 7, 'network delay cannot change the tab the user chose');
    equal(h.injections[0].target.tabId, 7, 'injection uses the original target tab');
  });

  await test('navigation cancels a start whose receiver check is pending', async () => {
    const gate = deferred();
    const h = harness({ persisted: { local: { token: 'a'.repeat(64) }, session: {} }, fetcher: () => gate.promise });
    const start = h.popup({ type: 'start' }); await h.flush();
    h.update({ status: 'loading' }); await ticks();
    gate.resolve(response({ configured: true, keywords }));
    await responsive(start, 'cancelled navigation start resolves');
    check(!h.data.session.monitor, 'navigation before readiness leaves monitoring stopped');
    equal(h.injections.length, 0, 'a changed page is not injected by the pending start');
  });

  await test('full queue still acknowledges an already-persisted duplicate', async () => {
    const persisted = { local: { token: 'a'.repeat(64) }, session: { monitor: { tabId: 7, keywords }, queue: Array.from({ length: 100 }, (_, i) => event(i + 1, { nextAt: epoch + 100000 })) } };
    const h = harness({ persisted });
    equal(await responsive(h.message({ type: 'alert-event', ...event(1) }), 'duplicate queue request responds'), { queued: true }, 'existing id is acknowledged even at capacity');
    equal(await responsive(h.message({ type: 'alert-event', ...event(101) }), 'new queue request responds'), { queued: false }, 'new event is back-pressured at capacity');
    equal(h.data.session.queue.length, 100, 'capacity and dedupe remain intact');
  });

  await test('unauthorized tab cannot queue, stop or pair', async () => {
    const h = harness();
    equal(await responsive(h.message({ type: 'alert-event', ...event(9) }, { tab: { id: 8 } }), 'unmonitored tab event responds'), { stopped: true }, 'event from another tab is rejected');
    check((await responsive(h.message({ type: 'stop' }), 'content stop request responds')).error, 'content cannot stop through popup control route');
    check((await responsive(h.message({ type: 'pair', token: 'b'.repeat(64) }), 'content pairing request responds')).error, 'content cannot change the pairing token');
    equal(h.data.local.token, 'a'.repeat(64), 'token stays unchanged');
  });

  if (failures.length) {
    for (const failure of failures) process.stderr.write(`FAIL: ${failure}\n`);
    process.stderr.write(`${failures.length} browser lifecycle cases failed; ${assertions} assertions evaluated.\n`);
    process.exitCode = 1;
  } else process.stdout.write(`PASS: 13 browser lifecycle cases; ${assertions} assertions; Chrome APIs, storage and network are mocked.\n`);
})().catch(error => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
