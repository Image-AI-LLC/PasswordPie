import { defineConfig } from 'wxt';

// Pins the unpacked Chrome build's ID to pbbiimlkojflhpopeplkbfeecanbbdoj, which the native host
// manifest's allowed_origins lists (docs/BROWSER_EXTENSION.md, "Chrome").
const CHROME_KEY =
  'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0kseYmc4PYVMVdM0iSbi5mu2Z3GTAXmIZTXXTdJLLED61C/5ql+jaokNIOyKWB9LmNAJFP3/V6J/s3GHVNo5vwcx4hAVuGtNFmKXxiZb68Wi49SQL9OkafgiO6LPEVxtl4/POuthz+FO0JG5nhLvn18jmy4VxsmAdAtS5RIEPz7D9Efl5HbfUMMcUJl6HF8lIHh2T6Yd04iPeQ2kgBg8bRCI0aSDGB7FEam8dHdXmPRBNv14meLQrnSG+a54T1fdxL0TCtArVDpV5ixKJs6Wr4RITJlkevvcsY5n8MRdUyKcM18wzKYYG7LTOFumwwEaPo4JAI2DIDnDLQWEvaTPKQIDAQAB';

export default defineConfig({
  srcDir: 'src',
  manifestVersion: 3,
  manifest: ({ browser }) => ({
    name: 'PasswordPie',
    description: 'Fill passwords from PasswordPie on your Mac.',
    version: '0.1.0',
    permissions: ['nativeMessaging', 'tabs', 'webNavigation', 'alarms'],
    host_permissions: ['<all_urls>'],
    icons: { 16: 'icon/16.png', 32: 'icon/32.png', 48: 'icon/48.png', 128: 'icon/128.png' },
    action: { default_title: 'PasswordPie', default_icon: { 16: 'icon/16.png', 32: 'icon/32.png' } },
    ...(browser === 'chrome' ? { key: CHROME_KEY } : {}),
  }),
});
