'use strict';

// Pure synthetic page text. No browser, page, configuration, token or network is used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const corePath = path.join(__dirname, '..', '..', '..', 'browser-extension', 'core.js');
const { Detector } = require(corePath);
const keywords = [
  { name: '告警抽查邮件', terms: ['告警抽查邮件', '抽查邮件'] },
  { name: '客服电话检查', terms: ['客服电话检查', '电话检查'] }
];
let checks = 0;
let cases = 0;
const failures = [];

function check(condition, message) { checks++; assert.ok(condition, message); }
function equal(actual, expected, message) { checks++; assert.deepEqual(actual, expected, message); }
function fresh(options = {}) { return new Detector({ keywords, ...options }); }
function scan(detector, text) {
  const result = detector.scan(text);
  check(Array.isArray(result), 'scan returns an event array');
  for (const event of result) {
    equal(Object.keys(event).sort(), ['id', 'keyword'], 'events expose only id and keyword');
    check(typeof event.id === 'string' && event.id.length > 0 && event.id.length <= 160, 'event id is a bounded nonempty string');
    check(keywords.some(k => k.name === event.keyword), 'event uses a configured canonical keyword');
  }
  return result;
}
function empty(detector, text, message) { equal(scan(detector, text), [], message); }
function test(name, run) {
  cases++;
  try { run(); }
  catch (error) { failures.push(`${name}: ${error.message}`); }
}

test('CommonJS and browser global expose the same public API', () => {
  check(typeof Detector === 'function', 'CommonJS exports Detector');
  const browserContext = { crypto: require('node:crypto').webcrypto, TextEncoder, TextDecoder };
  vm.runInNewContext(fs.readFileSync(corePath, 'utf8'), browserContext, { filename: corePath });
  check(browserContext.BrowserAlertCore && typeof browserContext.BrowserAlertCore.Detector === 'function', 'browser global exports Detector');
  const browserDetector = new browserContext.BrowserAlertCore.Detector({ keywords });
  equal(JSON.parse(JSON.stringify(browserDetector.scan('收件箱'))), [], 'browser build establishes a baseline');
});

test('existing history is baseline, not an alert', () => {
  const d = fresh();
  for (let i = 0; i < 5; i++) empty(d, '收件箱\n告警抽查邮件：历史业务A\n客服电话检查：历史业务B', 'unchanged startup mail stays silent');
});

test('empty loading page does not consume the startup baseline', () => {
  const d = fresh();
  for (const value of ['', ' \t\r\n', null, undefined]) empty(d, value, 'no readable text does not initialize an empty-mail baseline');
  empty(d, '告警抽查邮件：已存在邮件', 'first readable mail is the baseline');
  empty(d, '告警抽查邮件：已存在邮件', 'baseline remains silent after confirmation');
});

test('new mail needs two stable observations and delivers once', () => {
  const d = fresh();
  empty(d, '收件箱暂无告警', 'readable baseline');
  empty(d, '告警抽查邮件：新业务A', 'one observation is insufficient');
  const events = scan(d, '告警抽查邮件：新业务A');
  equal(events.map(e => e.keyword), ['告警抽查邮件'], 'second observation emits the canonical keyword');
  empty(d, '告警抽查邮件：新业务A', 'continued presence is not a new mail');
});

test('single transient text does not trigger', () => {
  const d = fresh();
  empty(d, '收件箱', 'baseline');
  empty(d, '告警抽查邮件：短暂界面文字', 'first transient observation');
  empty(d, '收件箱', 'candidate disappeared');
  empty(d, '告警抽查邮件：短暂界面文字', 'returning candidate needs fresh confirmation');
  equal(scan(d, '告警抽查邮件：短暂界面文字').length, 1, 'fresh consecutive pair confirms');
});

test('empty page breaks pending stability', () => {
  const d = fresh();
  empty(d, '收件箱', 'baseline');
  empty(d, '客服电话检查：新业务', 'pending first observation');
  empty(d, '', 'blank render breaks continuity');
  empty(d, '客服电话检查：新业务', 'one observation after blank is insufficient');
  equal(scan(d, '客服电话检查：新业务').length, 1, 'next stable observation emits');
});

test('same number of rows with replacement content is a new event', () => {
  const d = fresh();
  empty(d, '告警抽查邮件：原有业务A', 'old row baseline');
  empty(d, '告警抽查邮件：替换业务B', 'new row first observation');
  equal(scan(d, '告警抽查邮件：替换业务B').length, 1, 'new content is detected even when total count stays one');
});

test('session dedupe survives disappearing and returning rows', () => {
  const d = fresh();
  empty(d, '收件箱', 'baseline');
  empty(d, '告警抽查邮件：业务A', 'first observation');
  equal(scan(d, '告警抽查邮件：业务A').length, 1, 'first delivery');
  empty(d, '收件箱', 'row disappears');
  empty(d, '告警抽查邮件：业务A', 'previously emitted row returns');
  empty(d, '告警抽查邮件：业务A', 'returning row remains deduplicated');
});

test('baseline rows stay suppressed after returning', () => {
  const d = fresh();
  empty(d, '客服电话检查：历史业务', 'history baseline');
  empty(d, '收件箱', 'history temporarily unmounted');
  empty(d, '客服电话检查：历史业务', 'history remounted');
  empty(d, '客服电话检查：历史业务', 'remount is not a new message');
});

test('row ordering and cosmetic whitespace do not create duplicate mail', () => {
  const d = fresh();
  empty(d, '告警抽查邮件：业务A\n客服电话检查：业务B', 'baseline');
  const rearranged = '  客服电话检查 : 业务B  \r\n 告 警 抽 查 邮 件 ： 业 务 A ';
  empty(d, rearranged, 'first reordered rendering');
  empty(d, rearranged, 'formatting changes are not new mail');
});

