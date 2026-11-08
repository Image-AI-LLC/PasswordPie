import { describe, expect, it } from 'vitest';
import { CHROME_KEY, extensionManifest } from '../manifest';

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
      expect(extensionManifest({ browser: 'chrome', storePackage }).permissions).toEqual(['nativeMessaging', 'webNavigation', 'alarms']);
    }
  });

  it('keeps tabs for Safari, where host access is granted per site', () => {
    expect(extensionManifest({ browser: 'safari', storePackage: false }).permissions).toEqual([
      'nativeMessaging',
      'tabs',
      'webNavigation',
      'alarms',
    ]);
  });

  it('never puts a key in the Safari build', () => {
    expect(extensionManifest({ browser: 'safari', storePackage: false })).not.toHaveProperty('key');
  });
});
