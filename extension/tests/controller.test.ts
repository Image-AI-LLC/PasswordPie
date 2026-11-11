import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FillController, UPGRADE_WINDOW_MS } from '../src/lib/controller';
import { FakeChannel, FakeTabs } from './fakes';

const FILL = { origin: 'https://example.com', username: 'octocat', password: 's3cret' };

let channel: FakeChannel;
let tabs: FakeTabs;
let controller: FillController;

function answerWithFill(): void {
  // FakeChannel stands in for the channel, which matches ids; the controller sees only the answer.
  channel.answer = (msg) => (msg.type === 'tab' ? { type: 'tab', id: 1, fill: FILL } : { type: 'hello', id: 1, version: 1, locked: false });
}

async function settle(ms = 100): Promise<void> {
  await vi.advanceTimersByTimeAsync(ms);
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });
  channel = new FakeChannel();
  tabs = new FakeTabs();
  controller = new FillController({ channel, tabs });
});

afterEach(() => {
  vi.useRealTimers();
});

describe('FillController reports', () => {
  it('says hello and reports the active tab on startup', async () => {
    controller.start();
    await settle();
    expect(channel.sent[0]).toEqual({ type: 'hello', version: 1, extension: '0.3.0' });
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/', reason: 'startup' }]);
  });

  it('reports non-http(s) URLs as ""', async () => {
    for (const url of ['chrome://newtab/', 'file:///etc/passwd', 'about:blank', 'javascript:alert(1)', 'not a url']) {
      tabs.active = { id: 1, url, active: true };
      controller.report('activated');
      await settle();
    }
    tabs.active = { id: 1, url: undefined, active: true };
    controller.report('activated');
    await settle();
    expect(channel.tabReports().map((r) => r.url)).toEqual(['', '', '', '', '', '']);
  });

  it('reports only the origin: no path, query or fragment leaves the browser', async () => {
    tabs.active = { id: 1, url: 'https://example.com:8443/reset?token=s3cret#frag', active: true };
    controller.report('activated');
    await settle();
    expect(channel.tabReports().map((r) => r.url)).toEqual(['https://example.com:8443/']);
  });

  it('reports the tab on a poke', async () => {
    controller.start();
    await settle();
    channel.sent = [];
    channel.events?.onPoke();
    await settle();
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/', reason: 'poke' }]);
  });

  it('debounces bursts of events into one report', async () => {
    controller.tabActivated();
    controller.tabUpdated(1, { status: 'complete' }, { id: 1, url: 'https://example.com/login', active: true });
    controller.windowFocusChanged(7);
    await settle(50);
    expect(channel.tabReports()).toHaveLength(0);
    await settle(60);
    expect(channel.tabReports()).toHaveLength(1);
  });

  it('reports on tab updates of the active tab only, when complete or the URL changes', async () => {
    controller.tabUpdated(2, { status: 'complete' }, { id: 2, url: 'https://other.com/', active: false });
    await settle();
    controller.tabUpdated(1, { status: 'loading' }, { id: 1, url: 'https://example.com/login', active: true });
    await settle();
    expect(channel.tabReports()).toHaveLength(0);
    controller.tabUpdated(1, { url: 'https://example.com/next' }, { id: 1, url: 'https://example.com/next', active: true });
    await settle();
    controller.tabUpdated(1, { status: 'complete' }, { id: 1, url: 'https://example.com/next', active: true });
    await settle();
    expect(channel.tabReports().map((r) => r.reason)).toEqual(['updated', 'updated']);
  });

  it('ignores focus changes to no window', async () => {
    controller.windowFocusChanged(-1);
    await settle();
    expect(channel.tabReports()).toHaveLength(0);
    controller.windowFocusChanged(3);
    await settle();
    expect(channel.tabReports().map((r) => r.reason)).toEqual(['focus']);
  });

  it('accepts focus messages only from the top frame of an active tab', async () => {
    controller.runtimeMessage({ type: 'focus' }, { tab: { id: 1, active: true }, frameId: 2 });
    controller.runtimeMessage({ type: 'focus' }, { tab: { id: 5, active: false }, frameId: 0 });
    controller.runtimeMessage({ type: 'focus' }, { frameId: 0 });
    await settle();
    expect(channel.tabReports()).toHaveLength(0);
    controller.runtimeMessage({ type: 'focus' }, { tab: { id: 1, active: true }, frameId: 0 });
    await settle();
    expect(channel.tabReports().map((r) => r.reason)).toEqual(['focus']);
  });
});

