import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FillController, SIGN_IN_ASK_MS } from '../src/lib/controller';
import { showsSignIn } from '../src/lib/fields';
import { parseFrameMessage, parseSignInAsk, type SignInAsk } from '../src/lib/protocol';
import { signInAnswer } from '../src/lib/sign-in';
import { FakeChannel, FakeTabs } from './fakes';
import { input, loadFixture } from './helpers';

// Every tab report says whether the page shows a sign-in form, so the app can fill this page with the account the
// person picked instead of opening the account's own website (docs/UX.md, "Fill in the browser").

describe('showsSignIn', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('is true for a page with a password field', () => {
    loadFixture('autocomplete.html');
    expect(showsSignIn(document)).toBe(true);
    loadFixture('plain.html');
    expect(showsSignIn(document)).toBe(true);
  });

  it('is true for a username step marked autocomplete="username", focused or not', () => {
    document.body.innerHTML = '<form><input id="u" type="text" name="login" autocomplete="username"><button>Next</button></form>';
    expect(showsSignIn(document)).toBe(true);
  });

  it('is false for a lone e-mail box nobody is in: a newsletter form', () => {
    loadFixture('newsletter.html');
    expect(showsSignIn(document)).toBe(false);
  });

  it('is true for the same box once the caret is in it', () => {
    loadFixture('newsletter.html');
    input('news').focus();
    expect(document.activeElement).toBe(input('news'));
    expect(showsSignIn(document)).toBe(true);
  });

  it('is true for an unmarked username step with the caret in it, false without', () => {
    loadFixture('email-step.html');
    expect(showsSignIn(document)).toBe(false);
    input('email').focus();
    expect(showsSignIn(document)).toBe(true);
  });

  it('is false for a page with no fields, with only a search box, or with only hidden ones', () => {
    document.body.innerHTML = '<h1>News</h1><p>Nothing to sign in to.</p>';
    expect(showsSignIn(document)).toBe(false);
    document.body.innerHTML = '<form role="search"><input id="s" type="text" name="q"></form>';
    input('s').focus();
    expect(showsSignIn(document)).toBe(false);
    document.body.innerHTML = '<input type="password" style="display:none"><input type="hidden" name="username">';
    expect(showsSignIn(document)).toBe(false);
  });

  it('finds a password field inside an open shadow root', () => {
    document.body.innerHTML = '<login-box></login-box>';
    const host = document.querySelector('login-box');
    if (!host) throw new Error('no host');
    host.attachShadow({ mode: 'open' }).innerHTML = '<form><input type="email"><input type="password"></form>';
    expect(showsSignIn(document)).toBe(true);
  });

  it('follows the focus into an open shadow root for a lone username field', () => {
    document.body.innerHTML = '<login-box></login-box>';
    const host = document.querySelector('login-box');
    if (!host) throw new Error('no host');
    const shadow = host.attachShadow({ mode: 'open' });
    shadow.innerHTML = '<form><input id="u" type="email" name="identifier"></form>';
    expect(showsSignIn(document)).toBe(false);
    input('u', shadow).focus();
    expect(showsSignIn(document)).toBe(true);
  });
});

describe('the sign-in ask in a frame', () => {
  const ask: SignInAsk = { type: 'sign-in', origin: 'https://example.com' };

  beforeEach(() => {
    loadFixture('autocomplete.html');
  });

  it('answers for a frame of the asked origin that is the top frame or same-origin with it', () => {
    expect(signInAnswer(ask, { document, origin: 'https://example.com', frameAllowed: () => true })).toBe(true);
    document.body.innerHTML = '<p>No form</p>';
    expect(signInAnswer(ask, { document, origin: 'https://example.com', frameAllowed: () => true })).toBe(false);
  });

  it('says no in a frame of another origin, and in a frame of another site than the top one', () => {
    expect(signInAnswer(ask, { document, origin: 'https://ads.example.net', frameAllowed: () => true })).toBe(false);
    expect(signInAnswer(ask, { document, origin: 'https://example.com', frameAllowed: () => false })).toBe(false);
  });

  it('reads the ask and nothing else, and it is not a code message', () => {
    expect(parseSignInAsk({ type: 'sign-in', origin: 'https://a.example', extra: 1 })).toEqual({ type: 'sign-in', origin: 'https://a.example' });
    expect(parseSignInAsk({ type: 'sign-in' })).toBeUndefined();
    expect(parseSignInAsk({ type: 'sign-in', origin: 7 })).toBeUndefined();
    expect(parseSignInAsk({ type: 'watch-code', origin: 'https://a.example', waitMs: 5 })).toBeUndefined();
    expect(parseSignInAsk(undefined)).toBeUndefined();
    expect(parseFrameMessage({ type: 'sign-in', origin: 'https://a.example' })).toBeUndefined();
  });
});

