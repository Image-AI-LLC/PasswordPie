// The toolbar button and the right-click menus (docs/UX.md, "The toolbar button"). The popup is for setting up: once the
// account has Premium, a click on the button opens PasswordPie directly, and scan, the website and the account are in
// the button's menu. The page's own menu has scan too. The browser is injected, so tests can drive it.

import type { Entitlement } from './account';
import { SCAN_MESSAGES, type ScanOutcome } from './scan-outcome';

export const MENU_SCAN_ACTION = 'passwordpie-scan';
export const MENU_WEBSITE = 'passwordpie-website';
export const MENU_ACCOUNT = 'passwordpie-account';
export const MENU_SCAN_PAGE = 'passwordpie-scan-page';
/** How long the button carries "!" for a scan whose page could not show the note. */
export const BADGE_MS = 6_000;
const BUTTON_TITLE = 'PasswordPie';

export interface MenuItem {
  id: string;
  title: string;
  contexts: string[];
  documentUrlPatterns?: string[];
}

/** The lines added to the button's menu, then the one in the page's menu. `account` is false in the App Store build. */
export function menuItems(account: boolean): MenuItem[] {
  return [
    { id: MENU_SCAN_ACTION, title: 'Scan QR code on this page', contexts: ['action'] },
    { id: MENU_WEBSITE, title: 'Open passwordpie.com', contexts: ['action'] },
    ...(account ? [{ id: MENU_ACCOUNT, title: 'Account…', contexts: ['action'] }] : []),
    {
      id: MENU_SCAN_PAGE,
      title: 'Scan QR code with PasswordPie',
      // A QR code is an <img>, or a <canvas> or <svg>, which count as the page. `frame`: a page inside another.
      contexts: ['page', 'frame', 'image'],
      documentUrlPatterns: ['http://*/*', 'https://*/*'],
    },
  ];
}

/** What is kept of the passwordpie.com account (AccountStore). */
export interface ToolbarAccount {
  sessionToken(): Promise<string | undefined>;
  entitlement(): Promise<Entitlement | undefined>;
}

/** Signed in, with Premium that has not run out, as far as the browser knows without asking the site. */
export async function premiumNow(account: ToolbarAccount, now: number): Promise<boolean> {
  try {
    const [token, entitlement] = await Promise.all([account.sessionToken(), account.entitlement()]);
    if (!token || !entitlement?.premium) return false;
    if (!entitlement.expiresAt) return true;
    const until = Date.parse(entitlement.expiresAt);
    return Number.isNaN(until) || until > now;
  } catch {
    return false;
  }
}

/** The browser APIs the toolbar uses. Each rejects when the browser does not have it or refuses. */
export interface ToolbarBrowser {
  removeAllMenus(): Promise<void>;
  createMenu(item: MenuItem): Promise<void>;
  /** "" makes a click on the button an event (`action.onClicked`) and shows no popup. */
  setPopup(popup: string): Promise<void>;
  openPopup(): Promise<void>;
  openTab(url: string): Promise<unknown>;
  /** The note in the corner of the tab's page. False when the page did not show it. */
  showNote(tabId: number, kind: ScanOutcome['kind']): Promise<boolean>;
  setBadge(text: string, title: string): Promise<void>;
}

export class Toolbar {
  private actionMenu = false;

  constructor(
    private readonly deps: {
      browser: ToolbarBrowser;
      /** The popup page, as the manifest names it. */
      popupPath: string;
      /** The same page as a URL a tab can open. */
      popupUrl: string;
      websiteUrl: string;
      /** None in the App Store build: no account, so nothing to set up in the popup. */
      account?: ToolbarAccount;
      showPanel(): Promise<void>;
      /** Asks the site for Premium again. None in the App Store build. */
      refresh?(): Promise<unknown>;
      scan(): Promise<ScanOutcome>;
      now?: () => number;
      setTimeout?: (run: () => void, ms: number) => void;
    },
  ) {}

  /** Each time the background starts: the menus again (they are per browser session), then what a click does. */
  async start(): Promise<void> {
    const { browser } = this.deps;
    const made = new Set<string>();
    try {
      await browser.removeAllMenus();
      for (const item of menuItems(this.deps.account !== undefined)) {
        await browser.createMenu(item).then(
          () => made.add(item.id),
          () => undefined,
        );
      }
    } catch {
      // No menus in this browser: the popup stays.
    }
    // Scan must stay in reach: without its line in the button's menu, the popup keeps it.
    this.actionMenu = made.has(MENU_SCAN_ACTION);
    await this.sync();
  }

  /** True when a click on the button opens PasswordPie with no popup. */
  private async direct(): Promise<boolean> {
    if (!this.actionMenu) return false;
    if (!this.deps.account) return true;
    return premiumNow(this.deps.account, (this.deps.now ?? Date.now)());
  }

  /** After a sign-in, a sign-out or a new answer about Premium. */
  async sync(): Promise<void> {
    await this.deps.browser.setPopup((await this.direct()) ? '' : this.deps.popupPath).catch(() => undefined);
  }

  /** A click on the button while it has no popup. */
  async clicked(): Promise<void> {
    await Promise.all([
      this.deps.showPanel().catch(() => undefined),
      // What opening the popup did: keeps the pass fresh, and brings the popup back if Premium is gone.
      (this.deps.refresh?.() ?? Promise.resolve()).catch(() => undefined),
    ]);
  }

  async menuClicked(id: string | number, tabId: number | undefined): Promise<void> {
    if (id === MENU_WEBSITE) {
      await this.deps.browser.openTab(this.deps.websiteUrl).catch(() => undefined);
    } else if (id === MENU_ACCOUNT) {
      await this.showAccount();
    } else if (id === MENU_SCAN_ACTION || id === MENU_SCAN_PAGE) {
      await this.report(await this.deps.scan().catch((): ScanOutcome => ({ kind: 'none' })), tabId);
    }
  }

  /** The popup, also while the button has none: give it one for the moment it opens. */
  private async showAccount(): Promise<void> {
    const { browser } = this.deps;
    try {
      await browser.setPopup(this.deps.popupPath);
      await browser.openPopup();
    } catch {
      await browser.openTab(this.deps.popupUrl).catch(() => undefined);
    }
    await this.sync();
  }

  /** Says why a scan from a menu handed nothing over. When it did, the app's window is the answer. */
  private async report(outcome: ScanOutcome, tabId: number | undefined): Promise<void> {
    if (outcome.kind === 'sent') return;
    const { browser } = this.deps;
    const shown = tabId === undefined ? false : await browser.showNote(tabId, outcome.kind).catch(() => false);
    if (shown) return;
    await browser.setBadge('!', `${BUTTON_TITLE}: ${SCAN_MESSAGES[outcome.kind]}`).catch(() => undefined);
    (this.deps.setTimeout ?? ((run, ms) => void setTimeout(run, ms)))(() => {
      void browser.setBadge('', BUTTON_TITLE).catch(() => undefined);
    }, BADGE_MS);
  }
}