describe('FillController toolbar button', () => {
  it('asks the app to show its panel, and sends nothing else', async () => {
    channel.answer = () => ({ type: 'show', id: 1 });
    await controller.showPanel();
    expect(channel.sent).toEqual([{ type: 'show' }]);
    expect(tabs.opened).toEqual([]);
  });

  it('opens the website when no app answers: PasswordPie is not installed', async () => {
    channel.answer = () => undefined;
    await controller.showPanel();
    expect(tabs.opened).toEqual(['https://passwordpie.com/']);
  });

  it('does not send a user whose app runs but did not answer to the website', async () => {
    channel.answer = () => ({ type: 'error', id: 1, code: 'app-not-responding' });
    await controller.showPanel();
    expect(tabs.opened).toEqual([]);
  });

  it('opens the website for any other answer', async () => {
    channel.answer = () => ({ type: 'tab', id: 1 });
    await controller.showPanel();
    expect(tabs.opened).toEqual(['https://passwordpie.com/']);
  });

  it('opens the website when the app could not be started', async () => {
    channel.answer = () => ({ type: 'error', id: 1, code: 'app-unavailable' });
    await controller.showPanel();
    expect(tabs.opened).toEqual(['https://passwordpie.com/']);
  });
});

describe('FillController fills', () => {
  it('sends the fill to the top frame and same-origin frames only', async () => {
    answerWithFill();
    tabs.framesByTab.set(1, [
      { frameId: 0, url: 'https://example.com/login' },
      { frameId: 4, url: 'https://ads.evil.example/frame' },
      { frameId: 5, url: 'https://example.com/embedded-login' },
      { frameId: 6, url: 'http://example.com/login' },
      { frameId: 7, url: 'about:blank' },
      { frameId: 8, url: 'https://login.example.com/' },
    ]);
    tabs.frameAnswer = () => ({ username: false, password: false });
    controller.report('poke');
    await settle();
    expect(tabs.fills.map((f) => f.frameId)).toEqual([0, 5]);
    expect(tabs.fills[0]).toEqual({ tabId: 1, frameId: 0, msg: { type: 'fill', ...FILL, waitMs: 30_000 } });
  });

  it('drops the entry once a frame filled the password', async () => {
    answerWithFill();
    controller.report('poke');
    await settle();
    expect(tabs.fills).toHaveLength(1);
    expect(controller.hasEntry(1)).toBe(false);
    controller.tabUpdated(1, { status: 'complete' }, { id: 1, url: 'https://example.com/login', active: false });
    await settle();
    expect(tabs.fills).toHaveLength(1);
  });

  it('two-step across a navigation: the next page of the same origin gets the password', async () => {
    answerWithFill();
    tabs.frameAnswer = () => ({ username: true, password: false });
    controller.report('poke');
    await settle();
    expect(tabs.fills).toHaveLength(1);
    expect(controller.hasEntry(1)).toBe(true);

    // a page of another origin in between does not get it
    controller.tabUpdated(1, { status: 'complete' }, { id: 1, url: 'https://sso.other.com/', active: false });
    await settle();
    expect(tabs.fills).toHaveLength(1);

    tabs.framesByTab.set(1, [{ frameId: 0, url: 'https://example.com/password' }]);
    tabs.frameAnswer = () => ({ username: false, password: true });
    controller.tabUpdated(1, { status: 'complete' }, { id: 1, url: 'https://example.com/password', active: false });
    await settle();
    expect(tabs.fills).toHaveLength(2);
    expect(tabs.fills[1]?.msg.password).toBe('s3cret');
    expect(controller.hasEntry(1)).toBe(false);
  });

  it('drops the entry when the content script says the password filled later', async () => {
    answerWithFill();
    tabs.frameAnswer = () => ({ username: true, password: false });
    controller.report('poke');
    await settle();
    controller.runtimeMessage({ type: 'filled', password: true }, { tab: { id: 1, active: true }, frameId: 0 });
    expect(controller.hasEntry(1)).toBe(false);
  });

  it('never fills from an expired entry', async () => {
    answerWithFill();
    tabs.frameAnswer = () => ({ username: true, password: false });
    controller.report('poke');
    await settle();
    await vi.advanceTimersByTimeAsync(30_001);
    expect(controller.hasEntry(1)).toBe(false);
    controller.tabUpdated(1, { status: 'complete' }, { id: 1, url: 'https://example.com/password', active: false });
    await settle();
    expect(tabs.fills).toHaveLength(1);
  });

  it('keeps the fill no longer than the app says is left of its 30 s', async () => {
    channel.answer = (msg) =>
      msg.type === 'tab' ? { type: 'tab', id: 1, fill: { ...FILL, expiresIn: 5 } } : { type: 'hello', id: 1, version: 1, locked: false };
    tabs.frameAnswer = () => ({ username: true, password: false });
    controller.report('poke');
    await settle();
    expect(controller.hasEntry(1)).toBe(true);
    await vi.advanceTimersByTimeAsync(5_001);
    expect(controller.hasEntry(1)).toBe(false);
  });

  it('never keeps a fill longer than 30 s, whatever the answer says', async () => {
    channel.answer = (msg) =>
      msg.type === 'tab' ? { type: 'tab', id: 1, fill: { ...FILL, expiresIn: 3600 } } : { type: 'hello', id: 1, version: 1, locked: false };
    tabs.frameAnswer = () => ({ username: true, password: false });
    controller.report('poke');
    await settle();
    await vi.advanceTimersByTimeAsync(30_001);
    expect(controller.hasEntry(1)).toBe(false);
  });

  it('checks expiry by the clock even if the timer has not run', async () => {
    answerWithFill();
    tabs.frameAnswer = () => ({ username: true, password: false });
    controller.report('poke');
    await settle();
    vi.setSystemTime(Date.now() + 31_000); // the clock jumps (e.g. the Mac slept), timers have not fired
    controller.tabUpdated(1, { status: 'complete' }, { id: 1, url: 'https://example.com/password', active: false });
    await settle(0);
    expect(tabs.fills).toHaveLength(1);
  });

  it('drops the entry when the tab closes', async () => {
    answerWithFill();
    tabs.frameAnswer = () => ({ username: true, password: false });
    controller.report('poke');
    await settle();
    controller.tabRemoved(1);
    expect(controller.hasEntry(1)).toBe(false);
  });

  it('fills the tab the report named, even if another tab is active by the time the answer arrives', async () => {
    let release: () => void = () => {};
    channel.answer = () =>
      new Promise((resolve) => {
        release = () => resolve({ type: 'tab', id: 1, fill: FILL });
      });
    tabs.framesByTab.set(1, [{ frameId: 0, url: 'https://example.com/login' }]);
    tabs.framesByTab.set(2, [{ frameId: 0, url: 'https://example.com/other' }]);
    controller.report('poke');
    await settle();
    tabs.active = { id: 2, url: 'https://example.com/other', active: true };
    release();
    await settle(0);
    expect(tabs.fills.map((f) => f.tabId)).toEqual([1]);
  });

  it('ignores a fill whose origin is not the reported URL\'s origin', async () => {
    channel.answer = () => ({ type: 'tab', id: 1, fill: { ...FILL, origin: 'https://evil.example' } });
    tabs.framesByTab.set(1, [{ frameId: 0, url: 'https://evil.example/' }]);
    controller.report('poke');
    await settle();
    expect(tabs.fills).toHaveLength(0);
    expect(controller.hasEntry(1)).toBe(false);
  });

  it('treats errors, empty answers and timeouts as no fill', async () => {
    for (const answer of [{ type: 'error', id: 1, code: 'app-unavailable' }, { type: 'tab', id: 1 }, undefined, { type: 'tab', id: 1, fill: { origin: 'https://example.com' } }]) {
      channel.answer = () => answer;
      controller.report('poke');
      await settle();
    }
    expect(tabs.fills).toHaveLength(0);
  });

  it('fills a frame whose content script starts after the answer arrived, if its origin matches', async () => {
    answerWithFill();
    tabs.framesByTab.set(1, [
      { frameId: 0, url: 'https://example.com/login' },
      { frameId: 3, url: 'https://ads.evil.example/' },
    ]);
    tabs.frameAnswer = () => undefined; // no content script yet
    controller.report('poke');
    await settle();
    expect(tabs.fills.map((f) => f.frameId)).toEqual([0]);
    expect(controller.hasEntry(1)).toBe(true);

    tabs.frameAnswer = () => ({ username: true, password: true });
    controller.runtimeMessage({ type: 'ready' }, { tab: { id: 1 }, frameId: 3 });
    await settle(0);
    expect(tabs.fills.map((f) => f.frameId)).toEqual([0]); // cross-origin frame: nothing
    controller.runtimeMessage({ type: 'ready' }, { tab: { id: 1 }, frameId: 0 });
    await settle(0);
    expect(tabs.fills.map((f) => f.frameId)).toEqual([0, 0]);
    expect(controller.hasEntry(1)).toBe(false);
  });

  it('never fills a non-http(s) tab', async () => {
    answerWithFill();
    tabs.active = { id: 1, url: 'chrome://settings/', active: true };
    controller.report('poke');
    await settle();
    expect(tabs.fills).toHaveLength(0);
  });
});

