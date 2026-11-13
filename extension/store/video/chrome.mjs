// Starts the Chrome used for the promo video: its own profile (never the user's), the unpacked extension, and
// https://fernway.example served by dev/mock-site.mjs on 127.0.0.1:$SITE_PORT. Stays running; record.mjs connects to it
// on 127.0.0.1:$CDP_PORT. See README.md.
//
//   PUPPETEER=<path to puppeteer-core> UDD=<empty dir> SPKI=<base64 sha256 of the site's key> node chrome.mjs
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const puppeteer = (await import(process.env.PUPPETEER ?? 'puppeteer-core')).default;
const dir = path.dirname(fileURLToPath(import.meta.url));
const udd = process.env.UDD;
const sitePort = process.env.SITE_PORT ?? '8443';
const cdpPort = process.env.CDP_PORT ?? '9431';
if (!udd || !process.env.SPKI) throw new Error('UDD and SPKI are required');

// Chrome with --user-data-dir only reads native messaging hosts from <udd>/NativeMessagingHosts. PasswordPie writes its
// manifest to the default place when it starts; copy it.
mkdirSync(path.join(udd, 'NativeMessagingHosts'), { recursive: true });
copyFileSync(
  path.join(homedir(), 'Library/Application Support/Google/Chrome/NativeMessagingHosts/com.passwordpie.json'),
  path.join(udd, 'NativeMessagingHosts/com.passwordpie.json'),
);

// No "Save password?" from Chrome's own password manager in the shots.
mkdirSync(path.join(udd, 'Default'), { recursive: true });
if (!existsSync(path.join(udd, 'Default/Preferences'))) {
  writeFileSync(path.join(udd, 'Default/Preferences'), JSON.stringify({
    credentials_enable_service: false,
    credentials_enable_autosignin: false,
    profile: { password_manager_enabled: false },
    autofill: { profile_enabled: false, credit_card_enabled: false },
  }));
}

// Window in screen points, top-left origin. record.mjs captures exactly this rectangle.
const [x, y, w, h] = (process.env.WINDOW ?? '95,118,1280,720').split(',');
const browser = await puppeteer.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: false,
  pipe: true,
  defaultViewport: null,
  enableExtensions: true,
  ignoreDefaultArgs: true, // no --enable-automation: no "controlled by automated test software" bar
  args: [
    `--user-data-dir=${udd}`,
    '--remote-debugging-pipe',
    `--remote-debugging-port=${cdpPort}`,
    '--enable-unsafe-extension-debugging',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-search-engine-choice-screen',
    '--hide-crash-restore-bubble',
    '--disable-features=Translate,MediaRouter,OptimizationHints,PrivacySandboxSettings4',
    `--host-resolver-rules=MAP fernway.example 127.0.0.1:${sitePort}`,
    `--ignore-certificate-errors-spki-list=${process.env.SPKI}`,
    `--window-position=${x},${y}`,
    `--window-size=${w},${h}`,
    'about:blank',
  ],
});
const id = await browser.installExtension(path.resolve(dir, '../../.output/chrome-mv3'));
// An extension installed this way starts without site access ("This extension has no additional site access"), so it
// cannot see the tab's site. Grant what the store install grants: all sites.
const page = await browser.newPage();
await page.goto('chrome://extensions/');
await page.evaluate(async (extensionId) => {
  await chrome.developerPrivate.updateProfileConfiguration({ inDeveloperMode: true });
  await chrome.developerPrivate.updateExtensionConfiguration({ extensionId, hostAccess: 'ON_ALL_SITES' });
}, id);
await page.goto('https://fernway.example/login');
// Close the "unsupported command-line flag" bar (--host-resolver-rules): its × is 30 pt from the window's right
// edge, 115 pt below its top.
await page.bringToFront();
if (process.env.PPVIDEO) {
  execFileSync(process.env.PPVIDEO, ['activate', String(browser.process()?.pid)]);
  await new Promise((r) => setTimeout(r, 500));
  execFileSync(process.env.PPVIDEO, ['click', String(Number(x) + Number(w) - 30), String(Number(y) + 115)]);
}
for (const p of await browser.pages()) if (p !== page) await p.close();
console.log(`chrome ready, extension ${id}, cdp ${cdpPort}, pid ${browser.process()?.pid}`);
browser.on('disconnected', () => process.exit(0));
