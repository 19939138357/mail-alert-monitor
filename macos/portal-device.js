function portalDevice(perform = false) {
  const origin = 'https://portal.example.com:9978';
  let clickStarted = false;
  function route(value, main, base) {
    if (typeof value !== 'string') return false;
    try {
      const u = new URL(value, base);
      if (u.origin !== origin || u.username || u.password || u.pathname !== '/admin.php'
        || u.searchParams.getAll('controller').length !== 1
        || u.searchParams.get('controller') !== 'admin_index') return false;
      const actions = u.searchParams.getAll('action');
      return main ? actions.length === 1 && actions[0] === 'main'
        : actions.length === 0 || (actions.length === 1 && actions[0] === 'main');
    } catch { return false; }
  }
  function viewOf(doc) {
    const view = doc && doc.defaultView;
    if (!view || view.document !== doc || typeof view.getComputedStyle !== 'function'
      || !view.Element || typeof view.Element.prototype.getAttribute !== 'function') return null;
    return view;
  }
  function attr(el, name) {
    const view = viewOf(el && el.ownerDocument);
    if (!view) throw new Error('Invalid document');
    return view.Element.prototype.getAttribute.call(el, name);
  }
  function visible(el, doc) {
    const view = viewOf(doc);
    if (!view || !el || el.ownerDocument !== doc || !el.isConnected || el.disabled
      || attr(el, 'aria-disabled') === 'true') return false;
    for (let node = el; node; node = node.parentElement) {
      if (node.ownerDocument !== doc) return false;
      const style = view.getComputedStyle(node);
      if (!style || style.display === 'none' || ['hidden', 'collapse'].includes(style.visibility)
        || style.opacity === '0' || style.pointerEvents === 'none') return false;
    }
    return Array.from(el.getClientRects()).some(r => r.width > 0 && r.height > 0
      && r.right > 0 && r.bottom > 0 && r.left < view.innerWidth && r.top < view.innerHeight);
  }
  function browserLink(value, doc) {
    if (typeof value !== 'string' || !value.trim()) return false;
    const u = new URL(value, doc.baseURI);
    if (u.origin !== origin || u.username || u.password || u.pathname !== '/admin.php' || u.hash) return false;
    // Before the normal portal hover handler expands its parameters, the same
    // browser icon has this exact four-parameter template. Do not synthesize
    // hover or accept a mixture of template and expanded entry parameters.
    if (u.searchParams.has('rdptype')) {
      const template = new Map([
        ['controller', 'admin_pro'], ['rdptype', 'web'], ['action', 'dev_login'], ['id', '8']
      ]);
      return Array.from(u.searchParams).length === template.size &&
        Array.from(template).every(([name, value]) =>
          u.searchParams.getAll(name).length === 1 && u.searchParams.get(name) === value);
    }
    const required = new Map([
      ['controller', 'admin_pro'], ['action', 'dev_login'], ['id', '8'],
      ['selectedip', ''], ['logintool', 'web']
    ]);
    const options = new Set(['screen', 'bydomain', 'rdpbpp', 'rdpclipauth', 'rdpdiskauth',
      'rdparg', 'appdeviceid', 'applocallogin', 'consoleauth']);
    let timestamps = 0;
    for (const [name, value] of u.searchParams) {
      if (u.searchParams.getAll(name).length !== 1) return false;
      if (required.has(name)) {
        if (value !== required.get(name)) return false;
      } else if (options.has(name)) {
        if (!/^\d+$/.test(value)) return false;
      } else if (/^\d+$/.test(name) && value === '') {
        if (++timestamps > 1) return false;
      } else return false;
    }
    return Array.from(required).every(([name, value]) =>
      u.searchParams.getAll(name).length === 1 && u.searchParams.get(name) === value);
  }
  function point(entry) {
    const childView = viewOf(entry.doc), topView = viewOf(document);
    function rect(el) {
      const view = viewOf(el.ownerDocument);
      const read = view && view.Element.prototype.getBoundingClientRect;
      if (typeof read !== 'function') throw new Error('Missing rectangle');
      const r = read.call(el);
      if (![r.left, r.top, r.width, r.height].every(Number.isFinite) || r.width <= 0 || r.height <= 0) throw new Error('Invalid rectangle');
      return {x: r.left, y: r.top, width: r.width, height: r.height};
    }
    if (!childView || !topView || typeof entry.doc.elementFromPoint !== 'function'
      || typeof document.elementFromPoint !== 'function') return 'BLOCKED';
    const image = rect(entry.image), localX = image.x + image.width / 2, localY = image.y + image.height / 2;
    if (image.x < 0 || image.y < 0 || image.x + image.width > childView.innerWidth
      || image.y + image.height > childView.innerHeight) return 'BLOCKED';
    const childHit = entry.doc.elementFromPoint(localX, localY);
    if (childHit !== entry.image && childHit !== entry.anchor && !entry.anchor.contains(childHit)) return 'BLOCKED';
    let target = image, frameRect = {x: 0, y: 0, width: topView.innerWidth, height: topView.innerHeight};
    if (entry.frame) {
      const frame = entry.frame;
      // A rotated/skewed frame cannot be safely mapped by axis-aligned bounds.
      for (let node = frame; node; node = node.parentElement) {
        const style = topView.getComputedStyle(node);
        if (!style || (style.transform && style.transform !== 'none')
          || (style.zoom && !['1', 'normal'].includes(style.zoom))) return 'BLOCKED';
      }
      frameRect = rect(frame);
      const dimensions = [frame.offsetWidth, frame.offsetHeight, frame.clientLeft, frame.clientTop,
        frame.clientWidth, frame.clientHeight, childView.innerWidth, childView.innerHeight];
      if (!dimensions.every(Number.isFinite) || frame.offsetWidth <= 0 || frame.offsetHeight <= 0
        || frame.clientLeft < 0 || frame.clientTop < 0 || childView.innerWidth <= 0 || childView.innerHeight <= 0
        || Math.abs(frame.clientWidth - childView.innerWidth) > 2
        || Math.abs(frame.clientHeight - childView.innerHeight) > 2) return 'BLOCKED';
      const scaleX = frameRect.width / frame.offsetWidth, scaleY = frameRect.height / frame.offsetHeight;
      if (Math.abs(scaleX - 1) > 0.01 || Math.abs(scaleY - 1) > 0.01) return 'BLOCKED';
      target = {x: frameRect.x + (frame.clientLeft + image.x) * scaleX,
        y: frameRect.y + (frame.clientTop + image.y) * scaleY,
        width: image.width * scaleX, height: image.height * scaleY};
    }
    const centerX = target.x + target.width / 2, centerY = target.y + target.height / 2;
    if (target.x < 0 || target.y < 0 || target.x + target.width > topView.innerWidth
      || target.y + target.height > topView.innerHeight) return 'BLOCKED';
    const topHit = document.elementFromPoint(centerX, centerY);
    if (entry.frame ? topHit !== entry.frame
      : topHit !== entry.image && topHit !== entry.anchor && !entry.anchor.contains(topHit)) return 'BLOCKED';
    const result = {x: target.x, y: target.y, width: target.width, height: target.height, centerX, centerY,
      viewportWidth: topView.innerWidth, viewportHeight: topView.innerHeight,
      frameX: frameRect.x, frameY: frameRect.y, frameWidth: frameRect.width, frameHeight: frameRect.height};
    if (!Object.values(result).every(Number.isFinite) || result.viewportWidth <= 0 || result.viewportHeight <= 0) return 'BLOCKED';
    return JSON.stringify(result);
  }
  function inspect() {
    if (window.top !== window || document.defaultView !== window || !viewOf(document)
      || !route(location.href, false) || !route(document.URL, false)) return {state: 'BLOCKED'};
    if (document.readyState === 'loading') return {state: 'WAIT'};
    let doc = document, frame = null;
    if (!route(location.href, true)) {
      const frames = Array.from(document.querySelectorAll('iframe')).filter(el => attr(el, 'name') === 'main');
      if (frames.length === 0) return {state: 'WAIT'};
      if (frames.length !== 1 || !visible(frames[0], document)) return {state: 'BLOCKED'};
      frame = frames[0];
      const src = attr(frame, 'src');
      if (!src || !route(src, true, document.baseURI)) return {state: 'BLOCKED'};
      // The declared src alone is insufficient after a cross-origin redirect.
      const frameView = frame.contentWindow;
      if (!frameView) return {state: 'WAIT'};
      const actual = frameView.location.href;
      if (actual === 'about:blank') return {state: 'WAIT'};
      if (!route(actual, true)) return {state: 'BLOCKED'};
      doc = frame.contentDocument;
      if (!doc) return {state: 'WAIT'};
      if (doc.defaultView !== frameView || !viewOf(doc) || !route(doc.URL, true)) return {state: 'BLOCKED'};
    }
    if (doc.readyState === 'loading') return {state: 'WAIT'};
    const matches = Array.from(doc.querySelectorAll('tr')).filter(row => {
      const cells = Array.from(row.cells || []);
      return cells.length === 9 && cells[0].innerText.trim() === '8' && cells[1].innerText.trim() === '监控机-1'
        && cells[2].innerText.trim() === '192.0.2.11'
        && cells[5].innerText.trim() === 'administrator' && cells[6].innerText.trim() === 'RDP';
    });
    if (matches.length !== 1) return {state: 'BLOCKED'};
    const row = matches[0], tools = row.cells[8];
    if (!visible(row, doc) || !visible(tools, doc)) return {state: 'BLOCKED'};
    const images = Array.from(tools.querySelectorAll('img'));
    if (!images.length) return {state: 'BLOCKED'};
    const image = images[0], raw = attr(image, 'src');
    const imageURL = new URL(raw || '', doc.baseURI);
    if (!raw || imageURL.origin !== origin || imageURL.username || imageURL.password
      || imageURL.pathname.split('/').pop() !== 'web.jpeg' || !visible(image, doc)) return {state: 'BLOCKED'};
    const anchor = image.parentElement, anchors = Array.from(tools.querySelectorAll('a'));
    if (!anchor || anchor.tagName !== 'A' || anchors[0] !== anchor
      || anchors.filter(a => a === anchor).length !== 1 || !tools.contains(anchor)
      || !visible(anchor, doc) || typeof anchor.onclick !== 'function'
      || anchor.querySelectorAll('img').length !== 1) return {state: 'BLOCKED'};
    // Validate the native attribute against the observed device-8 web entry.
    // Never navigate to a copied URL or evaluate href/onclick source; only the
    // current DOM anchor's existing handler may perform the normal action.
    if (!browserLink(attr(anchor, 'href'), doc)) return {state: 'BLOCKED'};
    return {state: 'READY', doc, frame, row, tools, image, anchor};
  }
  try {
    if (perform !== false && perform !== true && perform !== 'focus' && perform !== 'point') return 'BLOCKED';
    const first = inspect();
    if (first.state !== 'READY' || perform === false) return first.state;
    const fresh = inspect();
    if (fresh.state !== 'READY') return fresh.state;
    if (['doc', 'frame', 'row', 'tools', 'image', 'anchor'].some(key => first[key] !== fresh[key])) return 'BLOCKED';
    if (perform === 'point') return point(fresh);
    const view = viewOf(fresh.doc);
    if (!view || !view.HTMLElement) return 'BLOCKED';
    if (perform === 'focus') {
      if (typeof view.HTMLElement.prototype.focus !== 'function') return 'BLOCKED';
      view.HTMLElement.prototype.focus.call(fresh.anchor, {preventScroll: true});
      return fresh.doc.activeElement === fresh.anchor ? 'FOCUSED' : 'BLOCKED';
    }
    if (typeof view.HTMLElement.prototype.click !== 'function') return 'BLOCKED';
    clickStarted = true;
    view.HTMLElement.prototype.click.call(fresh.anchor);
    return 'ENTERED';
  } catch {
    return clickStarted ? 'UNCERTAIN' : 'BLOCKED';
  }
}