describe('FillController site icons', () => {
  function iconRequests() {
    return channel.sent.filter((m) => m.type === 'icon');
  }

  it('sends the tab icon when the app asks for it', async () => {
    tabs.active = { id: 7, url: 'https://news.example.com/item?id=1', active: true, favIconUrl: 'https://news.example.com/y18.svg' };
    channel.answer = (msg) => (msg.type === 'tab' ? { type: 'tab', id: 1, wantIcon: true } : { type: 'icon', id: 2 });
    controller.report('activated');
    await settle();
    expect(tabs.iconAsks).toEqual([{ tabId: 7, favIconUrl: 'https://news.example.com/y18.svg', origin: 'https://news.example.com' }]);
    expect(iconRequests()).toEqual([{ type: 'icon', origin: 'https://news.example.com', png: 'iVBORw0KGgo=' }]);
  });

  it('sends nothing when the app does not ask', async () => {
    channel.answer = () => ({ type: 'tab', id: 1 });
    controller.report('activated');
    await settle();
    expect(tabs.iconAsks).toEqual([]);
    expect(iconRequests()).toEqual([]);
  });

  it('sends nothing when no icon could be made, or for a page that is not http(s)', async () => {
    tabs.iconPng = undefined;
    channel.answer = () => ({ type: 'tab', id: 1, wantIcon: true });
    controller.report('activated');
    await settle();
    expect(iconRequests()).toEqual([]);

    tabs.iconPng = 'iVBORw0KGgo=';
    tabs.active = { id: 1, url: 'chrome://settings/', active: true };
    controller.report('activated');
    await settle();
    expect(iconRequests()).toEqual([]);
  });

  it('still fills when the same answer asks for the icon', async () => {
    channel.answer = (msg) => (msg.type === 'tab' ? { type: 'tab', id: 1, fill: FILL, wantIcon: true } : { type: 'icon', id: 2 });
    controller.report('activated');
    await settle();
    expect(tabs.fills).toHaveLength(1);
    expect(iconRequests()).toHaveLength(1);
  });
});

