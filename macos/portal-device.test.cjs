// Synthetic DOM only: no browser, network, credentials or real portal actions.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, 'portal-device.js'), 'utf8');
const origin = 'https://portal.example.com:9978';
const shellURL = origin + '/admin.php?controller=admin_index&ref=';
const mainURL = origin + '/admin.php?controller=admin_index&action=main';
const templateHref = 'admin.php?controller=admin_pro&rdptype=web&action=dev_login&id=8';
const browserHref = 'admin.php?controller=admin_pro&action=dev_login&id=8&selectedip=&screen=3&bydomain=0&rdpbpp=16&rdpclipauth=0&rdpdiskauth=0&rdparg=0&appdeviceid=0&applocallogin=0&logintool=web&consoleauth=0&1792430384';
let checks = 0;

function fixture(direct = false) {
  let clicks = 0, otherClicks = 0, focuses = 0, focusOptions;
  class Element {
    constructor(tagName, doc, attrs = {}) {
      this.tagName = tagName; this.ownerDocument = doc; this.attrs = attrs;
      this.isConnected = true; this.parentElement = null; this.nodes = [];
      this.style = {display: 'block', visibility: 'visible', opacity: '1', pointerEvents: 'auto'};
      this.rects = [{left: 10, top: 10, right: 110, bottom: 40, width: 100, height: 30}];
    }
    getAttribute(name) { return Object.hasOwn(this.attrs, name) ? this.attrs[name] : null; }
    getClientRects() { return this.rects; }
    getBoundingClientRect() { return this.rects[0] || {left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0}; }
    querySelectorAll(selector) { return this.nodes.filter(el => el.tagName.toLowerCase() === selector); }
    contains(el) { return this.nodes.includes(el); }
    click() { if (this.onclick) this.onclick(); }
    focus(options) { this.ownerDocument.activeElement = this; if (this.onFocus) this.onFocus(options); }
  }
  function makeDocument(url) {
    const location = {href: url};
    const doc = {readyState: 'complete', frames: [], rows: [],
      get URL() { return location.href; }, get baseURI() { return location.href; },
      querySelectorAll(selector) { return selector === 'iframe' ? this.frames : selector === 'tr' ? this.rows : []; },
      elementFromPoint(x, y) { return this.hitTest ? this.hitTest(x, y) : this.hit; }};
    const view = {document: doc, location, Element, HTMLElement: Element, innerWidth: 1200, innerHeight: 800,
      getComputedStyle(el) { assert.equal(el.ownerDocument, doc, 'style uses the owning document view'); return el.style; }};
    doc.defaultView = view;
    return {doc, view, location};
  }
  const top = makeDocument(direct ? mainURL : shellURL), main = direct ? top : makeDocument(mainURL);
  top.view.top = top.view;
  const frame = new Element('IFRAME', top.doc, {name: 'main', src: mainURL});
  frame.contentWindow = main.view; frame.contentDocument = main.doc;
  frame.rects = [{left: 20, top: 50, right: 1124, bottom: 654, width: 1104, height: 604}];
  Object.assign(frame, {offsetWidth: 1104, offsetHeight: 604, clientLeft: 2, clientTop: 2, clientWidth: 1100, clientHeight: 600});
  if (!direct) { main.view.innerWidth = 1100; main.view.innerHeight = 600; }
  if (!direct) top.doc.frames = [frame];
  const row = new Element('TR', main.doc);
  row.cells = Array.from({length: 9}, () => new Element('TD', main.doc));
  row.cells.forEach(cell => { cell.innerText = ''; cell.parentElement = row; });
  row.cells[0].innerText = '8'; row.cells[1].innerText = '监控机-1'; row.cells[2].innerText = '192.0.2.11';
  row.cells[5].innerText = 'administrator'; row.cells[6].innerText = 'RDP';
  const tools = row.cells[8], anchor = new Element('A', main.doc, {href: browserHref});
  const image = new Element('IMG', main.doc, {src: '/images/web.jpeg'});
  const other = new Element('A', main.doc, {href: '#'});
  const otherImage = new Element('IMG', main.doc, {src: '/images/mstsc_ico.gif'});
  anchor.parentElement = tools; image.parentElement = anchor; anchor.nodes = [image];
  other.parentElement = tools; otherImage.parentElement = other; other.nodes = [otherImage];
  anchor.onclick = () => { clicks++; }; other.onclick = () => { otherClicks++; };
  anchor.onFocus = options => { focuses++; focusOptions = options; };
  tools.nodes = [anchor, image, other, otherImage]; main.doc.rows = [row];
  main.doc.hit = image;
  if (!direct) top.doc.hit = frame;
  const context = vm.createContext({URL, window: top.view, document: top.doc, location: top.location});
  vm.runInContext(source, context);
  return {top, main, frame, row, tools, anchor, image, other, otherImage, Element,
    run: (perform = false) => context.portalDevice(perform), clicks: () => clicks, otherClicks: () => otherClicks,
    focuses: () => focuses, focusOptions: () => focusOptions};
}
function check(name, setup, expected, perform = false, direct = false) {
  const f = fixture(direct); setup(f);
  assert.equal(f.run(perform), expected, name);
  assert.equal(f.clicks(), expected === 'ENTERED' ? 1 : 0, name + ': browser click count');
  assert.equal(f.otherClicks(), 0, name + ': second icon is never clicked');
  assert.equal(f.focuses(), expected === 'FOCUSED' ? 1 : 0, name + ': native focus count');
  checks++;
}
function linkParam(f, name, value, append = false) {
  const u = new URL(f.anchor.attrs.href, f.main.doc.baseURI);
  if (value === null) u.searchParams.delete(name);
  else if (append) u.searchParams.append(name, value);
  else u.searchParams.set(name, value);
  f.anchor.attrs.href = u.href;
}

