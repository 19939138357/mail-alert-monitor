'use strict';
// Real content.js + core.js, synthetic DOM and in-memory extension messaging only.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..', '..', '..', 'browser-extension');
const source = fs.readFileSync(path.join(root, 'content.js'), 'utf8');
const core = fs.readFileSync(path.join(root, 'core.js'), 'utf8');
const epoch = Date.parse('2026-09-07T12:00:00Z');
const keywords = [{ name: '告警抽查邮件', terms: ['告警抽查邮件'] }];
let assertions = 0, cases = 0;
const failures = [];
function check(value, label) { assertions++; assert.ok(value, label); }
function equal(actual, expected, label) { assertions++; assert.deepEqual(structuredClone(actual), expected, label); }
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
async function ticks() { for (let i = 0; i < 80; i++) await Promise.resolve(); }
function harness(handler = async () => undefined) {
  const listeners = new Set(), timers = new Map(), messages = [], scans = [];
  let now = epoch, timerId = 0, session = 0;
  const document = { body: { innerText: '收件箱' }, querySelector: () => null };
  class FakeDate extends Date { constructor(...args) { super(...(args.length ? args : [now])); } static now() { return now; } }
  const context = vm.createContext({
    document, Date: FakeDate, console,
    crypto: { randomUUID: () => `00000000-0000-4000-8000-${String(++session).padStart(12, '0')}` },
    setInterval(fn, ms) { const id = ++timerId; timers.set(id, { fn, ms }); return id; },
    clearInterval(id) { timers.delete(id); },
    chrome: { runtime: {
      onMessage: { addListener(fn) { listeners.add(fn); }, removeListener(fn) { listeners.delete(fn); } },
      async sendMessage(message) {
        messages.push(structuredClone(message));
        const value = await handler(structuredClone(message), messages);
        if (value !== undefined) return value;
        if (message.type === 'get-monitor') return { enabled: true, keywords };
        if (message.type === 'alert-event') return { queued: true };
        return { ok: true };
      }
    } }
  });
  vm.runInContext(core, context, { filename: 'core.js' });
  const ActualDetector = context.BrowserAlertCore.Detector;
  context.BrowserAlertCore.Detector = class extends ActualDetector {
    scan(text) { scans.push({ time: now, text }); return super.scan(text); }
  };
  return {
    context, messages, scans, listeners, timers, document,
    inject() { vm.runInContext(source, context, { filename: 'content.js' }); },
    async run() { for (const { fn } of [...timers.values()]) fn(); await ticks(); },
    async at(ms) { now = epoch + ms; await this.run(); },
    text(value) { document.body = value === null ? null : { innerText: value }; },
    stop() { for (const fn of [...listeners]) fn({ type: 'stop-monitor' }, {}, () => {}); },
    count(type) { return messages.filter(message => message.type === type).length; }
  };
}
function single(h, label) {
  equal(h.timers.size, 1, label + ': one timer');
  equal(h.listeners.size, 1, label + ': one listener');
  equal(h.context.__mailAlertRunning, true, label + ': current global remains active');
}
async function test(name, run) {
  cases++;
  try { await run(); } catch (error) { failures.push(`${name}: ${error.message}`); }
}

