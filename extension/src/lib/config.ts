// Build-time settings. `WXT_PP_SITE_URL` points the build at another site (the mock in extension/dev), `WXT_PP_STORE=mas`
// makes the Safari build that ships inside the App Store app, and `WXT_GOOGLE_CLIENT_ID` turns on Google sign-in.
// Read as `import.meta.env.X` so Vite inlines them and the App Store build carries no upgrade link at all.

/** passwordpie.com, or the site this build was made for. No trailing slash. */
export const SITE_URL = (import.meta.env.WXT_PP_SITE_URL || 'https://passwordpie.com').replace(/\/+$/, '');

/** The App Store build: no upgrade link and no key field (App Store rules, docs/ACCOUNTS.md). */
export const STORE_BUILD = import.meta.env.WXT_PP_STORE === 'mas';

export const GOOGLE_CLIENT_ID = import.meta.env.WXT_GOOGLE_CLIENT_ID || '';

/** Where "Upgrade" goes. None in the App Store build. */
export const UPGRADE_URL: string | undefined = import.meta.env.WXT_PP_STORE === 'mas' ? undefined : `${SITE_URL}/pricing`;

export const SiteRoutes = {
  signUp: `${SITE_URL}/sign-up`,
  forgotPassword: `${SITE_URL}/forgot-password`,
  account: `${SITE_URL}/account`,
} as const;