check('wrapper probe is read only', () => {}, 'READY');
check('wrapper browser entry clicks once', () => {}, 'ENTERED', true);
check('direct main document is supported', () => {}, 'READY', false, true);
check('direct main document clicks only its browser icon', () => {}, 'ENTERED', true, true);
check('surrounding cell whitespace is harmless', f => f.row.cells[1].innerText = ' 监控机-1\n', 'READY');
check('relative same-origin main frame source', f => f.frame.attrs.src = '/admin.php?controller=admin_index&action=main', 'READY');
check('empty href is not the verified device entry', f => f.anchor.attrs.href = '', 'BLOCKED', true);
check('fragment href is not the verified device entry', f => f.anchor.attrs.href = '#', 'BLOCKED', true);
check('missing href is rejected', f => delete f.anchor.attrs.href, 'BLOCKED', true);
check('native attribute ignores a shadow href property', f => f.anchor.href = 'https://evil.invalid/', 'READY');
check('void href is not the verified device entry', f => f.anchor.attrs.href = 'javascript:void(0);', 'BLOCKED', true);
check('absolute verified entry is allowed', f => f.anchor.attrs.href = new URL(browserHref, f.main.doc.baseURI).href, 'ENTERED', true);
check('unhovered web template probe is read only', f => f.anchor.attrs.href = templateHref, 'READY');
check('unhovered web template can be focused without clicking', f => f.anchor.attrs.href = templateHref, 'FOCUSED', 'focus');
check('unhovered web template still supports the existing click mode', f => f.anchor.attrs.href = templateHref, 'ENTERED', true);
check('unhovered ActiveX template cannot be used', f => f.anchor.attrs.href = templateHref.replace('rdptype=web', 'rdptype=activex'), 'BLOCKED', 'focus');
for (const name of ['controller', 'rdptype', 'action', 'id']) {
  check('template requires ' + name, f => { f.anchor.attrs.href = templateHref; linkParam(f, name, null); }, 'BLOCKED', 'focus');
  check('template rejects duplicate ' + name, f => { f.anchor.attrs.href = templateHref; linkParam(f, name, '', true); }, 'BLOCKED', 'focus');
}
check('template cannot mix an expanded selected IP parameter', f => f.anchor.attrs.href = templateHref + '&selectedip=', 'BLOCKED', 'focus');
check('template cannot mix an expanded web-tool parameter', f => f.anchor.attrs.href = templateHref + '&logintool=web', 'BLOCKED', 'focus');
check('template cannot mix an expanded display parameter', f => f.anchor.attrs.href = templateHref + '&screen=3', 'BLOCKED', 'focus');
check('template cannot add an expanded timestamp', f => f.anchor.attrs.href = templateHref + '&1792430384', 'BLOCKED');
check('template rejects unknown options', f => f.anchor.attrs.href = templateHref + '&other=0', 'BLOCKED', 'focus');
check('template cannot change device id', f => f.anchor.attrs.href = templateHref.replace('id=8', 'id=9'), 'BLOCKED', 'focus');
check('expanded entry cannot mix a template type', f => linkParam(f, 'rdptype', 'web'), 'BLOCKED', 'focus');
check('verified entry does not require an incidental timestamp', f => linkParam(f, '1792430384', null), 'READY');
check('another single empty numeric timestamp is allowed', f => { linkParam(f, '1792430384', null); linkParam(f, '1792430399', ''); }, 'READY');
check('wrong entry host', f => f.anchor.attrs.href = new URL(browserHref, 'https://evil.invalid/').href, 'BLOCKED', true);
check('wrong entry scheme', f => f.anchor.attrs.href = new URL(browserHref, f.main.doc.baseURI).href.replace('https:', 'http:'), 'BLOCKED', true);
check('wrong entry port', f => f.anchor.attrs.href = new URL(browserHref, f.main.doc.baseURI).href.replace('9978', '9980'), 'BLOCKED', true);
check('entry username is forbidden', f => f.anchor.attrs.href = new URL(browserHref, f.main.doc.baseURI).href.replace('https://', 'https://user@'), 'BLOCKED', true);
check('entry username and password are forbidden', f => f.anchor.attrs.href = new URL(browserHref, f.main.doc.baseURI).href.replace('https://', 'https://user:secret@'), 'BLOCKED', true);
check('wrong entry controller', f => linkParam(f, 'controller', 'admin_index'), 'BLOCKED', true);
check('wrong entry action', f => linkParam(f, 'action', 'other'), 'BLOCKED', true);
check('wrong entry device id', f => linkParam(f, 'id', '9'), 'BLOCKED', true);
check('entry device id is required', f => linkParam(f, 'id', null), 'BLOCKED', true);
check('row device id is required', f => f.row.cells[0].innerText = '9', 'BLOCKED', true);
check('non-web entry is rejected', f => linkParam(f, 'logintool', 'mstsc'), 'BLOCKED', true);
check('selected IP cannot override the verified row', f => linkParam(f, 'selectedip', '192.0.2.12'), 'BLOCKED', true);
check('selected IP parameter must be explicitly empty', f => linkParam(f, 'selectedip', null), 'BLOCKED', true);
for (const name of ['controller', 'action', 'id', 'logintool', 'selectedip', 'screen']) {
  check('duplicate entry parameter ' + name, f => linkParam(f, name, '', true), 'BLOCKED', true);
}
check('unknown entry option is rejected', f => linkParam(f, 'redirect', '/other.php'), 'BLOCKED', true);
check('known display options must remain numeric', f => linkParam(f, 'screen', 'other'), 'BLOCKED', true);
check('two timestamp parameters are ambiguous', f => linkParam(f, '1792430399', ''), 'BLOCKED', true);
check('timestamp parameter cannot carry a value', f => linkParam(f, '1792430384', 'other'), 'BLOCKED', true);
check('duplicate timestamp is rejected', f => linkParam(f, '1792430384', '', true), 'BLOCKED', true);
check('entry URL fragment is not allowed', f => f.anchor.attrs.href += '#other', 'BLOCKED', true);
check('wrong top origin', f => f.top.location.href = shellURL.replace('portal.example.com', 'evil.invalid'), 'BLOCKED', true);
check('HTTP top page', f => f.top.location.href = shellURL.replace('https:', 'http:'), 'BLOCKED');
check('wrong top port', f => f.top.location.href = shellURL.replace('9978', '9980'), 'BLOCKED');
check('top URL credentials', f => f.top.location.href = shellURL.replace('https://', 'https://user@'), 'BLOCKED');
check('wrong top path', f => f.top.location.href = shellURL.replace('/admin.php', '/admin.php-other'), 'BLOCKED');
check('login page is never a device entry', f => f.top.location.href = shellURL + '&action=login', 'BLOCKED', true);
check('unknown top action is rejected', f => f.top.location.href = shellURL + '&action=other', 'BLOCKED');
check('duplicate top controller', f => f.top.location.href = shellURL + '&controller=admin_index', 'BLOCKED');
check('duplicate top action', f => f.top.location.href = mainURL + '&action=main', 'BLOCKED');
check('execution inside a subframe is rejected', f => f.top.view.top = {}, 'BLOCKED');
check('top document defaultView identity is required', f => f.top.doc.defaultView = f.main.view, 'BLOCKED');
check('top loading does not click', f => f.top.doc.readyState = 'loading', 'WAIT', true);
check('missing main frame waits without guessing', f => f.top.doc.frames = [], 'WAIT', true);
check('duplicate main frames are ambiguous', f => f.top.doc.frames.push(f.frame), 'BLOCKED', true);
check('hidden main frame is rejected', f => f.frame.style.display = 'none', 'BLOCKED', true);
check('disconnected main frame is rejected', f => f.frame.isConnected = false, 'BLOCKED');
check('cross-origin declared frame is rejected', f => f.frame.attrs.src = mainURL.replace('portal.example.com', 'evil.invalid'), 'BLOCKED', true);
check('wrong frame route is rejected', f => f.frame.attrs.src = mainURL.replace('action=main', 'action=login'), 'BLOCKED');
check('duplicate frame query is rejected', f => f.frame.attrs.src = mainURL + '&action=main', 'BLOCKED');
check('frame source cannot use embedded credentials', f => f.frame.attrs.src = mainURL.replace('https://', 'https://user@'), 'BLOCKED');
check('loading blank frame waits', f => f.main.location.href = 'about:blank', 'WAIT', true);
check('redirected frame is rejected', f => f.main.location.href = 'https://evil.invalid/', 'BLOCKED', true);
check('inaccessible cross-origin frame is rejected', f => Object.defineProperty(f.frame, 'contentWindow', {get() { throw new Error('SecurityError'); }}), 'BLOCKED', true);
check('main document view identity is required', f => f.main.doc.defaultView = f.top.view, 'BLOCKED');
check('main document requires its own style API', f => f.main.view.getComputedStyle = null, 'BLOCKED');
check('main document loading waits', f => f.main.doc.readyState = 'loading', 'WAIT', true);
check('wrong device name', f => f.row.cells[1].innerText = '监控机-2', 'BLOCKED', true);
check('wrong device IP', f => f.row.cells[2].innerText = '192.0.2.12', 'BLOCKED', true);
check('wrong device account', f => f.row.cells[5].innerText = 'other', 'BLOCKED', true);
check('wrong protocol', f => f.row.cells[6].innerText = 'SSH', 'BLOCKED', true);
check('row must contain exactly nine cells', f => f.row.cells.push(f.tools), 'BLOCKED');
check('duplicate matching device rows', f => f.main.doc.rows.push(f.row), 'BLOCKED', true);
check('nonmatching extra rows are harmless', f => f.main.doc.rows.push({cells: []}), 'READY');
check('invisible target row', f => f.row.rects = [], 'BLOCKED');
check('hidden tools cell', f => f.tools.style.visibility = 'hidden', 'BLOCKED');
check('transparent ancestor is rejected', f => f.tools.style.opacity = '0', 'BLOCKED');
check('first icon must be web.jpeg', f => f.image.attrs.src = '/images/mstsc_ico.gif', 'BLOCKED', true);
check('matching icon filename cannot be a suffix', f => f.image.attrs.src = '/images/other-web.jpeg', 'BLOCKED');
check('browser icon must have the exact case', f => f.image.attrs.src = '/images/WEB.JPEG', 'BLOCKED');
check('browser icon requires the original origin', f => f.image.attrs.src = 'https://evil.invalid/web.jpeg', 'BLOCKED', true);
check('browser icon cannot contain URL credentials', f => f.image.attrs.src = origin.replace('https://', 'https://user@') + '/web.jpeg', 'BLOCKED');
check('browser image cannot be missing', f => f.tools.nodes = [f.anchor, f.other], 'BLOCKED');
check('icon must be visible', f => f.image.style.display = 'none', 'BLOCKED');
check('offscreen icon is rejected', f => f.image.rects = [{left: 1500, right: 1600, top: 10, bottom: 40, width: 100, height: 30}], 'BLOCKED');
check('first image must belong to an anchor', f => f.anchor.tagName = 'SPAN', 'BLOCKED');
check('first image anchor must also be the first tools anchor', f => f.tools.nodes = [f.other, f.anchor, f.image, f.otherImage], 'BLOCKED', true);
check('browser anchor must have one icon', f => f.anchor.nodes.push(f.otherImage), 'BLOCKED');
check('browser anchor requires its existing handler', f => f.anchor.onclick = null, 'BLOCKED', true);
check('disabled browser anchor', f => f.anchor.attrs['aria-disabled'] = 'true', 'BLOCKED');
check('unsafe javascript href is not executed', f => f.anchor.attrs.href = 'javascript:alert(1)', 'BLOCKED', true);
check('foreign href is rejected', f => f.anchor.attrs.href = 'https://evil.invalid/', 'BLOCKED', true);
check('unverified navigation href is rejected', f => f.anchor.attrs.href = '/other.php', 'BLOCKED');
check('truthy strings cannot authorize a click', () => {}, 'BLOCKED', 'true');