(async () => {
  await test('duplicate injection is one instance and stop releases it', async () => {
    const h = harness();
    h.inject(); h.inject(); await ticks();
    single(h, 'duplicate injection');
    equal(h.count('get-monitor'), 1, 'only one bootstrap request');
    h.stop(); h.stop();
    equal(h.timers.size, 0, 'stop clears the timer');
    equal(h.listeners.size, 0, 'stop removes the message listener');
    equal(h.context.__mailAlertRunning, false, 'stop clears the shared flag');
    h.inject(); await ticks(); single(h, 'new instance after stop');
  });

  await test('four-second settling period and two fresh observations', async () => {
    const h = harness();
    h.text('告警抽查邮件：历史业务A');
    h.inject(); await ticks();
    await h.at(1000); await h.at(3999);
    equal(h.scans.length, 0, 'initial settling period does not scan');
    await h.at(4000);
    equal(h.scans.length, 1, 'first scan starts at four seconds');
    equal(h.count('alert-event'), 0, 'loaded history establishes the baseline');
    h.text('告警抽查邮件：历史业务A\n告警抽查邮件：新增业务B');
    await h.at(5000);
    equal(h.count('alert-event'), 0, 'one new observation does not send');
    await h.at(6000);
    equal(h.count('alert-event'), 1, 'second new observation queues one event');
    await h.at(7000);
    equal(h.count('alert-event'), 1, 'unchanged mail is not queued again');
  });

  await test('missing body does not consume the first readable baseline', async () => {
    const h = harness(); h.text(null); h.inject(); await ticks();
    await h.at(4000);
    h.text('告警抽查邮件：迟到的历史列表');
    await h.at(5000); await h.at(6000);
    equal(h.count('alert-event'), 0, 'late initial body remains startup history');
  });

  for (const outcome of ['resolve', 'reject']) {
    await test(`old bootstrap ${outcome} cannot affect a restarted instance`, async () => {
      const old = deferred(); let bootstraps = 0;
      const h = harness(message => message.type === 'get-monitor' && ++bootstraps === 1 ? old.promise : undefined);
      h.inject(); await ticks();
      equal(h.timers.size, 0, 'first bootstrap is pending');
      h.stop(); h.inject(); await ticks();
      single(h, 'replacement before old bootstrap completes');
      if (outcome === 'resolve') old.resolve({ enabled: true, keywords }); else old.reject(new Error('Synthetic old bootstrap failure'));
      await ticks();
      single(h, 'replacement after old bootstrap completes');
      h.inject(); await ticks();
      single(h, 'late completion did not reopen the injection guard');
    });
  }

  for (const outcome of ['stopped', 'reject']) {
    await test(`old heartbeat ${outcome} cannot stop a newer instance`, async () => {
      const heartbeat = deferred(); let heartbeats = 0;
      const h = harness(message => message.type === 'heartbeat' && ++heartbeats === 1 ? heartbeat.promise : undefined);
      h.inject(); await ticks(); await h.at(4000);
      equal(h.count('heartbeat'), 1, 'old heartbeat is pending');
      h.stop(); h.inject(); await ticks();
      single(h, 'new instance before old heartbeat');
      if (outcome === 'stopped') heartbeat.resolve({ stopped: true }); else heartbeat.reject(new Error('Synthetic old heartbeat failure'));
      await ticks();
      single(h, 'new instance after old heartbeat');
      h.inject(); await ticks();
      single(h, 'old heartbeat cannot permit duplicate injection');
    });
  }

  await test('busy scan has one in-flight message and resumes after acknowledgement', async () => {
    const heartbeat = deferred(), alert = deferred();
    const h = harness(message => message.type === 'heartbeat' ? heartbeat.promise : message.type === 'alert-event' ? alert.promise : undefined);
    h.inject(); await ticks(); await h.at(4000);
    for (let i = 0; i < 10; i++) await h.run();
    equal(h.scans.length, 1, 'heartbeat wait prevents overlapping scans');
    equal(h.count('heartbeat'), 1, 'only one heartbeat in flight');
    heartbeat.resolve({ ok: true }); await ticks();
    h.text('告警抽查邮件：新业务'); await h.at(5000); await h.at(6000);
    equal(h.count('alert-event'), 1, 'one alert waits for its queue acknowledgement');
    for (let i = 0; i < 10; i++) await h.run();
    equal(h.scans.length, 3, 'queue acknowledgement wait prevents overlapping scans');
    equal(h.count('alert-event'), 1, 'pending acknowledgement does not multiply messages');
    alert.resolve({ queued: true }); await ticks(); await h.at(7000);
    equal(h.scans.length, 4, 'scanning resumes after acknowledgement');
    equal(h.count('alert-event'), 1, 'acknowledged event is removed from local pending');
  });

  await test('backpressure retries exactly the same pending event identity', async () => {
    let alerts = 0;
    const h = harness(message => message.type === 'alert-event' ? { queued: ++alerts > 1 } : undefined);
    h.inject(); await ticks(); await h.at(4000);
    h.text('告警抽查邮件：新业务'); await h.at(5000); await h.at(6000); await h.at(7000); await h.at(8000);
    const sent = h.messages.filter(message => message.type === 'alert-event');
    equal(sent.length, 2, 'not-yet-queued event retries, then stops after ACK');
    equal(sent[0].eventId, sent[1].eventId, 'backpressure cannot regenerate event identity');
    equal(sent[0].createdAt, sent[1].createdAt, 'backpressure cannot reset event age');
    equal(Object.keys(sent[0]).sort(), ['createdAt', 'eventId', 'keyword', 'type'], 'only minimal event metadata leaves the page');
  });

  await test('stop during queue acknowledgement cancels the remaining old batch', async () => {
    const oldAlert = deferred(); let alerts = 0;
    const h = harness(message => message.type === 'alert-event' && ++alerts === 1 ? oldAlert.promise : undefined);
    h.inject(); await ticks(); await h.at(4000);
    h.text('告警抽查邮件：新业务A\n告警抽查邮件：新业务B');
    await h.at(5000); await h.at(6000);
    equal(h.count('alert-event'), 1, 'first old event is waiting');
    h.stop(); h.inject(); await ticks();
    oldAlert.resolve({ queued: true }); await ticks();
    equal(h.count('alert-event'), 1, 'stopped instance cannot send its second pending event');
    single(h, 'old queue acknowledgement leaves replacement alone');
  });

  await test('disabled or failed bootstrap releases all lifecycle resources', async () => {
    for (const failure of [false, true]) {
      const h = harness(message => {
        if (message.type !== 'get-monitor') return;
        if (failure) return Promise.reject(new Error('Synthetic bootstrap failure'));
        return { enabled: false };
      });
      h.inject(); await ticks();
      equal(h.timers.size, 0, 'failed bootstrap starts no timer');
      equal(h.listeners.size, 0, 'failed bootstrap removes listener');
      equal(h.context.__mailAlertRunning, false, 'failed bootstrap allows explicit restart');
    }
  });

  if (failures.length) {
    for (const failure of failures) process.stderr.write(`FAIL: ${failure}\n`);
    process.stderr.write(`${failures.length}/${cases} content lifecycle cases failed; ${assertions} assertions evaluated.\n`);
    process.exitCode = 1;
  } else process.stdout.write(`PASS: ${cases} content lifecycle cases; ${assertions} assertions; synthetic DOM, clock and Chrome messaging only.\n`);
})().catch(error => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
