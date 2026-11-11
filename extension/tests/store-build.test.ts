// @vitest-environment node
// The App Store build (WXT_PP_STORE=mas) has no account: nothing in it may listen for the site's sign-in or know the site
// it would talk to (docs/ACCOUNTS.md, "App Store rules"). The one address it keeps is the download page. Checked on the real bundle, built next to a normal one as the
// control, both into a temporary folder so `.output` is left alone.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const ROOT = resolve(import.meta.dirname, '..');
/** A site no build would use, so finding it in a bundle can only mean SITE_URL. */
const SITE = 'https://site-check.invalid';
/** Strings only the sign-in handover, or a request to the site, puts in a bundle. */
const SIGN_IN_MARKERS = [SITE, 'site-check.invalid', '/extension/connect', 'passwordpie-site', 'site-session', '/api/auth/', '/api/premium/'];

const out = mkdtempSync(join(tmpdir(), 'pp-store-build-'));

function buildSafari(name: string, env: Record<string, string>): string {
  const outDir = join(out, name);
  const script = "import { build } from 'wxt'; await build({ browser: 'safari', manifestVersion: 3, outDir: process.argv[1] });";
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', script, outDir], {
    cwd: ROOT,
    env: { ...process.env, WXT_PP_SITE_URL: SITE, ...env },
    encoding: 'utf8',
  });
  if (result.status !== 0) throw new Error(`build ${name} failed:\n${result.stdout}\n${result.stderr}`);
  return join(outDir, 'safari-mv3');
}

function bundleText(dir: string): string {
  return readdirSync(dir, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile() && /\.(js|json|html)$/.test(entry.name))
    .map((entry) => readFileSync(join(entry.parentPath, entry.name), 'utf8'))
    .join('\n');
}

let mas = '';
let direct = '';

beforeAll(() => {
  const env = { ...process.env };
  delete env.WXT_PP_STORE;
  mas = bundleText(buildSafari('mas', { WXT_PP_STORE: 'mas' }));
  direct = bundleText(buildSafari('direct', { WXT_PP_STORE: '' }));
}, 120_000);

afterAll(() => {
  rmSync(out, { recursive: true, force: true });
});

describe('the App Store Safari build', () => {
  it('has the sign-in handover and the site address when it is not the App Store build (control)', () => {
    for (const marker of SIGN_IN_MARKERS) expect(direct, marker).toContain(marker);
  });

  it('has no connect listener, no address of the site the build talks to, and no request to the site', () => {
    for (const marker of SIGN_IN_MARKERS) expect(mas, marker).not.toContain(marker);
  });

  it('keeps one passwordpie.com address: the download page the toolbar opens when the app cannot be started', () => {
    // WEBSITE_URL in protocol.ts. It is opened in a tab, never fetched. Any other address of the site turns this red.
    const addresses = new Set(mas.match(/https?:\/\/[\w.-]*passwordpie\.com[\w./?=&%-]*/g));
    expect([...addresses]).toEqual(['https://passwordpie.com/']);
  });

  it('asks for no storage permission', () => {
    expect(mas).not.toMatch(/"storage"/);
    expect(direct).toMatch(/"storage"/);
  });
});
