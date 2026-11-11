import type { ConfigEnv, UserManifest } from 'wxt';

// The Chrome Web Store item's public key ("Package > View public key" in the developer dashboard). It gives an unpacked
// build the store's ID, BridgeConstants.chromeExtensionID, which the native host manifest allows
// (docs/BROWSER_EXTENSION.md, "Chrome"; tests/extension-id.test.ts).
export const CHROME_KEY =
  'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2zW0SYYgInyFlKRpe5Pk64yK3+DV8HVkPayUQ7s2Jd/kOKAdSXoSpm/38LlBW2YKEbaq9Uib7W+TSFZyn6XWUYmmLsbhOUDlFaevsV1Ey/Mgpqt9wIqmmzhqoJKJ7QwqRh57e6+WitmJDnDwBe2xO2P1ASD3MpyYtHMZh8Cv+cAq8cwEIiYoTuefGurYDqY69IkYvm6mEKxWpSm289HeHVCwR/JxPWKxGf+8+V6mUrnfiKTsYI1P5LcZI2aAafnLIiupDhN2GCcgQ5HBlrfoOkTROyTDhNyjY1fFhR0pfApiGe4yi7X/mdSQHGWll7a6A3ZPWZ+EQpfalk8+1JpvsQIDAQAB';

/**
 * `PP_STORE_PACKAGE=1 wxt zip` (pnpm zip:chrome-store): the package uploaded to the Chrome Web Store, which rejects a
 * manifest with `key`. An env var, not a WXT mode: the mode would also become NODE_ENV and the build would not be production.
 */
export const STORE_PACKAGE_ENV = 'PP_STORE_PACKAGE';

/** The panel shortcut (`commands`). Chrome may not grant it (a key already taken), so the popup reads the real one. */
export const OPEN_PANEL_COMMAND = 'open-panel';

export function extensionManifest({
  browser,
  storePackage,
  account = true,
}: {
  browser: ConfigEnv['browser'];
  storePackage: boolean;
  /** False for the App Store build (WXT_PP_STORE=mas): no account, so no `storage` permission. */
  account?: boolean;
}): UserManifest {
  return {
    name: 'PasswordPie',
    description: 'Fills sign-in forms from the PasswordPie app on your Mac. Needs PasswordPie for Mac.',
    version: '0.2.0',
    // Chrome: <all_urls> already exposes tab.url, so `tabs` would only add a "browsing history" warning. Safari grants
    // host access per site and keeps it.
    // `storage` keeps the passwordpie.com session and entitlement token (docs/ACCOUNTS.md); the App Store build has no
    // account and does not ask for it. Signing in happens on the site, so there is no `identity` and no `oauth2`.
    permissions: [
      ...(browser === 'safari' ? ['nativeMessaging', 'tabs', 'webNavigation', 'alarms'] : ['nativeMessaging', 'webNavigation', 'alarms']),
      ...(account ? ['storage'] : []),
    ],
    host_permissions: ['<all_urls>'],
    icons: { 16: 'icon/16.png', 32: 'icon/32.png', 48: 'icon/48.png', 128: 'icon/128.png' },
    action: { default_title: 'PasswordPie', default_icon: { 16: 'icon/16.png', 32: 'icon/32.png' } },
    commands: {
      [OPEN_PANEL_COMMAND]: { suggested_key: { default: 'Alt+Shift+P' }, description: 'Open the PasswordPie panel' },
    },
    ...(browser === 'chrome' && !storePackage ? { key: CHROME_KEY } : {}),
  };
}
