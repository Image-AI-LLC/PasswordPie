import { describe, expect, it } from 'vitest';
import type { Entitlement } from '../src/lib/account';
import type { ScanOutcome } from '../src/lib/scan-outcome';
import {
  BADGE_MS,
  MENU_ACCOUNT,
  MENU_SCAN_ACTION,
  MENU_SCAN_PAGE,
  MENU_WEBSITE,
  Toolbar,
  menuItems,
  premiumNow,
  type MenuItem,
  type ToolbarBrowser,
} from '../src/lib/toolbar';

const NOW = Date.parse('2026-11-11T00:00:00Z');
const POPUP = 'popup.html';

function entitlement(over: Partial<Entitlement> = {}): Entitlement {
  return { premium: true, plan: 'lifetime', expiresAt: null, token: 'signed', checkedAt: NOW, ...over } as Entitlement;
}

class FakeBrowser implements ToolbarBrowser {
  menus: MenuItem[] = [];
  /** Ids the browser refuses to add, as Safari may for the button's menu. */
  refuse = new Set<string>();
  noMenus = false;
  popup: string | undefined;
  popupOpens = 0;
  openPopupFails = false;
  tabs: string[] = [];
  notes: Array<{ tabId: number; kind: string }> = [];
  pageShowsNote = true;
  badges: Array<{ text: string; title: string }> = [];

  async removeAllMenus(): Promise<void> {
    if (this.noMenus) throw new Error('no menus');
    this.menus = [];
  }
  async createMenu(item: MenuItem): Promise<void> {
    if (this.noMenus || this.refuse.has(item.id)) throw new Error('refused');
    this.menus.push(item);
  }
  async setPopup(popup: string): Promise<void> {
    this.popup = popup;
  }
  async openPopup(): Promise<void> {
    if (this.openPopupFails) throw new Error('no window');
    this.popupOpens += 1;
  }
  async openTab(url: string): Promise<unknown> {
    this.tabs.push(url);
    return undefined;
  }
  async showNote(tabId: number, kind: ScanOutcome['kind']): Promise<boolean> {
    this.notes.push({ tabId, kind });
    return this.pageShowsNote;
  }
  async setBadge(text: string, title: string): Promise<void> {
    this.badges.push({ text, title });
  }
}

function make(options: { account?: { token?: string; entitlement?: Entitlement } | null; outcome?: ScanOutcome } = {}) {
  const browser = new FakeBrowser();
  const calls = { panel: 0, refresh: 0, scan: 0 };
  const timeouts: Array<{ run: () => void; ms: number }> = [];
  const held = options.account === null ? undefined : (options.account ?? {});
  const toolbar = new Toolbar({
    browser,
    popupPath: POPUP,
    popupUrl: 'chrome-extension://id/popup.html',
    websiteUrl: 'https://passwordpie.com/',
    ...(held
      ? { account: { sessionToken: async () => held.token, entitlement: async () => held.entitlement } }
      : {}),
    showPanel: async () => {
      calls.panel += 1;
    },
    refresh: async () => {
      calls.refresh += 1;
    },
    scan: async () => {
      calls.scan += 1;
      return options.outcome ?? { kind: 'none' };
    },
    now: () => NOW,
    setTimeout: (run, ms) => void timeouts.push({ run, ms }),
  });
  return { browser, toolbar, calls, timeouts, held };
}

describe('premiumNow', () => {
  it('needs a session and an entitlement that says premium', async () => {
    const at = (token: string | undefined, e: Entitlement | undefined) =>
      premiumNow({ sessionToken: async () => token, entitlement: async () => e }, NOW);
    expect(await at('s', entitlement())).toBe(true);
    expect(await at(undefined, entitlement())).toBe(false);
    expect(await at('s', undefined)).toBe(false);
    expect(await at('s', entitlement({ premium: false, token: null }))).toBe(false);
  });

  it('is over once the end date has passed', async () => {
    const at = (expiresAt: string) => premiumNow({ sessionToken: async () => 's', entitlement: async () => entitlement({ expiresAt }) }, NOW);
    expect(await at('2027-01-01T00:00:00Z')).toBe(true);
    expect(await at('2026-11-10T00:00:00Z')).toBe(false);
  });

  it('is not premium when the storage cannot be read', async () => {
    const broken = { sessionToken: async () => Promise.reject(new Error('x')), entitlement: async () => entitlement() };
    expect(await premiumNow(broken, NOW)).toBe(false);
  });
});

