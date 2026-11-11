import { browser } from 'wxt/browser';
import { defineBackground } from 'wxt/utils/define-background';
import { AccountStore, refreshEntitlement } from '@/lib/account';
import { storageKV } from '@/lib/browser-kv';
import { SITE_URL, UPGRADE_URL } from '@/lib/config';
import { FillController, type TabsAdapter } from '@/lib/controller';
import { ChromeNativeChannel, SafariNativeChannel, SHOW_TIMEOUT_MS, type NativeChannel, type PortLike } from '@/lib/native-channel';
import type { ScanNoteMessage } from '@/lib/page-note';
import { PassRelay, relayKeysChanged } from '@/lib/pass-relay';
import { NATIVE_APP, WEBSITE_URL, originOf, parsePopupMessage } from '@/lib/protocol';
import { type QrImagesMessage } from '@/lib/qr-page';
import { decodeQrDataUrl, scanActiveTab, type ScanDeps } from '@/lib/qr-scan';
import { parseSiteSessionMessage } from '@/lib/site-connect';
import { acceptSiteSession, fromConnectPage } from '@/lib/site-session';
import { Toolbar, type ToolbarBrowser } from '@/lib/toolbar';
import { iconCandidates, offscreenGraphics, parseIconLinks, tabIconPng, type IconLinksMessage } from '@/lib/site-icon';

const RECONNECT_ALARM = 'passwordpie-reconnect';
const ENTITLEMENT_ALARM = 'passwordpie-entitlement';
/** The keyboard shortcut for the panel (manifest `commands`): the toolbar button opens the popup now. */
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

/** The browser side of "Scan QR code on this page". Pictures stay in memory; the link goes only to the app. */
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

/** The popup page (src/app/popup). */
const POPUP_PATH = 'popup.html';

