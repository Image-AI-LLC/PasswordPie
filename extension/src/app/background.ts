import { browser } from 'wxt/browser';
import { defineBackground } from 'wxt/utils/define-background';
import { FillController, type TabsAdapter } from '@/lib/controller';
import { ChromeNativeChannel, SafariNativeChannel, SHOW_TIMEOUT_MS, type NativeChannel, type PortLike } from '@/lib/native-channel';
import type { ScanNoteMessage } from '@/lib/page-note';
import { NATIVE_APP, WEBSITE_URL, originOf } from '@/lib/protocol';
import { type QrImagesMessage } from '@/lib/qr-page';
import { decodeQrDataUrl, scanActiveTab, type ScanDeps } from '@/lib/qr-scan';
import { Toolbar, type ToolbarBrowser } from '@/lib/toolbar';
import { iconCandidates, offscreenGraphics, parseIconLinks, tabIconPng, type IconLinksMessage } from '@/lib/site-icon';

const RECONNECT_ALARM = 'passwordpie-reconnect';
/** The keyboard shortcut for the panel (manifest `commands`). It does what a click on the toolbar button does. */
const OPEN_PANEL_COMMAND = 'open-panel'; // manifest.ts commands

function connectNative(): PortLike {
  const port = browser.runtime.connectNative(NATIVE_APP);
  // Read lastError so a missing host is not reported as an unchecked error.
  port.onDisconnect.addListener(() => void browser.runtime.lastError);
  return port;
}

function makeChannel(): NativeChannel {
  if (import.meta.env.BROWSER === 'safari') {
    return new SafariNativeChannel((msg) => browser.runtime.sendNativeMessage(NATIVE_APP, msg), connectNative);
  }
  return new ChromeNativeChannel(connectNative);
}

const tabs: TabsAdapter = {
  async activeTab() {
    const [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
    return tab;
  },
  async frames(tabId) {
    const frames = await browser.webNavigation.getAllFrames({ tabId });
    return (frames ?? []).map((frame) => ({ frameId: frame.frameId, url: frame.url }));
  },
  sendFill(tabId, frameId, msg) {
    return browser.tabs.sendMessage(tabId, msg, { frameId });
  },
  sendToFrame(tabId, frameId, msg) {
    return browser.tabs.sendMessage(tabId, msg, { frameId });
  },
  openTab(url) {
    return browser.tabs.create({ url });
  },
  async tabIcon(tabId, _reportedFavIconUrl, origin) {
    // Read the tab again: after a navigation, the icon from the report can still be the previous page's.
    const tab = await browser.tabs.get(tabId).catch(() => undefined);
    if (!tab?.url || originOf(tab.url) !== origin) return undefined;
    const favIconUrl = tab.status === 'complete' ? tab.favIconUrl : undefined;
    const ask: IconLinksMessage = { type: 'icon-links', origin };
    const links = parseIconLinks(await browser.tabs.sendMessage(tabId, ask, { frameId: 0 }).catch(() => []));
    return tabIconPng(iconCandidates(origin, favIconUrl, links), { fetch: (url, init) => fetch(url, init), graphics: offscreenGraphics });
  },
};

/** The browser side of a scan. Pictures stay in memory; the link goes only to the app. */
function scanDeps(channel: NativeChannel): ScanDeps {
  return {
    async activeTab() {
      const [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
      return tab;
    },
    pageImages(tabId) {
      const ask: QrImagesMessage = { type: 'qr-images' };
      return browser.tabs.sendMessage(tabId, ask, { frameId: 0 });
    },
    async captureVisibleTab(windowId) {
      // Safari may not allow it; the page's own pictures were tried first.
      return windowId === undefined
        ? await browser.tabs.captureVisibleTab({ format: 'png' })
        : await browser.tabs.captureVisibleTab(windowId, { format: 'png' });
    },
    decode: decodeQrDataUrl,
    sendScan(otpauth, url) {
      return channel.request({ type: 'scan', otpauth, url });
    },
    async startApp() {
      const answer: unknown = await channel.request({ type: 'show' }, SHOW_TIMEOUT_MS);
      return typeof answer === 'object' && answer !== null && 'type' in answer && answer.type === 'show';
    },
  };
}

/** The button's menu and the page's menu (toolbar.ts). Each rejects where the browser has no such API. */
const toolbarBrowser: ToolbarBrowser = {
  async removeAllMenus() {
    await browser.contextMenus.removeAll();
  },
  createMenu(item) {
    return new Promise((resolve, reject) => {
      browser.contextMenus.create(item as Parameters<typeof browser.contextMenus.create>[0], () => {
        const error = browser.runtime.lastError;
        if (error) reject(new Error(error.message));
        else resolve();
      });
    });
  },
  openTab(url) {
    return browser.tabs.create({ url });
  },
  async showNote(tabId, kind) {
    const note: ScanNoteMessage = { type: 'scan-note', kind };
    return (await browser.tabs.sendMessage(tabId, note, { frameId: 0 })) === true;
  },
  async setBadge(text, title) {
    await Promise.all([browser.action.setBadgeText({ text }), browser.action.setTitle({ title })]);
  },
};

export default defineBackground(() => {
  const channel = makeChannel();
  // The extension is a bridge to the app and keeps nothing: no sign-in, no session, no `storage` (docs/UX.md).
  const controller = new FillController({ channel, tabs });
  const toolbar = new Toolbar({
    browser: toolbarBrowser,
    websiteUrl: WEBSITE_URL,
    scan: () => scanActiveTab(scanDeps(channel)),
  });

  // The toolbar button shows nothing of its own: a click opens the app's panel, as the shortcut does.
  browser.action.onClicked.addListener(() => void controller.showPanel().catch(() => {}));
  browser.commands?.onCommand.addListener((command) => {
    if (command === OPEN_PANEL_COMMAND) controller.showPanel().catch(() => {});
  });
  browser.contextMenus?.onClicked.addListener((info, tab) => void toolbar.menuClicked(info.menuItemId, tab?.id));

  browser.tabs.onActivated.addListener(() => controller.tabActivated());
  browser.tabs.onUpdated.addListener((tabId, change, tab) => controller.tabUpdated(tabId, change, tab));
  browser.tabs.onRemoved.addListener((tabId) => controller.tabRemoved(tabId));
  browser.windows.onFocusChanged.addListener((windowId) => controller.windowFocusChanged(windowId));
  // Content scripts only: there is no extension page to send anything.
  browser.runtime.onMessage.addListener((msg: unknown, sender) => {
    controller.runtimeMessage(msg, sender);
    return false;
  });
  browser.runtime.onInstalled.addListener(() => controller.report('startup'));
  browser.runtime.onStartup.addListener(() => controller.report('startup'));

  // The service worker may have been restarted, or the host gone; check the port every minute.
  void browser.alarms.create(RECONNECT_ALARM, { periodInMinutes: 1 });
  browser.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === RECONNECT_ALARM) channel.ensureConnected();
  });

  controller.start();
  void toolbar.start();
});