const mutation = fixture();
let styleReads = 0;
const originalStyle = mutation.main.view.getComputedStyle;
mutation.main.view.getComputedStyle = function(el) {
  if (el === mutation.row && ++styleReads === 2) mutation.row.cells[2].innerText = '192.0.2.12';
  return originalStyle(el);
};
assert.equal(mutation.run(true), 'BLOCKED', 'second validation rejects a changed device identity');
assert.equal(mutation.clicks(), 0); assert.equal(mutation.otherClicks(), 0); checks++;

const uncertain = fixture();
uncertain.anchor.onclick = () => { throw new Error('Synthetic handler result unknown'); };
assert.equal(uncertain.run(true), 'UNCERTAIN', 'an attempted handler failure is never reported as unclicked');
assert.equal(uncertain.otherClicks(), 0); checks++;

const focused = fixture();
assert.equal(focused.run('focus'), 'FOCUSED', 'verified iframe browser anchor can receive focus');
assert.equal(focused.main.doc.activeElement, focused.anchor);
assert.equal(focused.focuses(), 1); assert.equal(focused.focusOptions().preventScroll, true);
assert.equal(focused.clicks(), 0); assert.equal(focused.otherClicks(), 0); checks++;

const directFocus = fixture(true);
assert.equal(directFocus.run('focus'), 'FOCUSED', 'verified direct main anchor can receive focus');
assert.equal(directFocus.focuses(), 1); assert.equal(directFocus.clicks(), 0); checks++;