/** The button, its menu and the page's menu (toolbar.ts). Each rejects where the browser has no such API. */
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
  async setPopup(popup) {
    await browser.action.setPopup({ popup });
  },
  async openPopup() {
    await browser.action.openPopup();
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
  // Spelled out so Vite folds it: the App Store build has no account and sends the site nothing (docs/ACCOUNTS.md).
  const account = import.meta.env.WXT_PP_STORE === 'mas' ? undefined : new AccountStore(storageKV(browser.storage.local));
  // The app has no sign-in: this hands it the account's pass, and takes it back on sign-out (docs/BROWSER_EXTENSION.md).
  const relay =
    import.meta.env.WXT_PP_STORE === 'mas' || !account
      ? undefined
      : new PassRelay({ channel, account, kv: storageKV(browser.storage.local) });
  const controller = new FillController({
    channel,
    tabs,
    ...(account ? { account } : {}),
    ...(relay ? { relay } : {}),
    ...(UPGRADE_URL ? { upgradeUrl: UPGRADE_URL } : {}),
  });

  const toolbar = new Toolbar({
    browser: toolbarBrowser,
    popupPath: POPUP_PATH,
    popupUrl: browser.runtime.getURL(`/${POPUP_PATH}`),
    websiteUrl: WEBSITE_URL,
    showPanel: () => controller.showPanel(),
    scan: () => scanActiveTab(scanDeps(channel)),
    // Spelled out so Vite folds it: the App Store build asks the site nothing.
    ...(import.meta.env.WXT_PP_STORE !== 'mas' && account
      ? { account, refresh: () => refreshEntitlement(account, fetch, SITE_URL) }
      : {}),
  });
  // Fires only while the button has no popup: the account has Premium, or the build has no account.
  browser.action.onClicked.addListener(() => void toolbar.clicked());
  browser.contextMenus?.onClicked.addListener((info, tab) => void toolbar.menuClicked(info.menuItemId, tab?.id));

  browser.tabs.onActivated.addListener(() => controller.tabActivated());
  browser.tabs.onUpdated.addListener((tabId, change, tab) => controller.tabUpdated(tabId, change, tab));
  browser.tabs.onRemoved.addListener((tabId) => controller.tabRemoved(tabId));
  browser.windows.onFocusChanged.addListener((windowId) => controller.windowFocusChanged(windowId));
  browser.runtime.onMessage.addListener((msg: unknown, sender, sendResponse: (answer: unknown) => void) => {
    // The site's connect page handing over a session (signing in on passwordpie.com). Spelled out so Vite folds it:
    // not in the App Store build.
    if (import.meta.env.WXT_PP_STORE !== 'mas' && account) {
      const session = parseSiteSessionMessage(msg);
      if (session) {
        if (!fromConnectPage(sender, browser.runtime.id, SITE_URL)) {
          sendResponse({ ok: false });
          return false;
        }
        const accountChanged = relay ? () => relay.sync() : undefined;
        acceptSiteSession(session.token, account, fetch, SITE_URL, accountChanged ? { accountChanged } : {}).then(
          sendResponse,
          () => sendResponse({ ok: false }),
        );
        return true; // answers later
      }
    }
    // Only the extension's own pages (the popup) may ask for these; a content script's sender URL is the web page's.
    const fromExtensionPage = sender.id === browser.runtime.id && (sender.url ?? '').startsWith(browser.runtime.getURL('/'));
    const popup = fromExtensionPage ? parsePopupMessage(msg) : undefined;
    if (popup?.type === 'open-panel') {
      controller.showPanel().catch(() => {});
      sendResponse(true);
    } else if (popup?.type === 'popup-status') {
      sendResponse(controller.popupStatus());
    } else if (popup?.type === 'scan-page') {
      scanActiveTab(scanDeps(channel)).then(sendResponse, () => sendResponse({ kind: 'none' }));
      return true; // answers later
    } else if (popup?.type === 'app-premium') {
      controller.appPremium().then(sendResponse, () => sendResponse('none'));
      return true; // answers later
    } else {
      controller.runtimeMessage(msg, sender);
    }
    return false;
  });
  // The toolbar button opens the popup, whose first button opens the panel, or the panel itself (toolbar.ts). The
  // shortcut always opens the panel.
  browser.commands?.onCommand.addListener((command) => {
    if (command === OPEN_PANEL_COMMAND) controller.showPanel().catch(() => {});
  });
  browser.runtime.onInstalled.addListener(() => controller.report('startup'));
  browser.runtime.onStartup.addListener(() => controller.report('startup'));

  // The service worker may have been restarted, or the host gone; check the port every minute.
  void browser.alarms.create(RECONNECT_ALARM, { periodInMinutes: 1 });
  browser.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === RECONNECT_ALARM) channel.ensureConnected();
  });

  if (import.meta.env.WXT_PP_STORE !== 'mas' && relay) {
    // Sign-in, sign-out, a renewal from the popup or the alarm, and a 401 all land in storage: tell the app each time.
    browser.storage.onChanged.addListener((changes, area) => {
      if (!relayKeysChanged(changes, area)) return;
      void relay.sync();
      void toolbar.sync();
    });
  }

  if (import.meta.env.WXT_PP_STORE !== 'mas' && account) {
    // The entitlement once a day (and each time the popup opens), so the token the app checks stays fresh.
    // Only when it is not scheduled yet: create() replaces an alarm of the same name, and this runs on every service-worker
    // start, which would push the refresh back each time.
    void browser.alarms.get(ENTITLEMENT_ALARM).then((existing) => {
      if (!existing) void browser.alarms.create(ENTITLEMENT_ALARM, { periodInMinutes: 24 * 60, delayInMinutes: 1 });
    });
    browser.alarms.onAlarm.addListener((alarm) => {
      if (alarm.name === ENTITLEMENT_ALARM) void refreshEntitlement(account, fetch, SITE_URL).catch(() => undefined);
    });
  }

  controller.start();
  void toolbar.start();
});
