// The popup's passwordpie.com account: the real one, and the App Store build's nothing. Only `livePopupAccount` reaches
// the site, and the App Store build's entry point never refers to it, so it is not in that bundle (docs/ACCOUNTS.md).
// Signing in happens on the site: the popup only opens its connect page.
import { browser } from 'wxt/browser';
import type { PopupApi } from '../components/popup';
import { AccountStore, redeemKey, refreshEntitlement } from './account';
import { currentUser, signOut } from './auth';
import { storageKV } from './browser-kv';
import { SITE_URL } from './config';
import { connectUrl } from './site-connect';

export type PopupAccount = Pick<
  PopupApi,
  'accountEnabled' | 'signInUrl' | 'siteName' | 'user' | 'cachedEntitlement' | 'refreshEntitlement' | 'signOut' | 'redeem'
>;

export function livePopupAccount(): PopupAccount {
  const store = new AccountStore(storageKV(browser.storage.local));
  return {
    accountEnabled: true,
    signInUrl: connectUrl(SITE_URL),
    siteName: new URL(SITE_URL).host,
    user: () => currentUser(store, fetch, SITE_URL),
    cachedEntitlement: async () => (await store.entitlement()) ?? null,
    refreshEntitlement: () => refreshEntitlement(store, fetch, SITE_URL),
    signOut: () => signOut(store, fetch, SITE_URL),
    redeem: (code) => redeemKey(store, fetch, SITE_URL, code),
  };
}

/** The App Store build. The popup never calls these, because `accountEnabled` is false. */
export const noPopupAccount: PopupAccount = {
  accountEnabled: false,
  signInUrl: '',
  siteName: '',
  user: async () => null,
  cachedEntitlement: async () => null,
  refreshEntitlement: async () => ({ ok: false, reason: 'network' }),
  signOut: async () => undefined,
  redeem: async () => ({ ok: false, reason: 'network' }),
};
