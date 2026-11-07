import { browser } from 'wxt/browser';
import { defineBackground } from 'wxt/utils/define-background';
import { FillController, type TabsAdapter } from '@/lib/controller';
import { ChromeNativeChannel, SafariNativeChannel, type NativeChannel, type PortLike } from '@/lib/native-channel';
import { NATIVE_APP } from '@/lib/protocol';

const RECONNECT_ALARM = 'passwordpie-reconnect';

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
};

export default defineBackground(() => {
  const channel = makeChannel();
  const controller = new FillController({ channel, tabs });

  browser.tabs.onActivated.addListener(() => controller.tabActivated());
  browser.tabs.onUpdated.addListener((tabId, change, tab) => controller.tabUpdated(tabId, change, tab));
  browser.tabs.onRemoved.addListener((tabId) => controller.tabRemoved(tabId));
  browser.windows.onFocusChanged.addListener((windowId) => controller.windowFocusChanged(windowId));
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
});