describe('FillController two-step codes', () => {
  const ORIGIN = 'https://example.com';

  function answer(code: unknown): void {
    channel.answer = (msg) => {
      if (msg.type === 'tab') return { type: 'tab', id: 1, fill: { ...FILL, otp: true } };
      if (msg.type === 'code') return code;
      return { type: 'hello', id: 1, version: 1, locked: false };
    };
  }

  async function filled(): Promise<void> {
    controller.report('poke');
    await settle();
  }

  function codeField(frameId = 0, url = `${ORIGIN}/two-factor`): void {
    controller.runtimeMessage({ type: 'code-field' }, { tab: { id: 1, url, active: true }, frameId, url });
  }

  function watches(): unknown[] {
    return tabs.frameMessages.filter((m) => m.msg.type === 'watch-code').map((m) => m.frameId);
  }

  it('asks the frames to watch for a code field after filling an account with a code', async () => {
    answer({ type: 'code', id: 2, otp: { origin: ORIGIN, code: '123456', expiresIn: 20 } });
    await filled();
    expect(tabs.frameMessages[0]?.msg).toEqual({ type: 'watch-code', origin: ORIGIN, waitMs: 30_000 });
  });

  it('watches for the code field of a code just added from a scan, with no fill', async () => {
    channel.answer = (msg) => {
      if (msg.type === 'tab') return { type: 'tab', id: 1, expectCode: { origin: ORIGIN, expiresIn: 25 } };
      if (msg.type === 'code') return { type: 'code', id: 2, otp: { origin: ORIGIN, code: '654321', expiresIn: 20 } };
      return { type: 'hello', id: 1, version: 1, locked: false };
    };
    await filled();
    expect(tabs.fills).toEqual([]);
    expect(tabs.frameMessages[0]?.msg).toEqual({ type: 'watch-code', origin: ORIGIN, waitMs: 25_000 });
    codeField();
    await settle(0);
    expect(tabs.frameMessages.at(-1)).toEqual({ tabId: 1, frameId: 0, msg: { type: 'code', origin: ORIGIN, code: '654321' } });
  });

  it('ignores a scan announcement for another origin than the reported tab', async () => {
    channel.answer = (msg) =>
      msg.type === 'tab' ? { type: 'tab', id: 1, expectCode: { origin: 'https://evil.test', expiresIn: 25 } } : { type: 'hello', id: 1 };
    await filled();
    expect(watches()).toEqual([]);
  });

  it('does not watch for an account without a code', async () => {
    answerWithFill();
    await filled();
    expect(watches()).toEqual([]);
  });

  it('asks the app, carrying nothing about Premium, and fills the answer into the frame that found the field', async () => {
    answer({ type: 'code', id: 2, otp: { origin: ORIGIN, code: '123456', expiresIn: 20 } });
    await filled();
    codeField();
    await settle(0);
    expect(channel.sent.filter((m) => m.type === 'code')).toEqual([{ type: 'code', url: `${ORIGIN}/` }]);
    expect(tabs.frameMessages.at(-1)).toEqual({ tabId: 1, frameId: 0, msg: { type: 'code', origin: ORIGIN, code: '123456' } });
  });

  it('asks once per fill', async () => {
    answer({ type: 'code', id: 2, otp: { origin: ORIGIN, code: '123456', expiresIn: 20 } });
    await filled();
    codeField();
    codeField();
    await settle(0);
    codeField();
    await settle(0);
    expect(channel.sent.filter((m) => m.type === 'code')).toHaveLength(1);
  });

  function upgradeClicked(frameId = 0, tabId = 1): void {
    controller.runtimeMessage({ type: 'upgrade' }, { tab: { id: tabId, url: `${ORIGIN}/two-factor`, active: true }, frameId, url: `${ORIGIN}/two-factor` });
  }

  function upgradesSent(): number {
    return channel.sent.filter((m) => m.type === 'upgrade').length;
  }

  async function hinted(): Promise<void> {
    answer({ type: 'code', id: 2, premium: false });
    await filled();
    codeField();
    await settle(0);
  }

  it('shows the hint when the app has no Premium, with no link of its own', async () => {
    await hinted();
    expect(tabs.frameMessages.at(-1)).toEqual({ tabId: 1, frameId: 0, msg: { type: 'code-hint', origin: ORIGIN } });
  });

  it("Upgrade in the hint asks the app for its Premium window, once", async () => {
    await hinted();
    upgradeClicked();
    upgradeClicked();
    expect(channel.sent.filter((m) => m.type === 'upgrade')).toEqual([{ type: 'upgrade' }]);
  });

  it('a page cannot ask for the Premium window: only the hinted frame may, and only while the hint shows', async () => {
    upgradeClicked();
    expect(upgradesSent()).toBe(0);
    await hinted();
    upgradeClicked(3);
    upgradeClicked(0, 2);
    expect(upgradesSent()).toBe(0);
    await settle(UPGRADE_WINDOW_MS + 1);
    upgradeClicked();
    expect(upgradesSent()).toBe(0);
  });

  it('a closed tab takes its hint with it', async () => {
    await hinted();
    controller.tabRemoved(1);
    upgradeClicked();
    expect(upgradesSent()).toBe(0);
  });

  it('ignores a code field in a frame of another origin, or after the window', async () => {
    answer({ type: 'code', id: 2, otp: { origin: ORIGIN, code: '123456', expiresIn: 20 } });
    await filled();
    codeField(3, 'https://ads.example.net/');
    await settle(0);
    expect(channel.sent.filter((m) => m.type === 'code')).toEqual([]);
    await settle(31_000);
    codeField();
    await settle(0);
    expect(channel.sent.filter((m) => m.type === 'code')).toEqual([]);
  });

  it('drops a code answer for another origin', async () => {
    answer({ type: 'code', id: 2, otp: { origin: 'https://evil.example', code: '123456', expiresIn: 20 } });
    await filled();
    codeField();
    await settle(0);
    expect(tabs.frameMessages.filter((m) => m.msg.type === 'code')).toEqual([]);
  });

  it('watches again on the next page of the same origin and in frames that load later', async () => {
    answer({ type: 'code', id: 2, otp: { origin: ORIGIN, code: '123456', expiresIn: 20 } });
    await filled();
    tabs.frameMessages = [];
    controller.tabUpdated(1, { status: 'complete' }, { id: 1, url: `${ORIGIN}/two-factor`, active: true });
    await settle(0);
    controller.runtimeMessage({ type: 'ready' }, { tab: { id: 1, url: `${ORIGIN}/two-factor`, active: true }, frameId: 0, url: `${ORIGIN}/two-factor` });
    await settle(0);
    expect(watches()).toEqual([0, 0]);
    controller.tabUpdated(1, { status: 'complete' }, { id: 1, url: 'https://elsewhere.example/', active: true });
    await settle(0);
    expect(watches()).toEqual([0, 0]);
  });

  it('closing the tab forgets the wait', async () => {
    answer({ type: 'code', id: 2, otp: { origin: ORIGIN, code: '123456', expiresIn: 20 } });
    await filled();
    controller.tabRemoved(1);
    codeField();
    await settle(0);
    expect(channel.sent.filter((m) => m.type === 'code')).toEqual([]);
  });
});
