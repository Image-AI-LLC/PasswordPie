// The popup's passwordpie.com account: the real one, and the App Store build's nothing. Only `livePopupAccount` reaches
// the site, and the App Store build's entry point never refers to it, so it is not in that bundle (docs/ACCOUNTS.md).
import { browser } from 'wxt/browser';
import type { PopupApi } from '../components/popup';
import { AccountStore, redeemKey, refreshEntitlement } from './account';
import {
  currentUser,
  googleAvailable,
  makeAuthClient,
  signInWithEmail,
  signInWithGoogle,
  signOut,
  signUpWithEmail,
  type IdentityLike,
} from './auth';
import { storageKV } from './browser-kv';
import { GOOGLE_CLIENT_ID, SITE_URL, SiteRoutes } from './config';

export type PopupAccount = Pick<
  PopupApi,
  | 'accountEnabled'
  | 'googleAvailable'
  | 'signUpUrl'
  | 'forgotPasswordUrl'
  | 'user'
  | 'cachedEntitlement'
  | 'refreshEntitlement'
  | 'signIn'
  | 'signUp'
  | 'signInWithGoogle'
  | 'signOut'
  | 'redeem'
>;

export function livePopupAccount(): PopupAccount {
  const store = new AccountStore(storageKV(browser.storage.local));
  const client = makeAuthClient(store, SITE_URL);
  const identity = (browser as unknown as { identity?: IdentityLike }).identity;
  return {
    accountEnabled: true,
    googleAvailable: googleAvailable(identity, GOOGLE_CLIENT_ID),
    signUpUrl: SiteRoutes.signUp,
    forgotPasswordUrl: SiteRoutes.forgotPassword,
    user: () => currentUser(client, store),
    cachedEntitlement: async () => (await store.entitlement()) ?? null,
    refreshEntitlement: () => refreshEntitlement(store, fetch, SITE_URL),
    signIn: (email, password) => signInWithEmail(client, email, password),
    signUp: (name, email, password) => signUpWithEmail(client, name, email, password),
    signInWithGoogle: () => signInWithGoogle(identity, store, fetch, SITE_URL),
    signOut: () => signOut(client, store),
    redeem: (code) => redeemKey(store, fetch, SITE_URL, code),
  };
}

const none = { ok: false, message: 'This version has no account.' } as const;

/** The App Store build. The popup never calls these, because `accountEnabled` is false. */
export const noPopupAccount: PopupAccount = {
  accountEnabled: false,
  googleAvailable: false,
  signUpUrl: '',
  forgotPasswordUrl: '',
  user: async () => null,
  cachedEntitlement: async () => null,
  refreshEntitlement: async () => ({ ok: false, reason: 'network' }),
  signIn: async () => none,
  signUp: async () => none,
  signInWithGoogle: async () => none,
  signOut: async () => undefined,
  redeem: async () => ({ ok: false, reason: 'network' }),
};
