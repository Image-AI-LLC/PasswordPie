// Renders promo-small.html to promo-small-440x280.png (24-bit, no alpha, as the Chrome Web Store asks).
// Needs puppeteer (any recent version) on NODE_PATH or installed globally, and macOS `sips`.
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const puppeteer = (await import(process.env.PUPPETEER ?? 'puppeteer')).default;
const dir = path.dirname(fileURLToPath(import.meta.url));
const browser = await puppeteer.launch({ headless: true, channel: 'chrome' });
const page = await browser.newPage();
await page.setViewport({ width: 440, height: 280, deviceScaleFactor: 1 });
await page.goto(`file://${dir}/promo-small.html`);
await page.screenshot({ path: `${dir}/promo-small.jpg`, type: 'jpeg', quality: 100 });
await browser.close();
// JPEG -> PNG drops the alpha channel.
execFileSync('sips', ['-s', 'format', 'png', `${dir}/promo-small.jpg`, '--out', `${dir}/promo-small-440x280.png`], { stdio: 'ignore' });
execFileSync('rm', [`${dir}/promo-small.jpg`]);
