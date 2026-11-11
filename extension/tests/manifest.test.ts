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
      expect(extensionManifest({ browser: 'chrome', storePackage }).permissions).toEqual([
        'nativeMessaging',
        'webNavigation',
        'alarms',
        'contextMenus',
        'storage',
      ]);
    }
  });

  it('keeps tabs for Safari, where host access is granted per site', () => {
    expect(extensionManifest({ browser: 'safari', storePackage: false }).permissions).toEqual([
      'nativeMessaging',
      'tabs',
      'webNavigation',
      'alarms',
      'contextMenus',
      'storage',
    ]);
  });

  it('asks for no storage permission in the App Store build, which has no account', () => {
    expect(extensionManifest({ browser: 'safari', storePackage: false, account: false }).permissions).toEqual([
      'nativeMessaging',
      'tabs',
      'webNavigation',
      'alarms',
      'contextMenus',
    ]);
  });

  it('has no Google sign-in: no identity permission and no oauth2, in any build', () => {
    for (const browser of ['chrome', 'safari'] as const) {
      for (const storePackage of [false, true]) {
        for (const account of [false, true]) {
          const manifest = extensionManifest({ browser, storePackage, account });
          expect(manifest.permissions).not.toContain('identity');
          expect(manifest).not.toHaveProperty('oauth2');
        }
      }
    }
  });

  it('is 0.3.0: the store needs a version above the one it has, and the package agrees', () => {
    const { version } = extensionManifest({ browser: 'chrome', storePackage: true });
    expect(version).toBe('0.3.0');
    expect(JSON.parse(readFileSync(resolve(import.meta.dirname, '../package.json'), 'utf8')).version).toBe(version);
    expect(EXTENSION_VERSION, 'the version the native hello reports').toBe(version);
  });

  it('declares the panel shortcut the popup also offers', () => {
    expect(extensionManifest({ browser: 'chrome', storePackage: true }).commands).toHaveProperty('open-panel');
  });

  it('never puts a key in the Safari build', () => {
    expect(extensionManifest({ browser: 'safari', storePackage: false })).not.toHaveProperty('key');
  });
});
