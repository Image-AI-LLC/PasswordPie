import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { CHROME_KEY, extensionManifest } from '../manifest';
import { EXTENSION_VERSION, NATIVE_APP } from '../src/lib/protocol';

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

  it('is 0.6.0: the store needs a version above the one it has, and the package agrees', () => {
    const { version } = extensionManifest({ browser: 'chrome', storePackage: true });
    expect(version).toBe('0.6.0');
    expect(JSON.parse(readFileSync(resolve(import.meta.dirname, '../package.json'), 'utf8')).version).toBe(version);
    expect(EXTENSION_VERSION, 'the version the native hello reports').toBe(version);
  });

  it('connects to the com.passwordpie host: the app installs it next to the old name the store extension ≤ 0.4.0 uses', () => {
    expect(NATIVE_APP).toBe('com.passwordpie');
  });

  it('puts "Password Manager" in the Chrome store title, within the 75 characters the store shows', () => {
    for (const storePackage of [true, false]) {
      const manifest = extensionManifest({ browser: 'chrome', storePackage });
      expect(manifest.name).toBe('PasswordPie: Password Manager for Mac');
      expect(manifest.name).toContain('Password Manager');
      expect([...manifest.name!].length).toBeLessThanOrEqual(75);
      expect(manifest.short_name).toBe('PasswordPie');
    }
  });

  it('keeps the Chrome summary within 132 characters and says it needs the app', () => {
    const { description } = extensionManifest({ browser: 'chrome', storePackage: true });
    expect([...description!].length).toBeLessThanOrEqual(132);
    expect(description).toContain('Needs the PasswordPie app');
  });

  it('keeps the plain name in Safari, whose settings list it next to the app', () => {
    const manifest = extensionManifest({ browser: 'safari', storePackage: false });
    expect(manifest.name).toBe('PasswordPie');
    expect(manifest).not.toHaveProperty('short_name');
  });

  it('keeps the toolbar title PasswordPie in every build', () => {
    for (const browser of ['chrome', 'safari'] as const) {
      expect(extensionManifest({ browser, storePackage: false }).action?.default_title).toBe('PasswordPie');
    }
  });

  it('declares the panel shortcut', () => {
    expect(extensionManifest({ browser: 'chrome', storePackage: true }).commands).toHaveProperty('open-panel');
  });

  it('never puts a key in the Safari build', () => {
    expect(extensionManifest({ browser: 'safari', storePackage: false })).not.toHaveProperty('key');
  });
});
