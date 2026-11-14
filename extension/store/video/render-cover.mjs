// The cover of the promo video, from cover/cover.html:
//   node render-cover.mjs                       cover.jpg (1280x720, the YouTube thumbnail) and
//                                               composition/cover-1080p.png (the same page at 1.5x: the video's first frame)
//   node render-cover.mjs board OUT.png IMG…    the pictures as the Chrome Web Store shows a video before it plays
//                                               (cover/board.html); IMG is a file, or FILE=LABEL
// Needs ffmpeg and puppeteer: PUPPETEER is the path of puppeteer-core's module (see README.md), or puppeteer is on
// NODE_PATH. Headless; uses the installed Chrome, or the browser at CHROME_BIN.
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const dir = path.dirname(fileURLToPath(import.meta.url));
const puppeteer = (await import(process.env.PUPPETEER ?? 'puppeteer')).default;
const launch = () => puppeteer.launch({ headless: true,
  ...(process.env.CHROME_BIN ? { executablePath: process.env.CHROME_BIN } : { channel: 'chrome' }) });

async function shoot(browser, url, { width, height, scale = 1, fullPage = false }, file) {
  const page = await browser.newPage();
  await page.setViewport({ width, height, deviceScaleFactor: scale });
  await page.goto(url, { waitUntil: 'load' });
  // A picture that did not load would leave a hole that still renders: fail instead.
  const missing = await page.evaluate(async () => {
    const urls = [...document.images].map((img) => img.src);
    for (const el of document.querySelectorAll('*')) {
      const bg = /url\("?([^")]+)"?\)/.exec(getComputedStyle(el).backgroundImage);
      if (bg) urls.push(bg[1]);
    }
    const loads = (src) => new Promise((done) => { const i = new Image(); i.onload = () => done(null); i.onerror = () => done(src); i.src = src; });
    return (await Promise.all([...new Set(urls)].map(loads))).filter(Boolean);
  });
  if (missing.length) throw new Error(`${url}: could not load ${missing.join(', ')}`);
  await page.screenshot({ path: file, fullPage, ...(file.endsWith('.jpg') ? { type: 'jpeg', quality: 92 } : { type: 'png' }) });
  await page.close();
}

const [mode, ...rest] = process.argv.slice(2);
if (mode === 'board') {
  const [out, ...pictures] = rest;
  if (!out || !pictures.length) throw new Error('usage: node render-cover.mjs board OUT.png IMG…');
  const url = pathToFileURL(path.join(dir, 'cover/board.html'));
  for (const picture of pictures) {
    const [file, label] = picture.split('=');
    url.searchParams.append('img', pathToFileURL(path.resolve(file)).href + (label ? `|${label}` : ''));
  }
  const browser = await launch();
  try { await shoot(browser, url.href, { width: 1040, height: 600, fullPage: true }, path.resolve(out)); } finally { await browser.close(); }
} else if (mode === undefined) {
  // The frame of the fill take with both fields filled in, 3.4 s in: the cover shows its two fields.
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-ss', '3.4', '-i', path.join(dir, 'takes/fill.mov'), '-frames:v', '1', path.join(dir, 'cover/filled.png')]);
  const url = pathToFileURL(path.join(dir, 'cover/cover.html')).href;
  const browser = await launch();
  try {
    await shoot(browser, url, { width: 1280, height: 720 }, path.join(dir, 'cover.jpg'));
    await shoot(browser, url, { width: 1280, height: 720, scale: 1.5 }, path.join(dir, 'composition/cover-1080p.png'));
  } finally { await browser.close(); }
} else {
  throw new Error(`unknown mode ${mode}`);
}
