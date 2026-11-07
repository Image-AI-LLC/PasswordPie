import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FillController } from '../src/lib/controller';
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
    expect(channel.sent[0]).toEqual({ type: 'hello', version: 1, extension: '0.1.0' });
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/login', reason: 'startup' }]);
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

  it('reports the tab on a poke', async () => {
    controller.start();
    await settle();
    channel.sent = [];
    channel.events?.onPoke();
    await settle();
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/login', reason: 'poke' }]);
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
    expect(tabs.fills[0]).toEqual({ tabId: 1, frameId: 0, msg: { type: 'fill', ...FILL } });
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
