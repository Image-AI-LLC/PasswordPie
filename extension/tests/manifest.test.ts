import { describe, expect, it } from 'vitest';
import { CHROME_KEY, STORE_MODE, extensionManifest } from '../manifest';

describe('extensionManifest', () => {
  it('pins the unpacked Chrome ID with the public key in development and production builds', () => {
    expect(extensionManifest({ browser: 'chrome', mode: 'development' }).key).toBe(CHROME_KEY);
    expect(extensionManifest({ browser: 'chrome', mode: 'production' }).key).toBe(CHROME_KEY);
  });

  it('leaves the key out of the Chrome Web Store package, which rejects it', () => {
    const manifest = extensionManifest({ browser: 'chrome', mode: STORE_MODE });
    expect(manifest).not.toHaveProperty('key');
    expect(manifest.permissions).toEqual(['nativeMessaging', 'tabs', 'webNavigation', 'alarms']);
  });

  it('never puts a key in the Safari build', () => {
    expect(extensionManifest({ browser: 'safari', mode: 'production' })).not.toHaveProperty('key');
  });
});
