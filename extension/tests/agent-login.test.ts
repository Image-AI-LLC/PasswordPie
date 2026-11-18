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
    expect(fillOfTabAnswer({ type: 'tab', id: 1, fill: { ...FILL, submit: true, report: true, loginId: 'L1' } })).toMatchObject({ submit: true, report: true });
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
    answer({ ...FILL, submit: true, report: true, loginId: 'L1' });
    tabs.frameAnswer = () => ({ username: true, password: true, submitted: true });
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(100);
    expect(tabs.fills.map((f) => f.msg.submit)).toEqual([true]);
    expect(results()).toEqual([{ type: 'login-result', url: 'https://example.com/', result: 'submitted', loginId: 'L1' }]);
    expect(JSON.stringify(results())).not.toContain('s3cret');
    await vi.advanceTimersByTimeAsync(40_000);
    expect(results()).toHaveLength(1);
  });

  it('reports `filled` when the agent did not ask to send the form', async () => {
    answer({ ...FILL, report: true, loginId: 'L1' });
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(100);
    expect(tabs.fills[0]?.msg.submit).toBeUndefined();
    expect(results()).toEqual([{ type: 'login-result', url: 'https://example.com/', result: 'filled', loginId: 'L1' }]);
  });

  it('reports `no-fields` when the password never went in before the fill ran out', async () => {
    answer({ ...FILL, report: true, expiresIn: 30, loginId: 'L1' });
    tabs.frameAnswer = () => ({ username: false, password: false });
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(100);
    expect(results()).toEqual([]);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(results()).toEqual([{ type: 'login-result', url: 'https://example.com/', result: 'no-fields', loginId: 'L1' }]);
  });

  it('reports a password that went in late, from a frame of the fill origin only', async () => {
    answer({ ...FILL, submit: true, report: true, loginId: 'L1' });
    tabs.frameAnswer = () => ({ username: true, password: false });
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(100);
    const tab = { id: 1, url: 'https://example.com/login', active: true };
    controller.runtimeMessage({ type: 'filled', password: true, submitted: true }, { tab, frameId: 3, url: 'https://evil.example/' });
    expect(results()).toEqual([]);
    expect(controller.hasEntry(1)).toBe(true); // word from another origin ends nothing
    controller.runtimeMessage({ type: 'filled', password: true, submitted: true }, { tab, frameId: 0, url: 'https://example.com/login' });
    expect(results()).toEqual([{ type: 'login-result', url: 'https://example.com/', result: 'submitted', loginId: 'L1' }]);
  });

  it('reports `no-fields` when the tab closes or another fill replaces it before the password went in', async () => {
    answer({ ...FILL, report: true, loginId: 'L1' });
    tabs.frameAnswer = () => ({ username: true, password: false });
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(100);
    controller.tabRemoved(1);
    expect(results()).toEqual([{ type: 'login-result', url: 'https://example.com/', result: 'no-fields', loginId: 'L1' }]);
    await vi.advanceTimersByTimeAsync(31_000);
    expect(results()).toHaveLength(1);
  });

  it('a stale result about a replaced login carries that login\'s id', async () => {
    answer({ ...FILL, report: true, loginId: 'OLD' });
    tabs.frameAnswer = () => ({ username: true, password: false });
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(100);
    answer({ ...FILL, report: true, loginId: 'NEW' });
    tabs.frameAnswer = () => ({ username: true, password: true });
    controller.report('poke');
    await vi.advanceTimersByTimeAsync(100);
    expect(results()).toEqual([
      { type: 'login-result', url: 'https://example.com/', result: 'no-fields', loginId: 'OLD' },
      { type: 'login-result', url: 'https://example.com/', result: 'filled', loginId: 'NEW' },
    ]);
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

  const agentFill: FillMessage = { type: 'fill', ...FILL, submit: true, loginId: 'L1' };

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

  it('sends the form once when the same fill is delivered twice to one page', () => {
    document.body.innerHTML = `<form><input id="user" autocomplete="username"><input id="pass" type="password">
      <button id="go" type="submit">Sign in</button></form>`;
    const sent = submits();
    const page = makeFiller();
    expect(page.handle(agentFill).submitted).toBe(true);
    expect(page.handle(agentFill).submitted).toBeUndefined();
    expect(sent).toEqual(['go']);
  });

  it('a retry, another login, may send the same page again', () => {
    document.body.innerHTML = `<form><input id="user" autocomplete="username"><input id="pass" type="password">
      <button id="go" type="submit">Sign in</button></form>`;
    const sent = submits();
    const page = makeFiller();
    page.handle(agentFill);
    expect(page.handle({ ...agentFill, loginId: 'L2' }).submitted).toBe(true);
    expect(sent).toEqual(['go', 'go']);
  });

  it('presses a sign-in button that sits right under the body, with no form', () => {
    document.body.innerHTML = `<input id="user" autocomplete="username"><input id="pass" type="password"><button id="go">Log in</button>`;
    let clicked = false;
    document.getElementById('go')?.addEventListener('click', () => (clicked = true));
    expect(makeFiller().handle(agentFill).submitted).toBe(true);
    expect(clicked).toBe(true);
  });

  it('presses a Next button that names the username form from outside it', async () => {
    document.body.innerHTML = `<form id="step"><input id="user" autocomplete="username"></form><button id="next" form="step">Next</button>`;
    const sent = submits();
    makeFiller().handle(agentFill);
    await vi.advanceTimersByTimeAsync(USERNAME_SUBMIT_DELAY_MS + 100);
    expect(sent).toEqual(['next']);
  });

  it('on a username step, never clicks a text box that names the form, and finds an image button by its alt', async () => {
    document.body.innerHTML = `<form id="step"><input id="user" autocomplete="username"></form>
      <input type="text" id="decoy" form="step" value="Next"><input type="image" id="go" form="step" alt="Next" src="data:,">`;
    const clicked: string[] = [];
    for (const id of ['decoy', 'go']) document.getElementById(id)?.addEventListener('click', () => clicked.push(id));
    makeFiller().handle(agentFill);
    await vi.advanceTimersByTimeAsync(USERNAME_SUBMIT_DELAY_MS + 100);
    expect(clicked).toEqual(['go']);
  });

  it('never clicks a control outside the form that is not a submit button', () => {
    document.body.innerHTML = `<form id="login"><input id="user" autocomplete="username"><input id="pass" type="password"></form>
      <input type="checkbox" id="remember" form="login"><button id="go" type="submit" form="login">Sign in</button>`;
    const sent = submits();
    makeFiller().handle(agentFill);
    expect((document.getElementById('remember') as HTMLInputElement).checked).toBe(false);
    expect(sent).toEqual(['go']);
  });

  it('never presses a lone email field\'s other buttons: a reset or newsletter form is not a sign-in step', async () => {
    document.body.innerHTML = `<form><input id="user" type="email" autocomplete="email"><button id="reset">Send password reset email</button></form>`;
    const sent = submits();
    makeFiller().handle(agentFill);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(sent).toEqual([]);
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

  it('tells the background when the Next timer finds and fills a late password field', async () => {
    document.body.innerHTML = `<form><input id="user" autocomplete="username"><button id="go" type="submit">Sign in</button></form>`;
    const sent = submits();
    makeFiller().handle(agentFill);
    // The password field shows just before the timer fires, before the watch's next look.
    await vi.advanceTimersByTimeAsync(USERNAME_SUBMIT_DELAY_MS - 30);
    const pass = document.createElement('input');
    pass.type = 'password';
    pass.id = 'pass';
    document.querySelector('form')?.insertBefore(pass, document.getElementById('go'));
    await vi.advanceTimersByTimeAsync(40);
    expect(pass.value).toBe('s3cret');
    expect(sent).toEqual(['go']);
    expect(late).toEqual([true]);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(late).toEqual([true]);
  });

  it('presses Next on a username step that renders after the fill arrived', async () => {
    document.body.innerHTML = `<div id="app"></div>`;
    const sent = submits();
    makeFiller().handle(agentFill);
    document.getElementById('app')!.innerHTML = `<form><input id="user" autocomplete="username"><button id="next">Next</button></form>`;
    const late = submits();
    await vi.advanceTimersByTimeAsync(300 + USERNAME_SUBMIT_DELAY_MS + 100);
    expect(input('user').value).toBe('octocat');
    expect([...sent, ...late]).toEqual(['next']);
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
