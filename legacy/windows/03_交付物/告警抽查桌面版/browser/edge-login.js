'use strict';

// Standalone Edge session. Credentials arrive only on stdin; no traces, screenshots,
// console forwarding, page HTML dumps, or secret-bearing command-line arguments.
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const { setTimeout: delay } = require('node:timers/promises');

const TARGET_URL = 'https://portal.example.com:9978/admin.php?controller=admin_index&action=login';
const TARGET_ORIGIN = 'https://portal.example.com:9978';
const USER_PLACEHOLDER = /^\s*用户名\s*[:：]?\s*$/;
const PASSWORD_PLACEHOLDER = /^\s*口令\s*[:：]?\s*$/;
const LOGIN_NAME = /^\s*登\s*录\s*$/;

function allowedOrigin(value) {
  try {
    const uri = new URL(value);
    return uri.origin === TARGET_ORIGIN && !uri.username && !uri.password;
  } catch { return false; }
}

function loginPage(value) {
  if (!allowedOrigin(value)) return false;
  const uri = new URL(value);
  return uri.pathname === '/admin.php'
    && uri.searchParams.getAll('controller').length === 1
    && uri.searchParams.get('controller') === 'admin_index'
    && uri.searchParams.getAll('action').length === 1
    && uri.searchParams.get('action') === 'login';
}

function validateCredentials(value) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && value.targetUrl === TARGET_URL
    && typeof value.username === 'string' && value.username.trim().length > 0 && value.username.length <= 512
    && typeof value.password === 'string' && value.password.length > 0 && value.password.length <= 4096;
}

function projectArgument(args) {
  if (args.length !== 2 || args[0] !== '--project' || !path.isAbsolute(args[1])) return null;
  const root = path.resolve(args[1]);
  if (!fs.existsSync(path.join(root, 'Monitor-WindowKeywords.ps1'))) return null;
  return root;
}

function emit(state, message) {
  // Callers pass fixed text only. Never include exception.message, URLs, or DOM values.
  process.stdout.write(JSON.stringify({ state, message }) + '\n');
}

function readCredentials() {
  return new Promise((resolve, reject) => {
    const input = readline.createInterface({ input: process.stdin, terminal: false, crlfDelay: Infinity });
    let settled = false;
    const timeout = setTimeout(() => finish(null), 15000);
    function finish(line) {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      input.close();
      process.stdin.pause();
      try {
        if (typeof line !== 'string' || line.length > 32768) throw new Error();
        const value = JSON.parse(line);
        if (!validateCredentials(value)) throw new Error();
        resolve({ username: value.username, password: value.password, targetUrl: TARGET_URL });
      } catch { reject(new Error('Invalid login configuration')); }
    }
    input.once('line', finish);
    input.once('close', () => { if (!settled) finish(null); });
    input.once('error', () => finish(null));
  });
}

async function documentState(page) {
  // This evaluates page metadata only; it neither reads form values nor acts on security UI.
  return page.evaluate(() => {
    const error = document.querySelector('#error-code');
    const certificatePage = !!document.querySelector('#privacy-error, #bad-clock')
      || /ERR_CERT_|CERT_AUTHORITY|CERT_DATE|CERT_COMMON_NAME/i.test(error ? error.textContent : '')
      || (/^(chrome|edge)-error:/.test(location.href) && /privacy|certificate|证书|私密/i.test(document.title));
    return { url: location.href, certificatePage, topLevel: window.top === window };
  });
}

async function formHandles(page) {
  // Playwright's button role includes native <input type=submit value="登录">.
  const users = page.getByPlaceholder(USER_PLACEHOLDER).filter({ visible: true });
  const passwords = page.getByPlaceholder(PASSWORD_PLACEHOLDER).filter({ visible: true });
  const buttons = page.getByRole('button', { name: LOGIN_NAME }).filter({ visible: true });
  const counts = await Promise.all([users.count(), passwords.count(), buttons.count()]);
  if (counts.some(count => count !== 1)) return null;
  const values = await Promise.all([users.elementHandle(), passwords.elementHandle(), buttons.elementHandle()]);
  if (values.some(value => !value)) {
    await Promise.all(values.filter(Boolean).map(value => value.dispose().catch(() => {})));
    return null;
  }
  return { user: values[0], password: values[1], button: values[2] };
}