const unconfirmedFocus = fixture();
unconfirmedFocus.anchor.onFocus = () => { unconfirmedFocus.main.doc.activeElement = unconfirmedFocus.other; };
assert.equal(unconfirmedFocus.run('focus'), 'BLOCKED', 'focus must remain on the verified browser anchor');
assert.equal(unconfirmedFocus.clicks(), 0); assert.equal(unconfirmedFocus.otherClicks(), 0); checks++;

const failedFocus = fixture();
failedFocus.anchor.onFocus = () => { throw new Error('Synthetic focus failure'); };
assert.equal(failedFocus.run('focus'), 'BLOCKED', 'focus failure cannot authorize keyboard activation');
assert.equal(failedFocus.clicks(), 0); checks++;

check('wrong device cannot be focused', f => f.row.cells[0].innerText = '9', 'BLOCKED', 'focus');
check('detached browser anchor cannot be focused', f => f.anchor.isConnected = false, 'BLOCKED', 'focus');
check('hidden browser anchor cannot be focused', f => f.anchor.style.display = 'none', 'BLOCKED', 'focus');
check('missing native focus method cannot authorize keyboard activation', f => f.Element.prototype.focus = null, 'BLOCKED', 'focus');

const changedFocus = fixture();
let focusStyleReads = 0;
const focusStyle = changedFocus.main.view.getComputedStyle;
changedFocus.main.view.getComputedStyle = function(el) {
  if (el === changedFocus.row && ++focusStyleReads === 2) changedFocus.row.cells[0].innerText = '9';
  return focusStyle(el);
};
assert.equal(changedFocus.run('focus'), 'BLOCKED', 'changed device identity is rejected before focus');
assert.equal(changedFocus.focuses(), 0); assert.equal(changedFocus.clicks(), 0); checks++;

