// An agent's login (docs/BROWSER_EXTENSION.md, "Agent logins"): the app marks the fill `report`, and `submit` when the
// agent asked; the page's own button is pressed after the password, and the app is told how it went, once. Nothing about
// it changes an ordinary fill.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FillController } from '../src/lib/controller';
import { PageFiller, USERNAME_SUBMIT_DELAY_MS, type PageEnv } from '../src/lib/page-filler';
import { fillOfTabAnswer, parseContentMessage, parseFillMessage, parseFillResult, type FillMessage } from '../src/lib/protocol';
import { FakeChannel, FakeTabs } from './fakes';
import { input, loadFixture } from './helpers';

const ORIGIN = 'https://example.com';
const FILL = { origin: ORIGIN, username: 'octocat', password: 's3cret' };

describe('agent login: messages', () => {
  it('carries submit and report only when the app set them, and never submit with a new password', () => {
    expect(fillOfTabAnswer({ type: 'tab', id: 1, fill: { ...FILL, submit: true, report: true } })).toMatchObject({ submit: true, report: true });
    const plain = fillOfTabAnswer({ type: 'tab', id: 1, fill: FILL });
    expect(plain && 'submit' in plain).toBe(false);
    expect(plain && 'report' in plain).toBe(false);
    for (const odd of ['true', 1, null, {}]) {
      const parsed = fillOfTabAnswer({ type: 'tab', id: 1, fill: { ...FILL, submit: odd, report: odd } });
      expect(parsed && ('submit' in parsed || 'report' in parsed)).toBe(false);
    }
    const reset = fillOfTabAnswer({ type: 'tab', id: 1, fill: { ...FILL, newPassword: 'n3w-pass', submit: true, report: true } });
    expect(reset && 'submit' in reset).toBe(false);
    expect(parseFillMessage({ type: 'fill', ...FILL, submit: true })?.submit).toBe(true);
    expect(parseFillMessage({ type: 'fill', ...FILL, newPassword: 'n3w-pass', submit: true })?.submit).toBeUndefined();
    expect(parseFillResult({ username: true, password: true, submitted: true })).toEqual({ username: true, password: true, submitted: true });
    expect(parseContentMessage({ type: 'filled', password: true, submitted: true })).toEqual({ type: 'filled', password: true, submitted: true });
  });
});

