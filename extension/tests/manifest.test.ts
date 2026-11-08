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
      expect(extensionManifest({ browser: 'chrome', storePackage, googleClientId: '' }).permissions).toEqual([
        'nativeMessaging',
        'webNavigation',
        'alarms',
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
      'storage',
    ]);
  });

  it('asks for no storage permission in the App Store build, which has no account', () => {
    expect(extensionManifest({ browser: 'safari', storePackage: false, account: false }).permissions).toEqual([
      'nativeMessaging',
      'tabs',
      'webNavigation',
      'alarms',
    ]);
  });

  it('asks for identity and declares OAuth only for Chrome with a Google client ID', () => {
    const googleClientId = 'client.apps.googleusercontent.com';
    const chrome = extensionManifest({ browser: 'chrome', storePackage: true, googleClientId });
    expect(chrome.permissions).toContain('identity');
    expect(chrome.oauth2).toEqual({ client_id: googleClientId, scopes: ['openid', 'email', 'profile'] });
    const safari = extensionManifest({ browser: 'safari', storePackage: false, googleClientId });
    expect(safari.permissions).not.toContain('identity');
    expect(safari).not.toHaveProperty('oauth2');
    expect(extensionManifest({ browser: 'chrome', storePackage: false, googleClientId: '' })).not.toHaveProperty('oauth2');
  });

  it('declares the panel shortcut the popup also offers', () => {
    expect(extensionManifest({ browser: 'chrome', storePackage: true }).commands).toHaveProperty('open-panel');
  });

  it('never puts a key in the Safari build', () => {
    expect(extensionManifest({ browser: 'safari', storePackage: false })).not.toHaveProperty('key');
  });
});
