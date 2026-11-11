import { describe, expect, it } from 'vitest';
import type { ScanOutcome } from '../src/lib/scan-outcome';
import {
  BADGE_MS,
  MENU_SCAN_ACTION,
  MENU_SCAN_PAGE,
  MENU_WEBSITE,
  Toolbar,
  menuItems,
  type MenuItem,
  type ToolbarBrowser,
} from '../src/lib/toolbar';

class FakeBrowser implements ToolbarBrowser {
  menus: MenuItem[] = [{ id: 'left-over', title: 'x', contexts: ['action'] }];
  /** Ids the browser refuses to add, as Safari may for the button's menu. */
  refuse = new Set<string>();
  noMenus = false;
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

function make(scan: () => Promise<ScanOutcome> = async () => ({ kind: 'none' })) {
  const browser = new FakeBrowser();
  const timeouts: Array<{ run: () => void; ms: number }> = [];
  let scans = 0;
  const toolbar = new Toolbar({
    browser,
    websiteUrl: 'https://passwordpie.com/',
    scan: () => {
      scans += 1;
      return scan();
    },
    setTimeout: (run, ms) => void timeouts.push({ run, ms }),
  });
  return { browser, toolbar, timeouts, scans: () => scans };
}

describe('the right-click menus', () => {
  it("puts scan and the website in the button's menu, and scan in the page's; nothing about an account", () => {
    expect(menuItems(true).map((i) => [i.id, i.title, i.contexts])).toEqual([
      [MENU_SCAN_ACTION, 'Scan QR code on this page', ['action']],
      [MENU_WEBSITE, 'Open passwordpie.com', ['action']],
      [MENU_SCAN_PAGE, 'Scan QR code with PasswordPie', ['page', 'frame', 'image']],
    ]);
    expect(menuItems(true).at(-1)?.documentUrlPatterns).toEqual(['http://*/*', 'https://*/*']);
  });

  it('the Safari build, which also ships in the App Store app, has no line that opens the site', async () => {
    expect(menuItems(false).map((i) => i.id)).toEqual([MENU_SCAN_ACTION, MENU_SCAN_PAGE]);
    const browser = new FakeBrowser();
    const toolbar = new Toolbar({ browser, scan: async () => ({ kind: 'none' }) });
    await toolbar.start();
    expect(browser.menus.map((m) => m.id)).toEqual([MENU_SCAN_ACTION, MENU_SCAN_PAGE]);
    await toolbar.menuClicked(MENU_WEBSITE, 1);
    expect(browser.tabs).toEqual([]);
  });

  it('adds them again at each start, in place of what was there', async () => {
    const { browser, toolbar } = make();
    await toolbar.start();
    await toolbar.start();
    expect(browser.menus.map((m) => m.id)).toEqual([MENU_SCAN_ACTION, MENU_WEBSITE, MENU_SCAN_PAGE]);
  });

  it("keeps the page's scan when the browser refuses the button's menu", async () => {
    const { browser, toolbar } = make();
    browser.refuse.add(MENU_SCAN_ACTION).add(MENU_WEBSITE);
    await toolbar.start();
    expect(browser.menus.map((m) => m.id)).toEqual([MENU_SCAN_PAGE]);
  });

  it('does nothing in a browser without menus', async () => {
    const { browser, toolbar } = make();
    browser.noMenus = true;
    await expect(toolbar.start()).resolves.toBeUndefined();
  });

  it('Open passwordpie.com opens the website in a tab', async () => {
    const { browser, toolbar, scans } = make();
    await toolbar.menuClicked(MENU_WEBSITE, 1);
    expect(browser.tabs).toEqual(['https://passwordpie.com/']);
    expect(scans()).toBe(0);
  });

  it('a scan that reached the app says nothing: its window is the answer', async () => {
    for (const id of [MENU_SCAN_ACTION, MENU_SCAN_PAGE]) {
      const { browser, toolbar, scans } = make(async () => ({ kind: 'sent' }));
      await toolbar.menuClicked(id, 7);
      expect(scans()).toBe(1);
      expect(browser.notes).toEqual([]);
      expect(browser.badges).toEqual([]);
    }
  });

  it('a scan that found nothing says why in a note on the page', async () => {
    const { browser, toolbar } = make(async () => ({ kind: 'hotp' }));
    await toolbar.menuClicked(MENU_SCAN_PAGE, 7);
    expect(browser.notes).toEqual([{ tabId: 7, kind: 'hotp' }]);
    expect(browser.badges).toEqual([]);
  });

  it('marks the button when the page cannot show the note, and clears the mark', async () => {
    for (const tabId of [7, undefined]) {
      const { browser, toolbar, timeouts } = make(async () => ({ kind: 'no-page' }));
      browser.pageShowsNote = false;
      await toolbar.menuClicked(MENU_SCAN_ACTION, tabId);
      expect(browser.badges).toEqual([{ text: '!', title: 'PasswordPie: Open the page with the QR code first.' }]);
      expect(timeouts.map((t) => t.ms)).toEqual([BADGE_MS]);
      timeouts[0]?.run();
      expect(browser.badges.at(-1)).toEqual({ text: '', title: 'PasswordPie' });
    }
  });

  it('the timer of an older mark never clears a newer one', async () => {
    const { browser, toolbar, timeouts } = make(async () => ({ kind: 'no-page' }));
    browser.pageShowsNote = false;
    await toolbar.menuClicked(MENU_SCAN_ACTION, undefined);
    await toolbar.menuClicked(MENU_SCAN_ACTION, undefined);
    timeouts[0]?.run();
    expect(browser.badges.at(-1)?.text).toBe('!');
    timeouts[1]?.run();
    expect(browser.badges.at(-1)).toEqual({ text: '', title: 'PasswordPie' });
  });

  it('a scan that throws counts as nothing found', async () => {
    const { browser, toolbar } = make(() => Promise.reject(new Error('x')));
    await toolbar.menuClicked(MENU_SCAN_PAGE, 3);
    expect(browser.notes).toEqual([{ tabId: 3, kind: 'none' }]);
  });

  it('ignores a menu line it does not know', async () => {
    const { browser, toolbar, scans } = make();
    await toolbar.menuClicked('other', 1);
    expect(scans()).toBe(0);
    expect(browser.tabs).toEqual([]);
  });
});