const geometry = fixture();
const geometryResult = JSON.parse(geometry.run('point'));
assert.deepEqual(geometryResult, {x: 32, y: 62, width: 100, height: 30, centerX: 82, centerY: 77,
  viewportWidth: 1200, viewportHeight: 800, frameX: 20, frameY: 50, frameWidth: 1104, frameHeight: 604},
  'iframe point includes the frame position and border in top CSS coordinates');
assert(Object.values(geometryResult).every(value => typeof value === 'number' && Number.isFinite(value)));
assert.equal(geometry.clicks(), 0); assert.equal(geometry.otherClicks(), 0); assert.equal(geometry.focuses(), 0); checks++;

const directGeometry = fixture(true);
const directResult = JSON.parse(directGeometry.run('point'));
assert.deepEqual(directResult, {x: 10, y: 10, width: 100, height: 30, centerX: 60, centerY: 25,
  viewportWidth: 1200, viewportHeight: 800, frameX: 0, frameY: 0, frameWidth: 1200, frameHeight: 800});
assert.equal(directGeometry.clicks(), 0); assert.equal(directGeometry.focuses(), 0); checks++;

const hitCoordinates = fixture();
hitCoordinates.main.doc.hitTest = (x, y) => { assert.equal(x, 60); assert.equal(y, 25); return hitCoordinates.image; };
hitCoordinates.top.doc.hitTest = (x, y) => { assert.equal(x, 82); assert.equal(y, 77); return hitCoordinates.frame; };
assert.equal(typeof JSON.parse(hitCoordinates.run('point')).centerX, 'number'); checks++;

