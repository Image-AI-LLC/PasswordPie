import { createRoot } from 'react-dom/client';
import { browser } from 'wxt/browser';
import { Popup, type PopupApi } from '@/components/popup';
import { STORE_BUILD, UPGRADE_URL } from '@/lib/config';
import { livePopupAccount, noPopupAccount } from '@/lib/popup-account';
import type { PopupStatus } from '@/lib/protocol';
import './style.css';

// Spelled out so Vite folds it: the App Store build has no code that signs in or asks the site anything.
const account = import.meta.env.WXT_PP_STORE === 'mas' ? noPopupAccount : livePopupAccount();

const api: PopupApi = {
  ...account,
  sellsPremium: !STORE_BUILD,
  ...(UPGRADE_URL ? { upgradeUrl: UPGRADE_URL } : {}),
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
  openUrl(url) {
    void browser.tabs.create({ url });
    window.close();
  },
};

const root = document.getElementById('root');
if (root) createRoot(root).render(<Popup api={api} />);
