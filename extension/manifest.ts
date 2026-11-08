import type { ConfigEnv, UserManifest } from 'wxt';

// Pins the unpacked Chrome build's ID to pbbiimlkojflhpopeplkbfeecanbbdoj, which the native host
// manifest's allowed_origins lists (docs/BROWSER_EXTENSION.md, "Chrome").
export const CHROME_KEY =
  'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0kseYmc4PYVMVdM0iSbi5mu2Z3GTAXmIZTXXTdJLLED61C/5ql+jaokNIOyKWB9LmNAJFP3/V6J/s3GHVNo5vwcx4hAVuGtNFmKXxiZb68Wi49SQL9OkafgiO6LPEVxtl4/POuthz+FO0JG5nhLvn18jmy4VxsmAdAtS5RIEPz7D9Efl5HbfUMMcUJl6HF8lIHh2T6Yd04iPeQ2kgBg8bRCI0aSDGB7FEam8dHdXmPRBNv14meLQrnSG+a54T1fdxL0TCtArVDpV5ixKJs6Wr4RITJlkevvcsY5n8MRdUyKcM18wzKYYG7LTOFumwwEaPo4JAI2DIDnDLQWEvaTPKQIDAQAB';

/** `wxt zip --mode store`: the package uploaded to the Chrome Web Store, which rejects a manifest with `key`. */
export const STORE_MODE = 'store';

export function extensionManifest({ browser, mode }: Pick<ConfigEnv, 'browser' | 'mode'>): UserManifest {
  return {
    name: 'PasswordPie',
    description: 'Fills sign-in forms from the PasswordPie app on your Mac. Needs PasswordPie for Mac.',
    version: '0.1.0',
    // Chrome: <all_urls> already exposes tab.url, so `tabs` would only add a "browsing history" warning. Safari grants
    // host access per site and keeps it.
    permissions: browser === 'safari' ? ['nativeMessaging', 'tabs', 'webNavigation', 'alarms'] : ['nativeMessaging', 'webNavigation', 'alarms'],
    host_permissions: ['<all_urls>'],
    icons: { 16: 'icon/16.png', 32: 'icon/32.png', 48: 'icon/48.png', 128: 'icon/128.png' },
    action: { default_title: 'PasswordPie', default_icon: { 16: 'icon/16.png', 32: 'icon/32.png' } },
    ...(browser === 'chrome' && mode !== STORE_MODE ? { key: CHROME_KEY } : {}),
  };
}
