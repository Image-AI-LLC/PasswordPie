// The right-click menus (docs/UX.md, "The toolbar button"). A click on the toolbar button opens PasswordPie and nothing
// else, so what else the extension can do is here: scan and the website in the button's menu, scan in the page's own.
// The browser is injected, so tests can drive it.

import { SCAN_MESSAGES, type ScanOutcome } from './scan-outcome';

export const MENU_SCAN_ACTION = 'passwordpie-scan';
export const MENU_WEBSITE = 'passwordpie-website';
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

/** The lines added to the button's menu, then the one in the page's menu. */
export const MENU_ITEMS: MenuItem[] = [
  { id: MENU_SCAN_ACTION, title: 'Scan QR code on this page', contexts: ['action'] },
  { id: MENU_WEBSITE, title: 'Open passwordpie.com', contexts: ['action'] },
  {
    id: MENU_SCAN_PAGE,
    title: 'Scan QR code with PasswordPie',
    // A QR code is an <img>, or a <canvas> or <svg>, which count as the page. `frame`: a page inside another.
    contexts: ['page', 'frame', 'image'],
    documentUrlPatterns: ['http://*/*', 'https://*/*'],
  },
];

/** The browser APIs the menus use. Each rejects when the browser does not have it or refuses. */
export interface ToolbarBrowser {
  removeAllMenus(): Promise<void>;
  createMenu(item: MenuItem): Promise<void>;
  openTab(url: string): Promise<unknown>;
  /** The note in the corner of the tab's page. False when the page did not show it. */
  showNote(tabId: number, kind: ScanOutcome['kind']): Promise<boolean>;
  setBadge(text: string, title: string): Promise<void>;
}

export class Toolbar {
  constructor(
    private readonly deps: {
      browser: ToolbarBrowser;
      websiteUrl: string;
      scan(): Promise<ScanOutcome>;
      setTimeout?: (run: () => void, ms: number) => void;
    },
  ) {}

  /**
   * Each time the background starts: the menus again, as they are per browser session. A line the browser refuses
   * (Safari may, for the button's menu) is left out; the others stay.
   */
  async start(): Promise<void> {
    const { browser } = this.deps;
    try {
      await browser.removeAllMenus();
    } catch {
      return; // no menus in this browser
    }
    for (const item of MENU_ITEMS) await browser.createMenu(item).catch(() => undefined);
  }

  async menuClicked(id: string | number, tabId: number | undefined): Promise<void> {
    if (id === MENU_WEBSITE) {
      await this.deps.browser.openTab(this.deps.websiteUrl).catch(() => undefined);
    } else if (id === MENU_SCAN_ACTION || id === MENU_SCAN_PAGE) {
      await this.report(await this.deps.scan().catch((): ScanOutcome => ({ kind: 'none' })), tabId);
    }
  }

  /** Says why a scan handed nothing over. When it did, the app's window is the answer. */
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