describe('FillController says whether the page shows a sign-in form', () => {
  const FILL = { origin: 'https://example.com', username: 'octocat', password: 's3cret' };
  let channel: FakeChannel;
  let tabs: FakeTabs;
  let controller: FillController;

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

  it('sends signIn: true when a frame of the tab’s origin shows one', async () => {
    tabs.signInAnswer = () => true;
    controller.report('activated');
    await settle();
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/', reason: 'activated', signIn: true }]);
    expect(tabs.signInAsks).toEqual([{ tabId: 1, frameId: 0, msg: { type: 'sign-in', origin: 'https://example.com' } }]);
  });

  it('sends signIn: false when every frame of the origin answered and none shows one', async () => {
    tabs.framesByTab.set(1, [
      { frameId: 0, url: 'https://example.com/' },
      { frameId: 3, url: 'https://example.com/embedded' },
    ]);
    tabs.signInAnswer = () => false;
    controller.report('activated');
    await settle();
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/', reason: 'activated', signIn: false }]);
    expect(tabs.signInAsks.map((a) => a.frameId)).toEqual([0, 3]);
  });

  it('counts a form in a same-origin frame, and never asks a frame of another origin', async () => {
    tabs.framesByTab.set(1, [
      { frameId: 0, url: 'https://example.com/' },
      { frameId: 3, url: 'https://example.com/login-frame' },
      { frameId: 4, url: 'https://ads.example.net/banner' },
      { frameId: 5, url: 'about:blank' },
    ]);
    tabs.signInAnswer = (_tabId, frameId) => frameId === 3;
    controller.report('activated');
    await settle();
    expect(channel.tabReports()[0]?.signIn).toBe(true);
    expect(tabs.signInAsks.map((a) => a.frameId)).toEqual([0, 3]);
  });

  it('goes with the focus word, each read as the report goes out', async () => {
    tabs.profileFocused = async () => true;
    tabs.signInAnswer = () => true;
    controller.report('poke');
    await settle();
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/', reason: 'poke', focused: true, signIn: true }]);
  });

  it('leaves the word out where the browser side cannot ask', async () => {
    controller.report('activated');
    await settle();
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/', reason: 'activated' }]);
  });

  it('leaves it out, and asks nobody, for a page that is not a web page', async () => {
    tabs.signInAnswer = () => true;
    tabs.active = { id: 1, url: 'chrome://newtab/', active: true };
    controller.report('activated');
    await settle();
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: '', reason: 'activated' }]);
    expect(tabs.signInAsks).toEqual([]);
  });

  it('leaves it out when a frame has no content script to answer (a page open since before the update)', async () => {
    tabs.signInAnswer = () => undefined;
    controller.report('activated');
    await settle();
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/', reason: 'activated' }]);
  });

  it('leaves it out when asking fails, and the report still goes out', async () => {
    tabs.signInAnswer = () => {
      throw new Error('Could not establish connection. Receiving end does not exist.');
    };
    controller.report('activated');
    await settle();
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/', reason: 'activated' }]);
    channel.sent = [];
    tabs.frames = async () => {
      throw new Error('No tab with id: 1');
    };
    controller.report('activated');
    await settle();
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/', reason: 'activated' }]);
  });

  it(`waits at most ${SIGN_IN_ASK_MS} ms for the page: then the report goes out without the word`, async () => {
    tabs.signInAnswer = () => new Promise(() => {});
    controller.report('activated');
    await settle(100 + SIGN_IN_ASK_MS - 1);
    expect(channel.tabReports()).toHaveLength(0);
    await settle(1);
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/', reason: 'activated' }]);
  });

  it('does not wait for a slow frame once another one said yes', async () => {
    tabs.framesByTab.set(1, [
      { frameId: 0, url: 'https://example.com/' },
      { frameId: 3, url: 'https://example.com/slow' },
    ]);
    tabs.signInAnswer = (_tabId, frameId) => (frameId === 0 ? true : new Promise(() => {}));
    controller.report('activated');
    await settle();
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/', reason: 'activated', signIn: true }]);
  });

  it('does not say no while a frame of the origin has not answered', async () => {
    tabs.framesByTab.set(1, [
      { frameId: 0, url: 'https://example.com/' },
      { frameId: 3, url: 'https://example.com/slow' },
    ]);
    tabs.signInAnswer = (_tabId, frameId) => (frameId === 0 ? false : new Promise(() => {}));
    controller.report('activated');
    await settle(100 + SIGN_IN_ASK_MS);
    expect(channel.tabReports()).toEqual([{ type: 'tab', url: 'https://example.com/', reason: 'activated' }]);
  });

  it('still fills the tab from the answer, exactly as before', async () => {
    tabs.signInAnswer = () => true;
    channel.answer = (msg) => (msg.type === 'tab' ? { type: 'tab', id: 1, fill: FILL } : undefined);
    controller.report('poke');
    await settle();
    expect(tabs.fills).toHaveLength(1);
    expect(tabs.fills[0]).toMatchObject({ tabId: 1, frameId: 0, msg: { type: 'fill', ...FILL } });
    expect(controller.hasEntry(1)).toBe(false);
  });

  it('sends only yes or no: nothing about the field or what is in it', async () => {
    tabs.signInAnswer = () => true;
    controller.report('activated');
    await settle();
    expect(Object.keys(channel.tabReports()[0] ?? {}).sort()).toEqual(['reason', 'signIn', 'type', 'url']);
  });
});