describe('menuItems', () => {
  it("puts scan, the website and the account in the button's menu, and scan in the page's", () => {
    const items = menuItems(true);
    expect(items.map((i) => [i.id, i.title, i.contexts])).toEqual([
      [MENU_SCAN_ACTION, 'Scan QR code on this page', ['action']],
      [MENU_WEBSITE, 'Open passwordpie.com', ['action']],
      [MENU_ACCOUNT, 'Account…', ['action']],
      [MENU_SCAN_PAGE, 'Scan QR code with PasswordPie', ['page', 'frame', 'image']],
    ]);
    expect(items.at(-1)?.documentUrlPatterns).toEqual(['http://*/*', 'https://*/*']);
  });

  it('has no Account line in the App Store build', () => {
    expect(menuItems(false).map((i) => i.id)).toEqual([MENU_SCAN_ACTION, MENU_WEBSITE, MENU_SCAN_PAGE]);
  });
});

describe('Toolbar: what a click on the button does', () => {
  it('keeps the popup while signed out', async () => {
    const { browser, toolbar } = make();
    await toolbar.start();
    expect(browser.popup).toBe(POPUP);
  });

  it('keeps the popup for a free account', async () => {
    const { browser, toolbar } = make({ account: { token: 's', entitlement: entitlement({ premium: false, token: null }) } });
    await toolbar.start();
    expect(browser.popup).toBe(POPUP);
  });

  it('opens PasswordPie directly once the account has Premium', async () => {
    const { browser, toolbar } = make({ account: { token: 's', entitlement: entitlement() } });
    await toolbar.start();
    expect(browser.popup).toBe('');
  });

  it('opens PasswordPie directly in the App Store build, which has no account', async () => {
    const { browser, toolbar } = make({ account: null });
    await toolbar.start();
    expect(browser.popup).toBe('');
    expect(browser.menus.map((m) => m.id)).toEqual([MENU_SCAN_ACTION, MENU_WEBSITE, MENU_SCAN_PAGE]);
  });

  it("keeps the popup when the browser cannot add to the button's menu: scan must stay in reach", async () => {
    for (const setup of [(b: FakeBrowser) => b.refuse.add(MENU_SCAN_ACTION), (b: FakeBrowser) => void (b.noMenus = true)]) {
      const { browser, toolbar } = make({ account: { token: 's', entitlement: entitlement() } });
      setup(browser);
      await toolbar.start();
      expect(browser.popup).toBe(POPUP);
    }
  });

  it('still opens directly when only the page menu was refused', async () => {
    const { browser, toolbar } = make({ account: { token: 's', entitlement: entitlement() } });
    browser.refuse.add(MENU_SCAN_PAGE);
    await toolbar.start();
    expect(browser.popup).toBe('');
  });

  it('brings the popup back after a sign-out, and drops it after Premium arrives', async () => {
    const { browser, toolbar, held } = make({ account: { token: 's', entitlement: entitlement() } });
    await toolbar.start();
    if (held) held.token = undefined;
    await toolbar.sync();
    expect(browser.popup).toBe(POPUP);
    if (held) held.token = 's';
    await toolbar.sync();
    expect(browser.popup).toBe('');
  });

  it('a direct click opens the panel and asks the site for Premium again', async () => {
    const { toolbar, calls } = make({ account: { token: 's', entitlement: entitlement() } });
    await toolbar.start();
    await toolbar.clicked();
    expect(calls).toEqual({ panel: 1, refresh: 1, scan: 0 });
  });

  it('a click still opens the panel when the site cannot be asked', async () => {
    const browser = new FakeBrowser();
    let panel = 0;
    const toolbar = new Toolbar({
      browser,
      popupPath: POPUP,
      popupUrl: 'x',
      websiteUrl: 'https://passwordpie.com/',
      showPanel: async () => void (panel += 1),
      refresh: () => Promise.reject(new Error('offline')),
      scan: async () => ({ kind: 'none' }),
    });
    await expect(toolbar.clicked()).resolves.toBeUndefined();
    expect(panel).toBe(1);
  });
});

