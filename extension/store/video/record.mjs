// Measures and records PasswordPie filling https://fernway.example in the Chrome that chrome.mjs started. See README.md.
//
//   node record.mjs measure <runs> <out.json>      Return → username and password in the form, <runs> times
//   node record.mjs take fill|quick|twostep|typing <out-dir>
//
// Environment: PPVIDEO (the compiled tools/ppvideo), PUPPETEER (puppeteer-core), CHROME_PID (the recording Chrome),
// APP_PID (PasswordPie), WINDOW (x,y,w,h of the Chrome window in screen points; default as in chrome.mjs),
// CDP_PORT (default 9431). Keys go in through the HID event tap, as from the keyboard.
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const puppeteer = (await import(process.env.PUPPETEER ?? 'puppeteer-core')).default;
const PPVIDEO = process.env.PPVIDEO;
const CHROME_PID = process.env.CHROME_PID;
const APP_PID = process.env.APP_PID;
const [WX, WY, WW, WH] = (process.env.WINDOW ?? '95,118,1280,720').split(',').map(Number);
const SITE = 'https://fernway.example';
// While this file exists, the coordinator is using the screen (a Chrome Web Store upload): wait.
const BUSY = '/tmp/pp-store/busy';
if (!PPVIDEO || !CHROME_PID || !APP_PID) throw new Error('PPVIDEO, CHROME_PID and APP_PID are required');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pp = (...args) => execFileSync(PPVIDEO, args, { encoding: 'utf8' }).trim();

// Runs in the page before its own scripts: notes when the form has a username and a password, and when all six code
// boxes have a digit. performance.timeOrigin + now() is on the same clock as the helper's Date (epoch ms).
const INSTRUMENT = () => {
  const now = () => performance.timeOrigin + performance.now();
  const st = (window.__pp = {});
  const check = () => {
    const user = document.querySelector('#email');
    const pass = document.querySelector('#password');
    if (user?.value && !st.user) st.user = now();
    if (user?.value && pass?.value && !st.filled) {
      st.filled = now();
      // The second animation frame starts after the frame with the values was drawn.
      requestAnimationFrame(() => requestAnimationFrame(() => { st.painted = now(); }));
    }
    const boxes = [...document.querySelectorAll('.boxes input')];
    if (boxes.length === 6 && boxes.every((b) => b.value) && !st.code) {
      st.code = now();
      requestAnimationFrame(() => requestAnimationFrame(() => { st.codePainted = now(); }));
    }
  };
  document.addEventListener('input', check, true);
  document.addEventListener('change', check, true);
};

async function waitNotBusy() {
  let said = false;
  while (existsSync(BUSY)) {
    if (!said) console.error('screen busy (coordinator), waiting…');
    said = true;
    await sleep(2000);
  }
}

async function connect() {
  const browser = await puppeteer.connect({ browserURL: `http://127.0.0.1:${process.env.CDP_PORT ?? '9431'}`, defaultViewport: null });
  const page = (await browser.pages()).find((p) => p.url().startsWith(SITE)) ?? (await browser.newPage());
  await page.evaluateOnNewDocument(INSTRUMENT);
  return { browser, page };
}

async function waitFor(page, expr, timeoutMs = 5000) {
  const handle = await page.waitForFunction(expr, { timeout: timeoutMs, polling: 5 });
  return handle.jsonValue();
}

/** Loads the sign-in page fresh (empty form) and puts the recording Chrome in front, its page focused. */
async function prepare(page, url = `${SITE}/login`) {
  await waitNotBusy();
  await page.goto(url, { waitUntil: 'load' });
  pp('activate', CHROME_PID);
  await sleep(300);
  // A click on the empty brand panel: the page has the focus and the extension says its profile is in front.
  pp('click', String(WX + 250), String(WY + 520));
  await sleep(700);
}

/** ⌘\, wait for the panel, then Return after `dwell` ms. Returns the times (epoch ms). */
async function fill(page, dwell) {
  const hotkey = Number(pp('key', 'hotkey'));
  const panel = Number(pp('panel', APP_PID, '3000').split(' ')[0]);
  await sleep(dwell);
  const ret = Number(pp('key', 'return'));
  const filled = await waitFor(page, () => window.__pp.filled);
  const painted = await waitFor(page, () => window.__pp.painted);
  const gone = Number(pp('gone', APP_PID, '3000'));
  return { hotkey, panel, ret, filled, painted, gone };
}