async function checkForm(page, handles) {
  return page.evaluate(({ user, password, button, targetOrigin }) => {
    function sameOrigin(value) {
      try {
        const uri = new URL(value, location.href);
        return uri.origin === targetOrigin && !uri.username && !uri.password;
      } catch { return false; }
    }
    function expectedPage() {
      if (window.top !== window || !sameOrigin(location.href)) return false;
      const uri = new URL(location.href);
      return uri.pathname === '/admin.php'
        && uri.searchParams.getAll('controller').length === 1 && uri.searchParams.get('controller') === 'admin_index'
        && uri.searchParams.getAll('action').length === 1 && uri.searchParams.get('action') === 'login';
    }
    function usable(el) {
      return el && el.isConnected && !el.disabled && !el.readOnly && el.getClientRects().length > 0
        && getComputedStyle(el).visibility !== 'hidden';
    }
    if (!expectedPage()) return 'origin';
    if (!usable(user) || !usable(password) || !usable(button) || user === password) return 'fields';
    if (user.tagName !== 'INPUT' || !['text', 'email', 'tel'].includes(user.type)
      || password.tagName !== 'INPUT' || !['password', 'text'].includes(password.type)) return 'fields';
    if (!/^\s*用户名\s*[:：]?\s*$/.test(user.getAttribute('placeholder') || '')
      || !/^\s*口令\s*[:：]?\s*$/.test(password.getAttribute('placeholder') || '')) return 'fields';
    if (/动态|otp|one.?time|token|verification|dynamic/i.test((password.name || '') + ' ' + (password.id || ''))) return 'fields';
    const form = button.form || button.closest('form');
    if ((user.form || null) !== form || (password.form || null) !== form) return 'action';
    if (form && !sameOrigin(form.action || location.href)) return 'action';
    const buttonAction = button.getAttribute('formaction');
    if (buttonAction && !sameOrigin(buttonAction)) return 'action';
    // A native GET submission would put the password into the address/history.
    if (form && button.type === 'submit' && String(button.getAttribute('formmethod') || form.method).toLowerCase() !== 'post') return 'action';
    const dynamic = Array.from(document.querySelectorAll('input')).filter(el => usable(el)
      && /动态密码|验证码|一次性密码|otp|one.?time/i.test((el.getAttribute('placeholder') || '') + ' ' + (el.name || '') + ' ' + (el.id || '')));
    if (dynamic.some(el => el.required && !el.value)) return 'dynamic';
    return 'ready';
  }, { ...handles, targetOrigin: TARGET_ORIGIN });
}

async function disposeHandles(handles) {
  if (handles) await Promise.all(Object.values(handles).map(value => value.dispose().catch(() => {})));
}

async function attemptLogin(page, credentials, reporter = emit) {
  // This function is called at most once per process; no retries after filling or clicking.
  let handles;
  let passwordFilled = false;
  let clicked = false;
  try {
    const state = await documentState(page);
    if (!state.topLevel || state.certificatePage || !loginPage(state.url)) {
      reporter('blocked_origin', '当前不是可验证的指定登录页，未自动填写。');
      return false;
    }
    handles = await formHandles(page);
    if (!handles) {
      reporter('form_not_found', '未能唯一识别用户名、口令和登录按钮，请在 Edge 页面手动登录。');
      return false;
    }
    let formState = await checkForm(page, handles);
    if (formState === 'dynamic') {
      reporter('manual_required', '系统要求动态密码，请在 Edge 页面填写后登录。');
      return false;
    }
    if (formState !== 'ready') {
      reporter('blocked_origin', '页面或提交地址无法验证，未自动填写，请在 Edge 页面检查。');
      return false;
    }
    await handles.user.fill(credentials.username, { timeout: 5000 });
    if (await checkForm(page, handles) !== 'ready') {
      reporter('manual_required', '登录表单发生变化，自动填写已停止。');
      return false;
    }
    await handles.password.fill(credentials.password, { timeout: 5000 });
    passwordFilled = true;
    formState = await checkForm(page, handles);
    if (formState !== 'ready') {
      reporter('manual_required', '登录表单发生变化，已停止提交，请在 Edge 页面检查。');
      return false;
    }
    // Check origin once more immediately before the only click in this script.
    if (!loginPage(page.url())) {
      reporter('manual_required', '页面地址已变化，已停止提交。');
      return false;
    }
    clicked = true;
    await handles.button.click({ timeout: 10000, noWaitAfter: true });
    reporter('submitted', '已自动填写并点击登录，请以 Edge 页面显示的结果为准。');
    return true;
  } catch {
    reporter('manual_required', clicked
      ? '已尝试点击登录，请查看 Edge 页面结果；程序不会重复提交。'
      : '自动登录未完成，请在 Edge 页面继续操作。');
    return false;
  } finally {
    // A changed form must not retain an automatically filled password for an unknown action.
    if (handles && passwordFilled && !clicked) {
      try { await handles.password.fill('', { timeout: 1000 }); } catch {}
    }
    await disposeHandles(handles);
  }
}

