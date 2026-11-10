import { browser } from 'wxt/browser';
import { defineBackground } from 'wxt/utils/define-background';
import { AccountStore, refreshEntitlement } from '@/lib/account';
import { storageKV } from '@/lib/browser-kv';
import { SITE_URL, UPGRADE_URL } from '@/lib/config';
import { FillController, type TabsAdapter } from '@/lib/controller';
import { ChromeNativeChannel, SafariNativeChannel, type NativeChannel, type PortLike } from '@/lib/native-channel';
import { PassRelay, relayKeysChanged } from '@/lib/pass-relay';
import { NATIVE_APP, originOf, parsePopupMessage } from '@/lib/protocol';
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

  browser.tabs.onActivated.addListener(() => controller.tabActivated());
  browser.tabs.onUpdated.addListener((tabId, change, tab) => controller.tabUpdated(tabId, change, tab));
  browser.tabs.onRemoved.addListener((tabId) => controller.tabRemoved(tabId));
  browser.windows.onFocusChanged.addListener((windowId) => controller.windowFocusChanged(windowId));
  browser.runtime.onMessage.addListener((msg: unknown, sender, sendResponse: (answer: unknown) => void) => {
    // Only the extension's own pages (the popup) may ask for these; a content script's sender URL is the web page's.
    const fromExtensionPage = sender.id === browser.runtime.id && (sender.url ?? '').startsWith(browser.runtime.getURL('/'));
    const popup = fromExtensionPage ? parsePopupMessage(msg) : undefined;
    if (popup?.type === 'open-panel') {
      controller.showPanel().catch(() => {});
      sendResponse(true);
    } else if (popup?.type === 'popup-status') {
      sendResponse(controller.popupStatus());
    } else if (popup?.type === 'app-premium') {
      controller.appPremium().then(sendResponse, () => sendResponse('none'));
      return true; // answers later
    } else {
      controller.runtimeMessage(msg, sender);
    }
    return false;
  });
  // The toolbar button opens the popup, whose first button opens the panel. The shortcut opens it directly.
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
      if (relayKeysChanged(changes, area)) void relay.sync();
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
});
