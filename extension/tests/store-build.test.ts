// @vitest-environment node
// The extension is a bridge to the app: it has no account, signs in nowhere, asks no site anything and stores nothing
// (docs/UX.md, "Premium in the browser"). So the Safari build inside the App Store app is the same as every other, and
// the one address in it is the download page. Checked on the real bundles, built into a temporary folder so `.output`
// is left alone.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const ROOT = resolve(import.meta.dirname, '..');
/** Strings only a sign-in, an account or a request to the site would put in a bundle. */
const ACCOUNT_MARKERS = ['/extension/connect', 'passwordpie-site', 'site-session', '/api/auth/', '/api/premium/', '/pricing', 'entitlement', 'Bearer '];

const out = mkdtempSync(join(tmpdir(), 'pp-store-build-'));

function build(browser: 'chrome' | 'safari'): string {
  const outDir = join(out, browser);
  const script = "import { build } from 'wxt'; await build({ browser: process.argv[2], manifestVersion: 3, outDir: process.argv[1] });";
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', script, outDir, browser], { cwd: ROOT, encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`build ${browser} failed:\n${result.stdout}\n${result.stderr}`);
  return join(outDir, `${browser}-mv3`);
}

function bundleText(dir: string): string {
  return readdirSync(dir, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile() && /\.(js|json|html)$/.test(entry.name))
    .map((entry) => readFileSync(join(entry.parentPath, entry.name), 'utf8'))
    .join('\n');
}

const dirs: Record<string, string> = {};
const bundles: Record<string, string> = {};

beforeAll(() => {
  for (const browser of ['chrome', 'safari'] as const) {
    dirs[browser] = build(browser);
    bundles[browser] = bundleText(dirs[browser]);
  }
}, 120_000);

afterAll(() => {
  rmSync(out, { recursive: true, force: true });
});

describe.each(['chrome', 'safari'])('the %s build', (browser) => {
  it('has no sign-in, no account and no request to the site', () => {
    for (const marker of ACCOUNT_MARKERS) expect(bundles[browser], marker).not.toContain(marker);
  });

  it('keeps one passwordpie.com address: the download page the toolbar button opens when the app is not there', () => {
    // WEBSITE_URL in protocol.ts. It is opened in a tab, never fetched. Any other address of the site turns this red.
    const addresses = new Set(bundles[browser]?.match(/https?:\/\/[\w.-]*passwordpie\.com[\w./?=&%-]*/g));
    expect([...addresses]).toEqual(['https://passwordpie.com/']);
  });

  it('asks for no storage permission', () => {
    expect(bundles[browser]).not.toMatch(/"storage"/);
  });

  it('has no popup and no other extension page', () => {
    expect(bundles[browser]).not.toContain('default_popup');
    expect(existsSync(join(dirs[browser] ?? '', 'popup.html'))).toBe(false);
  });
});