async function waitForLoginPage(page, wasCertificateError, isClosed, reporter = emit) {
  let deadline = Date.now() + (wasCertificateError ? 300000 : 15000);
  let notified = wasCertificateError;
  if (notified) reporter('manual_required', 'Edge 提示站点证书问题，请自行核实并处理；程序最多等待 5 分钟，不会操作安全提示。');
  while (!isClosed() && Date.now() < deadline) {
    try {
      const state = await documentState(page);
      if (state.certificatePage) {
        if (!notified) {
          deadline = Date.now() + 300000;
          reporter('manual_required', 'Edge 提示站点证书问题，请自行核实并处理；程序最多等待 5 分钟，不会操作安全提示。');
        }
        notified = true;
      } else if (state.topLevel && loginPage(state.url)) {
        const handles = await formHandles(page);
        if (handles) { await disposeHandles(handles); return true; }
      } else if (state.url !== 'about:blank' && !/^(chrome|edge)-error:/.test(state.url)) {
        const knownSystem = allowedOrigin(state.url);
        reporter(knownSystem ? 'already_signed_in' : 'blocked_origin', knownSystem
          ? '系统页面已打开，请查看是否已有登录会话；未重复提交登录。'
          : '页面转到其他地址，自动登录已停止，请在 Edge 中检查。');
        return false;
      }
    } catch { /* Navigation or user-closing races; no raw errors are exposed. */ }
    await delay(750);
  }
  if (!isClosed()) reporter(notified ? 'manual_required' : 'form_not_found', notified
    ? '等待证书问题处理已结束，请在 Edge 手动继续；程序不会自动重试。'
    : '登录表单未能完整加载，请在 Edge 页面手动继续。');
  return false;
}

async function main() {
  // Debug environment variables can make dependencies print fill arguments.
  delete process.env.DEBUG;
  delete process.env.PWDEBUG;
  const projectRoot = projectArgument(process.argv.slice(2));
  if (!projectRoot) { emit('failed', '程序目录无效，无法打开系统登录。'); return; }
  let credentials;
  try { credentials = await readCredentials(); }
  catch { emit('credentials_required', '本机加密登录配置无法读取，请重新配置账号。'); return; }
  const profile = path.join(projectRoot, '04_资料', '私密配置', 'Edge系统登录');
  let context;
  let closed = false;
  let closedPromise;
  try {
    fs.mkdirSync(profile, { recursive: true });
    // Keep Playwright's transient browser artifacts and the child browser's temp files
    // alongside this D-drive profile instead of the user's C-drive temp directory.
    const runtimeTemp = path.join(profile, 'runtime-temp');
    fs.mkdirSync(runtimeTemp, { recursive: true });
    process.env.TEMP = runtimeTemp;
    process.env.TMP = runtimeTemp;
    const { chromium } = require('playwright-core');
    emit('opening', '正在 Edge 中打开远程监控系统…');
    context = await chromium.launchPersistentContext(profile, {
      channel: 'msedge', headless: false, viewport: null, acceptDownloads: false, chromiumSandbox: true,
      args: ['--start-maximized'],
    });
    closedPromise = new Promise(resolve => context.once('close', () => {
      closed = true;
      emit('closed', '系统登录窗口已关闭。');
      resolve();
    }));
    const page = context.pages()[0] || await context.newPage();
    page.setDefaultTimeout(10000);
    let certificateError = false;
    try { await page.goto(TARGET_URL, { waitUntil: 'domcontentloaded', timeout: 30000 }); }
    catch (error) {
      // Classify the error in memory. Never forward its message or stack.
      certificateError = /ERR_CERT_|CERT_AUTHORITY|CERT_DATE|CERT_COMMON_NAME/i.test(String(error && error.message));
      if (!certificateError && !closed) emit('manual_required', '连接暂未完成，请查看 Edge 页面；程序正在检查登录页。');
    }
    if (!closed && await waitForLoginPage(page, certificateError, () => closed)) {
      await attemptLogin(page, credentials);
    }
  } catch {
    if (!closed) emit('failed', context
      ? '自动登录未完成，Edge 页面可继续手动操作。'
      : 'Edge 登录窗口无法启动；如窗口已打开，请先使用现有登录窗口。');
  } finally {
    if (credentials) { credentials.username = ''; credentials.password = ''; credentials = null; }
  }
  // Keep a headed, normal browser session available to the user after submission/failure.
  // Never close another Edge session or terminate the user's existing browser.
  if (context && !closed) await closedPromise;
}

module.exports = {
  TARGET_URL, allowedOrigin, loginPage, validateCredentials, projectArgument,
  documentState, formHandles, checkForm, attemptLogin, waitForLoginPage,
};

if (require.main === module) {
  main().catch(() => { emit('failed', '系统登录程序未完成，请重新打开登录窗口。'); process.exitCode = 1; });
}
