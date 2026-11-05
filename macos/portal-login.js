function portalLogin(credentials) {
  const origin = 'https://portal.example.com:9978';
  function sameOrigin(value) {
    try { const u = new URL(value, location.href); return u.origin === origin && !u.username && !u.password; }
    catch { return false; }
  }
  function route(login) {
    if (window.top !== window || !sameOrigin(location.href)) return false;
    const u = new URL(location.href);
    return u.pathname === '/admin.php' && u.searchParams.getAll('controller').length === 1
      && u.searchParams.get('controller') === 'admin_index'
      && (!login || (u.searchParams.getAll('action').length === 1 && u.searchParams.get('action') === 'login'));
  }
  if (!route(false)) return 'BLOCKED';
  if (document.readyState === 'loading') return 'WAIT';
  if (!route(true)) {
    const text = document.body ? document.body.innerText : '';
    return /监控设备/.test(text) && (/退出|注销/.test(text) || /普通用户/.test(text)) ? 'SIGNED_IN' : 'BLOCKED';
  }
  function usable(el) {
    return el && el.isConnected && !el.disabled && !el.readOnly && el.getClientRects().length > 0
      && getComputedStyle(el).visibility !== 'hidden';
  }
  const inputs = Array.from(document.querySelectorAll('input')).filter(usable);
  const users = inputs.filter(e => /^\s*用户名\s*[:：]?\s*$/.test(e.getAttribute('placeholder') || ''));
  const secrets = inputs.filter(e => /^\s*口令\s*[:：]?\s*$/.test(e.getAttribute('placeholder') || ''));
  const buttons = Array.from(document.querySelectorAll('button,input[type=submit],input[type=button],[role=button]'))
    .filter(e => usable(e) && /^\s*登\s*录\s*$/.test(e.innerText || e.value || ''));
  if (users.length !== 1 || secrets.length !== 1 || buttons.length !== 1) return 'BLOCKED';
  const user = users[0], password = secrets[0], button = buttons[0];
  function safe() {
    if (!route(true) || !usable(user) || !usable(password) || !usable(button)) return false;
    if (!['text','email','tel'].includes(user.type) || password.type !== 'password') return false;
    if (/动态|otp|one.?time|token|verification|dynamic/i.test((password.name || '')+' '+(password.id || ''))) return false;
    const form = button.form || button.closest('form');
    if ((user.form || null) !== form || (password.form || null) !== form) return false;
    if (form && !sameOrigin(form.action || location.href)) return false;
    const action = button.getAttribute('formaction');
    if (action && !sameOrigin(action)) return false;
    if (form && button.type === 'submit' && String(button.getAttribute('formmethod') || form.method).toLowerCase() !== 'post') return false;
    return true;
  }
  if (!safe()) return 'BLOCKED';
  if (inputs.some(e => e.required && !e.value && /动态密码|验证码|一次性密码|otp|one.?time/i.test(
    (e.getAttribute('placeholder') || '')+' '+(e.name || '')+' '+(e.id || '')))) return 'MANUAL';
  if (Array.from(document.querySelectorAll('iframe[src*=captcha],img[src*=captcha],canvas[id*=captcha]')).some(usable)) return 'MANUAL';
  if (!credentials) return 'READY';
  if (typeof credentials.username !== 'string' || typeof credentials.password !== 'string'
    || !credentials.username.trim() || credentials.username.length > 512 || !credentials.password || credentials.password.length > 4096) return 'BLOCKED';
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  function put(el, value) { setter.call(el, value); el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); }
  try {
    put(user, credentials.username);
    if (!safe()) return 'BLOCKED';
    put(password, credentials.password);
    if (!safe() || user.value !== credentials.username || password.value !== credentials.password) {
      setter.call(password, ''); return 'BLOCKED';
    }
    button.click();
    return 'SUBMITTED';
  } catch {
    try { setter.call(password, ''); } catch {}
    return 'UNCERTAIN';
  }
}