const templatePoint = fixture(); templatePoint.anchor.attrs.href = templateHref;
assert.equal(JSON.parse(templatePoint.run('point')).centerX, 82);
assert.equal(templatePoint.clicks(), 0); assert.equal(templatePoint.focuses(), 0); checks++;

check('point rejects a child document overlay', f => f.main.doc.hit = f.other, 'BLOCKED', 'point');
check('point rejects a top document overlay', f => f.top.doc.hit = f.other, 'BLOCKED', 'point');
check('point rejects a hidden iframe', f => f.frame.style.display = 'none', 'BLOCKED', 'point');
check('point rejects a detached iframe', f => f.frame.isConnected = false, 'BLOCKED', 'point');
check('point rejects a transformed iframe', f => f.frame.style.transform = 'matrix(1,0,0,1,1,0)', 'BLOCKED', 'point');
check('point rejects a CSS-zoomed iframe', f => f.frame.style.zoom = '2', 'BLOCKED', 'point');
check('point rejects an unavailable frame dimension', f => f.frame.offsetWidth = 0, 'BLOCKED', 'point');
check('point rejects a mismatched child viewport', f => f.frame.clientWidth = 800, 'BLOCKED', 'point');
check('point rejects nonfinite viewport dimensions', f => f.top.view.innerWidth = Infinity, 'BLOCKED', 'point');
check('point rejects missing child hit testing', f => f.main.doc.elementFromPoint = null, 'BLOCKED', 'point');
check('point rejects missing top hit testing', f => f.top.doc.elementFromPoint = null, 'BLOCKED', 'point');
check('point rejects unknown device identity', f => f.row.cells[0].innerText = '9', 'BLOCKED', 'point');
check('point rejects unauthorized frame navigation', f => f.main.location.href = 'https://evil.invalid/', 'BLOCKED', 'point');
check('point never returns a partially clipped image', f => f.image.rects = [{left: -5, top: 10, right: 95, bottom: 40, width: 100, height: 30}], 'BLOCKED', 'point');

const clippedTop = fixture();
clippedTop.frame.rects = [{left: 1150, top: 50, right: 2254, bottom: 654, width: 1104, height: 604}];
assert.equal(clippedTop.run('point'), 'BLOCKED', 'point rejects an image clipped by the top viewport');
assert.equal(clippedTop.clicks(), 0); assert.equal(clippedTop.focuses(), 0); checks++;
console.log(`PASS ${checks} isolated portal device checks; no UI, network or real credentials.`);
