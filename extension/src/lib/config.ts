// Build-time settings. `WXT_PP_SITE_URL` points the build at another site (the mock in extension/dev), and
// `WXT_PP_STORE=mas` makes the Safari build that ships inside the App Store app.
// Read as `import.meta.env.X` so Vite inlines them and the App Store build carries no address to ask and no upgrade link.
// (The one passwordpie.com link left there is `WEBSITE_URL` in protocol.ts, the download page; tests/store-build.test.ts.)

/** passwordpie.com, or the site this build was made for. No trailing slash. Empty in the App Store build, which asks the site nothing. */
export const SITE_URL =
  import.meta.env.WXT_PP_STORE === 'mas' ? '' : (import.meta.env.WXT_PP_SITE_URL || 'https://passwordpie.com').replace(/\/+$/, '');

/** The App Store build: no account, no upgrade link and no key field (App Store rules, docs/ACCOUNTS.md). */
export const STORE_BUILD = import.meta.env.WXT_PP_STORE === 'mas';

/** Where "Upgrade" goes. None in the App Store build. */
export const UPGRADE_URL: string | undefined = import.meta.env.WXT_PP_STORE === 'mas' ? undefined : `${SITE_URL}/pricing`;