describe('Toolbar: the menus', () => {
  it('Open passwordpie.com opens the website in a tab', async () => {
    const { browser, toolbar } = make();
    await toolbar.start();
    await toolbar.menuClicked(MENU_WEBSITE, 1);
    expect(browser.tabs).toEqual(['https://passwordpie.com/']);
  });

  it('Account… shows the popup even while the button opens PasswordPie, then leaves the button as it was', async () => {
    const { browser, toolbar } = make({ account: { token: 's', entitlement: entitlement() } });
    await toolbar.start();
    const seen: Array<string | undefined> = [];
    const open = browser.openPopup.bind(browser);
    browser.openPopup = async () => {
      seen.push(browser.popup);
      await open();
    };
    await toolbar.menuClicked(MENU_ACCOUNT, 1);
    expect(seen).toEqual([POPUP]);
    expect(browser.popupOpens).toBe(1);
    expect(browser.popup).toBe('');
    expect(browser.tabs).toEqual([]);
  });

  it('Account… opens the popup page in a tab when the browser cannot open the popup', async () => {
    const { browser, toolbar } = make({ account: { token: 's', entitlement: entitlement() } });
    browser.openPopupFails = true;
    await toolbar.start();
    await toolbar.menuClicked(MENU_ACCOUNT, 1);
    expect(browser.tabs).toEqual(['chrome-extension://id/popup.html']);
    expect(browser.popup).toBe('');
  });

  it('a scan that reached the app says nothing: its window is the answer', async () => {
    for (const id of [MENU_SCAN_ACTION, MENU_SCAN_PAGE]) {
      const { browser, toolbar, calls } = make({ outcome: { kind: 'sent', issuer: 'Demo', account: 'ada' } });
      await toolbar.menuClicked(id, 7);
      expect(calls.scan).toBe(1);
      expect(browser.notes).toEqual([]);
      expect(browser.badges).toEqual([]);
    }
  });

  it('a scan that found nothing says why in a note on the page', async () => {
    const { browser, toolbar } = make({ outcome: { kind: 'hotp' } });
    await toolbar.menuClicked(MENU_SCAN_PAGE, 7);
    expect(browser.notes).toEqual([{ tabId: 7, kind: 'hotp' }]);
    expect(browser.badges).toEqual([]);
  });

  it('marks the button when the page cannot show the note, and clears the mark', async () => {
    for (const tabId of [7, undefined]) {
      const { browser, toolbar, timeouts } = make({ outcome: { kind: 'no-page' } });
      browser.pageShowsNote = false;
      await toolbar.menuClicked(MENU_SCAN_ACTION, tabId);
      expect(browser.badges).toEqual([{ text: '!', title: 'PasswordPie: Open the page with the QR code first.' }]);
      expect(timeouts.map((t) => t.ms)).toEqual([BADGE_MS]);
      timeouts[0]?.run();
      expect(browser.badges.at(-1)).toEqual({ text: '', title: 'PasswordPie' });
    }
  });

  it('a scan that throws counts as nothing found', async () => {
    const browser = new FakeBrowser();
    const toolbar = new Toolbar({
      browser,
      popupPath: POPUP,
      popupUrl: 'x',
      websiteUrl: 'https://passwordpie.com/',
      showPanel: async () => undefined,
      scan: () => Promise.reject(new Error('x')),
    });
    await toolbar.menuClicked(MENU_SCAN_PAGE, 3);
    expect(browser.notes).toEqual([{ tabId: 3, kind: 'none' }]);
  });

  it('ignores a menu line it does not know', async () => {
    const { browser, toolbar, calls } = make();
    await toolbar.menuClicked('other', 1);
    expect(calls).toEqual({ panel: 0, refresh: 0, scan: 0 });
    expect(browser.tabs).toEqual([]);
  });
});
