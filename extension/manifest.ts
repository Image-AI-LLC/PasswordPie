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

/** The panel shortcut (`commands`). Chrome may not grant it (a key already taken); the toolbar button always works. */
export const OPEN_PANEL_COMMAND = 'open-panel';

/** One manifest for every build: the extension has no account, so the App Store's Safari build is the same as the rest. */
export function extensionManifest({ browser, storePackage }: { browser: ConfigEnv['browser']; storePackage: boolean }): UserManifest {
  return {
    // Chrome: the store takes its title (≤ 75 characters) and summary (≤ 132) from these, so they say what it is in the
    // words people search for, and that it needs the app. Safari lists the extension under the app's own name in its
    // settings, in both channels, so it keeps the plain one. Nothing matches on the name (tests/manifest.test.ts).
    ...(browser === 'chrome'
      ? {
          name: 'PasswordPie: Password Manager for Mac',
          short_name: 'PasswordPie',
          description: 'Autofill passwords from PasswordPie, the KeePass password manager for Mac. Needs the PasswordPie app.',
        }
      : { name: 'PasswordPie', description: 'Fills sign-in forms from the PasswordPie app on your Mac. Needs PasswordPie for Mac.' }),
    version: '0.6.0',
    // Chrome: <all_urls> already exposes tab.url, so `tabs` would only add a "browsing history" warning. Safari grants
    // host access per site and keeps it.
    // No `storage`: the extension keeps nothing. No `identity` and no `oauth2`: it has no account and no sign-in.
    permissions: [
      ...(browser === 'safari' ? ['nativeMessaging', 'tabs', 'webNavigation', 'alarms'] : ['nativeMessaging', 'webNavigation', 'alarms']),
      // The lines in the button's right-click menu and the page's (toolbar.ts). It shows no warning at install.
      'contextMenus',
    ],
    host_permissions: ['<all_urls>'],
    icons: { 16: 'icon/16.png', 32: 'icon/32.png', 48: 'icon/48.png', 128: 'icon/128.png' },
    // Nothing opens under the button: a click is `action.onClicked`, which opens the app's panel.
    action: { default_title: 'PasswordPie', default_icon: { 16: 'icon/16.png', 32: 'icon/32.png' } },
    commands: {
      [OPEN_PANEL_COMMAND]: { suggested_key: { default: 'Alt+Shift+P' }, description: 'Open the PasswordPie panel' },
    },
    ...(browser === 'chrome' && !storePackage ? { key: CHROME_KEY } : {}),
  };
}