test('keyword aliases canonicalize without multiplying a row', () => {
  const d = fresh();
  empty(d, '收件箱', 'baseline');
  empty(d, '抽查邮件：业务A', 'alias first observation');
  equal(scan(d, '抽查邮件：业务A').map(e => e.keyword), ['告警抽查邮件'], 'alias uses canonical name');
  empty(d, '告警抽查邮件：抽查邮件业务B', 'two aliases on one new row');
  equal(scan(d, '告警抽查邮件：抽查邮件业务B').length, 1, 'same keyword is emitted only once per new row occurrence');
});

test('independent keyword types and rows have distinct ids', () => {
  const d = fresh();
  empty(d, '收件箱', 'baseline');
  const text = '告警抽查邮件：业务A\n告警抽查邮件：业务B\n客服电话检查：业务C';
  empty(d, text, 'new rows first observation');
  const events = scan(d, text);
  equal(events.map(e => e.keyword).sort(), ['告警抽查邮件', '告警抽查邮件', '客服电话检查'].sort(), 'all newly confirmed rows emit');
  equal(new Set(events.map(e => e.id)).size, 3, 'one id per event');
  empty(d, text, 'no repeated events');
});

test('same text with increased occurrence count yields only the added events', () => {
  const d = fresh();
  const row = '告警抽查邮件：相同主题';
  empty(d, row, 'one occurrence exists in baseline');
  empty(d, `${row}\n${row}\n${row}`, 'two added occurrences first seen');
  const events = scan(d, `${row}\n${row}\n${row}`);
  equal(events.length, 2, 'only added multiplicity is emitted');
  equal(new Set(events.map(e => e.id)).size, 2, 'identical rows still receive unique event ids');
  empty(d, row, 'count shrinks');
  empty(d, `${row}\n${row}\n${row}`, 'old multiplicity returns');
  empty(d, `${row}\n${row}\n${row}`, 'old multiplicity is not emitted again');
});

test('unstable multiplicity does not confirm the extra occurrence', () => {
  const d = fresh();
  const row = '客服电话检查：同一主题';
  empty(d, row, 'one occurrence baseline');
  empty(d, `${row}\n${row}`, 'extra occurrence briefly appears');
  empty(d, row, 'extra occurrence disappears');
  empty(d, `${row}\n${row}`, 'one fresh observation');
  equal(scan(d, `${row}\n${row}`).length, 1, 'second fresh observation confirms the extra row');
});

test('custom stableScans is honored', () => {
  const d = fresh({ stableScans: 3 });
  empty(d, '收件箱', 'baseline');
  empty(d, '告警抽查邮件：业务A', 'observation one');
  empty(d, '告警抽查邮件：业务A', 'observation two');
  equal(scan(d, '告警抽查邮件：业务A').length, 1, 'observation three emits');
});

test('small seen cache does not repeatedly alert on a static large page', () => {
  const d = fresh({ maxSeen: 2 });
  const text = Array.from({ length: 8 }, (_, i) => `告警抽查邮件：历史业务${i}`).join('\n');
  for (let i = 0; i < 8; i++) empty(d, text, 'active unchanged rows must not thrash the bounded seen cache');
  const updated = `${text}\n客服电话检查：新业务`;
  empty(d, updated, 'new row first observation after a large baseline');
  equal(scan(d, updated).map(e => e.keyword), ['客服电话检查'], 'only the actual new row emits');
  empty(d, updated, 'large page stays quiet after delivery');
});

test('self-generated notification lines cannot feed back into alerts', () => {
  for (const marker of ['监控提醒', '【夜间告警】', '推送测试', '验证码提醒', '网页告警提醒']) {
    const d = fresh();
    empty(d, '收件箱', 'baseline');
    const ownMessage = `${marker}：告警抽查邮件；客服电话检查；验证码001234`;
    empty(d, ownMessage, 'own notification first seen');
    empty(d, ownMessage, 'own notification remains excluded');
  }
});

test('ordinary night-alert business subject is not mistaken for an app notification', () => {
  const d = fresh();
  empty(d, '收件箱', 'baseline');
  empty(d, '夜间告警抽查邮件：真实业务A', 'nighttime business subject first seen');
  equal(scan(d, '夜间告警抽查邮件：真实业务A').map(e => e.keyword), ['告警抽查邮件'], 'unmarked business mail remains detectable');
});

test('ordinary verification code text is not an alert keyword', () => {
  const d = fresh();
  empty(d, '收件箱', 'baseline');
  empty(d, '验证码：001234，请在五分钟内完成登录。', 'verification mail without alert keyword');
  empty(d, '验证码：001234，请在五分钟内完成登录。', 'stable verification mail still does not emit an ordinary alert');
});

test('unmatched text and empty keyword configuration remain silent', () => {
  const d = fresh();
  empty(d, '收件箱', 'baseline');
  for (const text of ['普通业务邮件', '未读 12 封，时间 12:34', '账户验证码：123456', '会议安排']) empty(d, text, 'nonmatching text stays silent');
  const disabled = fresh({ keywords: [] });
  empty(disabled, '收件箱', 'empty keyword baseline');
  empty(disabled, '告警抽查邮件：业务A', 'no configured keywords');
  empty(disabled, '告警抽查邮件：业务A', 'no configured keywords after confirmation');
});

if (failures.length) {
  for (const failure of failures) process.stderr.write(`FAIL: ${failure}\n`);
  process.stderr.write(`${failures.length}/${cases} browser alert core cases failed; ${checks} assertions evaluated.\n`);
  process.exitCode = 1;
} else {
  process.stdout.write(`PASS: ${cases} browser alert core cases; ${checks} assertions; synthetic text only, no browser or network.\n`);
}
