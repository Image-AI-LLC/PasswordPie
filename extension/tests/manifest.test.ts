import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { CHROME_KEY, extensionManifest } from '../manifest';
import { EXTENSION_VERSION } from '../src/lib/protocol';

describe('extensionManifest', () => {
  it('pins the unpacked Chrome ID with the public key in every build but the store package', () => {
    expect(extensionManifest({ browser: 'chrome', storePackage: false }).key).toBe(CHROME_KEY);
  });

  it('leaves the key out of the Chrome Web Store package, which rejects it', () => {
    const manifest = extensionManifest({ browser: 'chrome', storePackage: true });
    expect(manifest).not.toHaveProperty('key');
  });

  it('asks Chrome for no tabs permission: <all_urls> already exposes the active tab URL', () => {
    for (const storePackage of [false, true]) {
      expect(extensionManifest({ browser: 'chrome', storePackage }).permissions).toEqual(['nativeMessaging', 'webNavigation', 'alarms', 'contextMenus']);
    }
  });

  it('keeps tabs for Safari, where host access is granted per site', () => {
    expect(extensionManifest({ browser: 'safari', storePackage: false }).permissions).toEqual([
      'nativeMessaging',
      'tabs',
      'webNavigation',
      'alarms',
      'contextMenus',
    ]);
  });

  it('has no account: no storage, no identity and no oauth2, in any build', () => {
    for (const browser of ['chrome', 'safari'] as const) {
      for (const storePackage of [false, true]) {
        const manifest = extensionManifest({ browser, storePackage });
        expect(manifest.permissions).not.toContain('storage');
        expect(manifest.permissions).not.toContain('identity');
        expect(manifest).not.toHaveProperty('oauth2');
      }
    }
  });

  it('has no popup: a click on the toolbar button opens PasswordPie', () => {
    for (const browser of ['chrome', 'safari'] as const) {
      expect(extensionManifest({ browser, storePackage: false }).action).not.toHaveProperty('default_popup');
    }
  });

  it('is 0.4.0: the store needs a version above the one it has, and the package agrees', () => {
    const { version } = extensionManifest({ browser: 'chrome', storePackage: true });
    expect(version).toBe('0.4.0');
    expect(JSON.parse(readFileSync(resolve(import.meta.dirname, '../package.json'), 'utf8')).version).toBe(version);
    expect(EXTENSION_VERSION, 'the version the native hello reports').toBe(version);
  });

  it('declares the panel shortcut', () => {
    expect(extensionManifest({ browser: 'chrome', storePackage: true }).commands).toHaveProperty('open-panel');
  });

  it('never puts a key in the Safari build', () => {
    expect(extensionManifest({ browser: 'safari', storePackage: false })).not.toHaveProperty('key');
  });
});