function startRecording(file) {
  const proc = spawn(PPVIDEO, ['record', file, '60', `${CHROME_PID},${APP_PID}`, `${WX},${WY},${WW},${WH}`], {
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  return new Promise((resolve, reject) => {
    proc.stdout.on('data', (d) => {
      const m = /recording ([\d.]+)/.exec(String(d));
      if (m) resolve({ proc, started: Number(m[1]) });
    });
    proc.on('exit', (code) => reject(new Error(`recorder exited ${code}`)));
  });
}

async function stopRecording({ proc }) {
  const done = new Promise((r) => proc.on('exit', r));
  proc.kill('SIGINT');
  await done;
}

const nearestRank = (sorted, q) => sorted[Math.min(sorted.length - 1, Math.ceil(q * sorted.length) - 1)];

function summary(values) {
  const s = [...values].sort((a, b) => a - b);
  return { n: s.length, min: s[0], median: s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2,
    p90: nearestRank(s, 0.9), max: s[s.length - 1] };
}

async function measure(runs, out) {
  const { browser, page } = await connect();
  const results = [];
  for (let i = 0; i < runs; i++) {
    await prepare(page);
    const t = await fill(page, 600);
    const run = { run: i + 1, ...t, fillMs: t.filled - t.ret, paintMs: t.painted - t.ret, panelMs: t.panel - t.hotkey };
    results.push(run);
    console.log(`#${run.run} Return→filled ${run.fillMs.toFixed(1)} ms, →next frame ${run.paintMs.toFixed(1)} ms (⌘\\→panel ${run.panelMs.toFixed(1)} ms)`);
    await sleep(500);
  }
  const report = {
    measured: new Date().toISOString(),
    machine: pp('machine'),
    chrome: (await browser.version()),
    fill: summary(results.map((r) => r.fillMs)),
    fillToNextFrame: summary(results.map((r) => r.paintMs)),
    panel: summary(results.map((r) => r.panelMs)),
    runs: results,
  };
  writeFileSync(out, JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ fill: report.fill, fillToNextFrame: report.fillToNextFrame, panel: report.panel }));
  browser.disconnect();
}

// Typing by hand, for the side-by-side: 40 words a minute on average (300 ms a character), with uneven gaps like a
// person's (tools/ppvideo type, a fixed pseudo-random sequence, so every take types the same way).
const TYPE_MS = 300;

async function screenPoint(page, selector) {
  return page.evaluate((sel) => {
    const r = document.querySelector(sel).getBoundingClientRect();
    return { x: screenX + r.x + r.width / 2, y: screenY + (outerHeight - innerHeight) + r.y + r.height / 2 };
  }, selector);
}

async function take(scenario, outDir) {
  mkdirSync(outDir, { recursive: true });
  const { browser, page } = await connect();
  await prepare(page);
  const file = path.join(outDir, `${scenario}.mov`);
  const rec = await startRecording(file);
  const events = { scenario, recordingStarted: rec.started };
  await sleep(1200);
  if (scenario === 'fill') {
    Object.assign(events, await fill(page, 1100));
    await sleep(2000);
  } else if (scenario === 'quick') {
    // For the side-by-side with typing: Return as soon as a person would, 300 ms after the panel shows.
    Object.assign(events, await fill(page, 300));
    await sleep(2000);
  } else if (scenario === 'twostep') {
    Object.assign(events, await fill(page, 900));
    await sleep(900);
    events.submit = Number(pp('key', 'return')); // Sign in: the caret is in the password field
    await page.waitForFunction(() => location.pathname === '/login/verify' && document.readyState === 'complete', { timeout: 5000 });
    events.codePage = Date.now();
    events.code = await waitFor(page, () => window.__pp.code, 10000);
    events.codePainted = await waitFor(page, () => window.__pp.codePainted);
    await sleep(1400);
    events.verify = Number(pp('key', 'return'));
    await page.waitForFunction(() => document.title.startsWith('Home'), { timeout: 5000 });
    events.home = Date.now();
    await sleep(1800);
  } else if (scenario === 'typing') {
    const password = process.env.DEMO_PASSWORD ?? 'vR7#kQ2m!Lp9wXz4Tb6e';
    const email = await screenPoint(page, '#email');
    events.click = Date.now();
    pp('click', String(Math.round(email.x)), String(Math.round(email.y)));
    await sleep(400);
    const [userStart] = pp('type', 'sam@rivera.example', String(TYPE_MS), '7').split(' ').map(Number);
    await sleep(TYPE_MS);
    events.tab = Number(pp('key', 'tab'));
    await sleep(TYPE_MS);
    const [, passEnd] = pp('type', password, String(TYPE_MS), '11').split(' ').map(Number);
    await page.waitForFunction((n) => document.querySelector('#password').value.length === n, { timeout: 3000 }, password.length);
    Object.assign(events, { typeStart: userStart, typeEnd: passEnd, typeMs: passEnd - userStart, keys: 'sam@rivera.example'.length + 1 + password.length });
    await sleep(1500);
  } else {
    throw new Error(`unknown scenario ${scenario}`);
  }
  await stopRecording(rec);
  writeFileSync(path.join(outDir, `${scenario}.json`), JSON.stringify(events, null, 2));
  console.log(JSON.stringify(events));
  browser.disconnect();
}

const [cmd, a, b] = process.argv.slice(2);
if (cmd === 'measure') await measure(Number(a), b);
else if (cmd === 'take') await take(a, b);
else throw new Error('usage: node record.mjs measure <runs> <out.json> | take fill|quick|twostep|typing <out-dir>');
