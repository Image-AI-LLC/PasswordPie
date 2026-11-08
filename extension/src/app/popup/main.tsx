import { createRoot } from 'react-dom/client';
import { browser } from 'wxt/browser';
import { Popup, type PopupApi } from '@/components/popup';
import { AccountStore, redeemKey, refreshEntitlement } from '@/lib/account';
import {
  currentUser,
  googleAvailable,
  makeAuthClient,
  signInWithEmail,
  signInWithGoogle,
  signOut,
  signUpWithEmail,
  type IdentityLike,
} from '@/lib/auth';
import { storageKV } from '@/lib/browser-kv';
import { GOOGLE_CLIENT_ID, SITE_URL, SiteRoutes, STORE_BUILD, UPGRADE_URL } from '@/lib/config';
import type { PopupStatus } from '@/lib/protocol';
import './style.css';

const store = new AccountStore(storageKV(browser.storage.local));
const client = makeAuthClient(store, SITE_URL);
const identity = (browser as unknown as { identity?: IdentityLike }).identity;

const api: PopupApi = {
  sellsPremium: !STORE_BUILD,
  googleAvailable: googleAvailable(identity, GOOGLE_CLIENT_ID),
  ...(UPGRADE_URL ? { upgradeUrl: UPGRADE_URL } : {}),
  signUpUrl: SiteRoutes.signUp,
  forgotPasswordUrl: SiteRoutes.forgotPassword,
  async openPanel() {
    await browser.runtime.sendMessage({ type: 'open-panel' }).catch(() => undefined);
    window.close();
  },
  async panelShortcut() {
    const commands = await browser.commands?.getAll().catch(() => []);
    return commands?.find((c) => c.name === 'open-panel')?.shortcut ?? '';
  },
  async status() {
    const answer: unknown = await browser.runtime.sendMessage({ type: 'popup-status' }).catch(() => undefined);
    return (answer ?? {}) as PopupStatus;
  },
  user: () => currentUser(client, store),
  cachedEntitlement: async () => (await store.entitlement()) ?? null,
  refreshEntitlement: () => refreshEntitlement(store, fetch, SITE_URL),
  signIn: (email, password) => signInWithEmail(client, email, password),
  signUp: (name, email, password) => signUpWithEmail(client, name, email, password),
  signInWithGoogle: () => signInWithGoogle(identity, store, fetch, SITE_URL),
  signOut: () => signOut(client, store),
  redeem: (code) => redeemKey(store, fetch, SITE_URL, code),
  openUrl(url) {
    void browser.tabs.create({ url });
    window.close();
  },
};

const root = document.getElementById('root');
if (root) createRoot(root).render(<Popup api={api} />);
