import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FillController } from '../src/lib/controller';
import { fillOfTabAnswer, parseContentMessage, parseFillMessage } from '../src/lib/protocol';
import { FakeChannel, FakeTabs } from './fakes';

const FILL = { origin: 'https://example.com', username: 'octocat', password: 's3cret' };
const CHANGE = { ...FILL, newPassword: 'N3w-pass' };
const PAGE = { tab: { id: 1, url: 'https://example.com/settings/password?token=t0ken', active: true }, frameId: 0, url: 'https://example.com/settings/password?token=t0ken' };

let channel: FakeChannel;
let tabs: FakeTabs;
let controller: FillController;

function answerWith(fill: object): void {
  channel.answer = (msg) => (msg.type === 'tab' ? { type: 'tab', id: 1, fill } : { type: 'changed', id: 1, version: 1 });
}

async function settle(ms = 100): Promise<void> {
  await vi.advanceTimersByTimeAsync(ms);
}

function changedRequests(): unknown[] {
  return channel.sent.filter((m) => m.type === 'changed');
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

describe('a fill with a new password: messages', () => {
  it('a tab answer may carry newPassword; without it the fill reads as before', () => {
    expect(fillOfTabAnswer({ type: 'tab', id: 1, fill: { ...FILL, expiresIn: 20 } })).toEqual({ ...FILL, lifetimeMs: 20_000, otp: false });
    expect(fillOfTabAnswer({ type: 'tab', id: 1, fill: { ...CHANGE, expiresIn: 20, otp: true } })).toEqual({
      ...CHANGE,
      lifetimeMs: 20_000,
      otp: true,
    });
  });

  it('a newPassword that is not a non-empty string is none: the fill is a plain one', () => {
    for (const newPassword of ['', 7, null, { a: 1 }]) {
      expect(fillOfTabAnswer({ type: 'tab', id: 1, fill: { ...FILL, newPassword } })).toEqual({ ...FILL, lifetimeMs: 30_000, otp: false });
      expect(parseFillMessage({ type: 'fill', ...FILL, newPassword })).toEqual({ type: 'fill', ...FILL });
    }
  });

  it('the frame reads the fill with and without newPassword', () => {
    expect(parseFillMessage({ type: 'fill', ...FILL, waitMs: 5 })).toEqual({ type: 'fill', ...FILL, waitMs: 5 });
    expect(parseFillMessage({ type: 'fill', ...CHANGE, waitMs: 5 })).toEqual({ type: 'fill', ...CHANGE, waitMs: 5 });
    expect(parseFillMessage({ type: 'fill', origin: FILL.origin, newPassword: 'N3w-pass' })).toBeUndefined();
  });

  it('the frame says changed, and carries nothing with it', () => {
    expect(parseContentMessage({ type: 'changed', url: 'https://evil.example/', password: 'x' })).toEqual({ type: 'changed' });
  });
});

describe('FillController with a new password', () => {
  it('sends the new password to the frame with the fill, and to frames of the origin only', async () => {
    answerWith(CHANGE);
    tabs.framesByTab.set(1, [
      { frameId: 0, url: 'https://example.com/login' },
      { frameId: 4, url: 'https://ads.evil.example/frame' },
    ]);
    controller.report('poke');
    await settle();
    expect(tabs.fills).toEqual([{ tabId: 1, frameId: 0, msg: { type: 'fill', ...CHANGE, waitMs: 30_000 } }]);
  });

  it('gives it to no tab of another origin', async () => {
    answerWith({ ...CHANGE, origin: 'https://other.example' });
    controller.report('poke');
    await settle();
    expect(tabs.fills).toEqual([]);
    controller.runtimeMessage({ type: 'changed' }, PAGE);
    expect(changedRequests()).toEqual([]);
  });

  it('a fill without one has no newPassword key', async () => {
    answerWith(FILL);
    controller.report('poke');
    await settle();
    expect(tabs.fills[0]?.msg).toEqual({ type: 'fill', ...FILL, waitMs: 30_000 });
  });

  it('a sign-in on the way: the next page of the same origin gets the new password', async () => {
    answerWith(CHANGE);
    tabs.frameAnswer = () => ({ username: true, password: false });
    controller.report('poke');
    await settle();
    expect(controller.hasEntry(1)).toBe(true);
    controller.tabUpdated(1, { status: 'complete' }, { id: 1, url: 'https://example.com/settings/password', active: false });
    await settle();
    expect(tabs.fills.map((f) => f.msg.newPassword)).toEqual(['N3w-pass', 'N3w-pass']);
  });

  it('tells the app once that the form was submitted, with the origin only', async () => {
    answerWith(CHANGE);
    controller.report('poke');
    await settle();
    expect(controller.hasEntry(1)).toBe(false); // the password is gone from the background; the wait holds no secret

    controller.runtimeMessage({ type: 'changed' }, PAGE);
    controller.runtimeMessage({ type: 'changed' }, PAGE);
    await settle();
    expect(changedRequests()).toEqual([{ type: 'changed', url: 'https://example.com/' }]);
  });

  it('an app from before this message answers with an error, and nothing breaks', async () => {
    channel.answer = (msg) => (msg.type === 'tab' ? { type: 'tab', id: 1, fill: CHANGE } : { type: 'error', id: 1, code: 'bad-request' });
    controller.report('poke');
    await settle();
    controller.runtimeMessage({ type: 'changed' }, PAGE);
    await settle();
    expect(changedRequests()).toHaveLength(1);
    controller.report('poke');
    await settle();
    expect(tabs.fills).toHaveLength(2);
  });

  it('says nothing for a tab that got a plain fill, or no fill', async () => {
    controller.runtimeMessage({ type: 'changed' }, PAGE);
    answerWith(FILL);
    controller.report('poke');
    await settle();
    controller.runtimeMessage({ type: 'changed' }, PAGE);
    expect(changedRequests()).toEqual([]);
  });

  it('says nothing from another tab, a frame of another origin, or a tab that moved to another site', async () => {
    answerWith(CHANGE);
    controller.report('poke');
    await settle();
    controller.runtimeMessage({ type: 'changed' }, { ...PAGE, tab: { ...PAGE.tab, id: 2 } });
    controller.runtimeMessage({ type: 'changed' }, { ...PAGE, frameId: 4, url: 'https://ads.evil.example/frame' });
    controller.runtimeMessage({ type: 'changed' }, { ...PAGE, url: undefined });
    controller.runtimeMessage({ type: 'changed' }, { ...PAGE, tab: { ...PAGE.tab, url: 'https://other.example/' } });
    expect(changedRequests()).toEqual([]);
    controller.runtimeMessage({ type: 'changed' }, PAGE);
    expect(changedRequests()).toHaveLength(1);
  });

  it('a plain fill after it ends the wait', async () => {
    answerWith(CHANGE);
    controller.report('poke');
    await settle();
    answerWith(FILL);
    controller.report('poke');
    await settle();
    controller.runtimeMessage({ type: 'changed' }, PAGE);
    expect(changedRequests()).toEqual([]);
  });

  it('stops waiting after 10 minutes, and when the tab closes', async () => {
    answerWith(CHANGE);
    controller.report('poke');
    await settle();
    await settle(600_000);
    controller.runtimeMessage({ type: 'changed' }, PAGE);
    expect(changedRequests()).toEqual([]);

    controller.report('poke');
    await settle();
    controller.tabRemoved(1);
    controller.runtimeMessage({ type: 'changed' }, PAGE);
    expect(changedRequests()).toEqual([]);
  });
});