describe('agent login: the background', () => {
  let channel: FakeChannel;
  let tabs: FakeTabs;
  let controller: FillController;

  function answer(fill: Record<string, unknown>): void {
    channel.answer = (msg) => (msg.type === 'tab' ? { type: 'tab', id: 1, fill } : { type: msg.type, id: 1 });
  }

  function results(): unknown[] {
    return channel.sent.filter((m) => m.type === 'login-result');
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

  it('asks the page to send the form and reports `submitted` once, with the origin only', async () => {
    answer({ ...FILL, submit: true, report: true });
    tabs.frameAnswer = () => ({ username: true, password: true, submitted: true });
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(100);
    expect(tabs.fills.map((f) => f.msg.submit)).toEqual([true]);
    expect(results()).toEqual([{ type: 'login-result', url: 'https://example.com/', result: 'submitted' }]);
    expect(JSON.stringify(results())).not.toContain('s3cret');
    await vi.advanceTimersByTimeAsync(40_000);
    expect(results()).toHaveLength(1);
  });

  it('reports `filled` when the agent did not ask to send the form', async () => {
    answer({ ...FILL, report: true });
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(100);
    expect(tabs.fills[0]?.msg.submit).toBeUndefined();
    expect(results()).toEqual([{ type: 'login-result', url: 'https://example.com/', result: 'filled' }]);
  });

  it('reports `no-fields` when the password never went in before the fill ran out', async () => {
    answer({ ...FILL, report: true, expiresIn: 30 });
    tabs.frameAnswer = () => ({ username: false, password: false });
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(100);
    expect(results()).toEqual([]);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(results()).toEqual([{ type: 'login-result', url: 'https://example.com/', result: 'no-fields' }]);
  });

  it('reports a password that went in late, from a frame of the fill origin only', async () => {
    answer({ ...FILL, submit: true, report: true });
    tabs.frameAnswer = () => ({ username: true, password: false });
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(100);
    const tab = { id: 1, url: 'https://example.com/login', active: true };
    controller.runtimeMessage({ type: 'filled', password: true, submitted: true }, { tab, frameId: 3, url: 'https://evil.example/' });
    expect(results()).toEqual([]);
    expect(controller.hasEntry(1)).toBe(false);
    answer({ ...FILL, submit: true, report: true });
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(100);
    controller.runtimeMessage({ type: 'filled', password: true, submitted: true }, { tab, frameId: 0, url: 'https://example.com/login' });
    expect(results()).toEqual([{ type: 'login-result', url: 'https://example.com/', result: 'submitted' }]);
  });

  it('says nothing for an ordinary fill', async () => {
    answer(FILL);
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(31_000);
    expect(tabs.fills[0]?.msg.submit).toBeUndefined();
    expect(results()).toEqual([]);
  });
});

describe('agent login: the page', () => {
  let filler: PageFiller | undefined;
  let late: boolean[] = [];

  function makeFiller(): PageFiller {
    const env: PageEnv = {
      document,
      origin: location.origin,
      frameAllowed: () => true,
      notifyPasswordFilled: (submitted) => late.push(submitted),
    };
    filler = new PageFiller(env);
    return filler;
  }

  function submits(): string[] {
    const sent: string[] = [];
    document.querySelector('form')?.addEventListener('submit', (event) => {
      event.preventDefault();
      sent.push((event as SubmitEvent).submitter?.id ?? 'form');
    });
    return sent;
  }

  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'Date'] });
    document.body.innerHTML = '';
    late = [];
  });

  afterEach(() => {
    filler?.stop();
    filler = undefined;
    vi.useRealTimers();
  });

  const agentFill: FillMessage = { type: 'fill', ...FILL, submit: true };

  it('presses the form own button after the password, once', () => {
    document.body.innerHTML = `<form><input id="user" autocomplete="username"><input id="pass" type="password">
      <button id="help" type="button">Help</button><button id="go" type="submit">Sign in</button></form>`;
    const sent = submits();
    expect(makeFiller().handle(agentFill)).toEqual({ username: true, password: true, submitted: true });
    expect(input('pass').value).toBe('s3cret');
    expect(sent).toEqual(['go']);
  });

  it('sends a form without a button through requestSubmit, so its handlers run', () => {
    document.body.innerHTML = `<form><input id="user" autocomplete="username"><input id="pass" type="password"></form>`;
    const sent = submits();
    expect(makeFiller().handle(agentFill).submitted).toBe(true);
    expect(sent).toEqual(['form']);
  });

  it('presses a sign-in button next to fields that have no form', () => {
    document.body.innerHTML = `<div><input id="user" autocomplete="username"><input id="pass" type="password">
      <span role="button" id="cancel">Cancel</span><div role="button" id="go">Log in</div></div>`;
    const clicked: string[] = [];
    for (const id of ['cancel', 'go']) document.getElementById(id)?.addEventListener('click', () => clicked.push(id));
    expect(makeFiller().handle(agentFill).submitted).toBe(true);
    expect(clicked).toEqual(['go']);
  });

  it('never sends the form without `submit`', () => {
    loadFixture('autocomplete.html');
    const sent = submits();
    expect(makeFiller().handle({ type: 'fill', ...FILL })).toEqual({ username: true, password: true });
    expect(sent).toEqual([]);
  });

  it('on a username-only page presses Next once, after a moment without a password field', async () => {
    document.body.innerHTML = `<form><input id="user" autocomplete="username"><button id="next">Next</button></form>`;
    const sent = submits();
    expect(makeFiller().handle(agentFill)).toEqual({ username: true, password: false });
    await vi.advanceTimersByTimeAsync(USERNAME_SUBMIT_DELAY_MS - 50);
    expect(sent).toEqual([]);
    await vi.advanceTimersByTimeAsync(100);
    expect(sent).toEqual(['next']);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(sent).toEqual(['next']);
  });

  it('fills and sends a password field that appears later, and tells the background', async () => {
    document.body.innerHTML = `<form><input id="user" autocomplete="username"><button id="go">Continue</button></form>`;
    const sent = submits();
    makeFiller().handle(agentFill);
    const pass = document.createElement('input');
    pass.type = 'password';
    pass.id = 'pass';
    document.querySelector('form')?.insertBefore(pass, document.getElementById('go'));
    await vi.advanceTimersByTimeAsync(300);
    expect(pass.value).toBe('s3cret');
    expect(sent).toEqual(['go']);
    expect(late).toEqual([true]);
  });
});
