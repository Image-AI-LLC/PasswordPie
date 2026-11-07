import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PageFiller, type PageEnv } from '../src/lib/page-filler';
import type { FillMessage } from '../src/lib/protocol';
import { input, loadFixture } from './helpers';

const ORIGIN = 'https://example.com';
const fill: FillMessage = { type: 'fill', origin: ORIGIN, username: 'octocat', password: 's3cret' };

let filler: PageFiller | undefined;
let notified = 0;

function makeFiller(overrides: Partial<PageEnv> = {}): PageFiller {
  filler = new PageFiller({
    document,
    origin: location.origin,
    frameAllowed: () => true,
    notifyPasswordFilled: () => {
      notified += 1;
    },
    ...overrides,
  });
  return filler;
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'Date'] });
  document.body.innerHTML = '';
  notified = 0;
});

afterEach(() => {
  filler?.stop();
  filler = undefined;
  vi.useRealTimers();
});

describe('PageFiller', () => {
  it('runs in a page at the expected origin', () => {
    expect(location.origin).toBe(ORIGIN);
  });

  it('fills username and password and fires input and change events', () => {
    loadFixture('autocomplete.html');
    const events: string[] = [];
    for (const id of ['user', 'pass']) {
      for (const type of ['input', 'change']) {
        input(id).addEventListener(type, (e) => {
          expect(e.bubbles).toBe(true);
          expect(e.composed).toBe(true);
          events.push(`${id}:${type}`);
        });
      }
    }
    let submitted = false;
    document.querySelector('form')?.addEventListener('submit', (e) => {
      submitted = true;
      e.preventDefault();
    });

    expect(makeFiller().handle(fill)).toEqual({ username: true, password: true });
    expect(input('user').value).toBe('octocat');
    expect(input('pass').value).toBe('s3cret');
    expect(events).toEqual(['user:input', 'user:change', 'pass:input', 'pass:change']);
    expect(submitted).toBe(false);
  });

  it('fills a form that has no attributes at all', () => {
    loadFixture('plain.html');
    expect(makeFiller().handle(fill)).toEqual({ username: true, password: true });
    expect(input('user').value).toBe('octocat');
    expect(input('pass').value).toBe('s3cret');
    expect(input('search').value).toBe('');
  });

  it('fills only the sign-in form on a sign-up + sign-in page', () => {
    loadFixture('signup-signin.html');
    makeFiller().handle(fill);
    expect(input('signin-pass').value).toBe('s3cret');
    expect(input('signup-pass').value).toBe('');
    expect(input('signup-confirm').value).toBe('');
    expect(input('signup-email').value).toBe('');
  });

  it('fills only the current password on a change-password page', () => {
    loadFixture('change-password.html');
    expect(makeFiller().handle(fill)).toEqual({ username: false, password: true });
    expect(input('current').value).toBe('s3cret');
    expect(input('new').value).toBe('');
    expect(input('confirm').value).toBe('');
  });

  it('leaves hidden decoys and search boxes empty', () => {
    loadFixture('decoys.html');
    makeFiller().handle(fill);
    expect(input('user').value).toBe('octocat');
    expect(input('pass').value).toBe('s3cret');
    for (const id of ['site-search', 'q', 'in-hidden-parent', 'pw-in-hidden-parent', 'hidden-attr', 'ghost', 'inline-none', 'disabled', 'readonly-pw', 'decoy-after']) {
      expect(input(id).value, id).toBe('');
    }
    expect(input('hidden-type').value).toBe('');
  });

  it('two-step: fills the email now and the password when its field appears', async () => {
    loadFixture('email-step.html');
    expect(makeFiller().handle(fill)).toEqual({ username: true, password: false });
    expect(input('email').value).toBe('octocat');
    expect(notified).toBe(0);

    await vi.advanceTimersByTimeAsync(5_000);
    const form = document.getElementById('step');
    form?.insertAdjacentHTML('beforeend', '<input id="pw" type="password">');
    await vi.advanceTimersByTimeAsync(0); // MutationObserver
    expect(input('pw').value).toBe('s3cret');
    expect(notified).toBe(1);
  });

  it('two-step: notices a password field in a shadow root by polling', async () => {
    loadFixture('email-step.html');
    makeFiller().handle(fill);
    document.body.insertAdjacentHTML('beforeend', '<pw-box></pw-box>');
    const host = document.querySelector('pw-box');
    if (!host) throw new Error('no host');
    const root = host.attachShadow({ mode: 'open' });
    await vi.advanceTimersByTimeAsync(0);
    root.innerHTML = '<input id="pw" type="password">'; // no mutation on the document
    await vi.advanceTimersByTimeAsync(250);
    expect(input('pw', root).value).toBe('s3cret');
    expect(notified).toBe(1);
  });

  it('waits for an SPA that has not rendered its form yet', async () => {
    expect(makeFiller().handle(fill)).toEqual({ username: false, password: false });
    await vi.advanceTimersByTimeAsync(1_000);
    loadFixture('autocomplete.html');
    await vi.advanceTimersByTimeAsync(0);
    expect(input('user').value).toBe('octocat');
    expect(input('pass').value).toBe('s3cret');
    expect(notified).toBe(1);
  });

  it('stops waiting 30 seconds after the fill arrived', async () => {
    loadFixture('email-step.html');
    makeFiller().handle(fill);
    await vi.advanceTimersByTimeAsync(30_001);
    document.getElementById('step')?.insertAdjacentHTML('beforeend', '<input id="pw" type="password">');
    await vi.advanceTimersByTimeAsync(500);
    expect(input('pw').value).toBe('');
    expect(notified).toBe(0);
  });

  it('stops waiting when the time the background says is left runs out', async () => {
    loadFixture('email-step.html');
    makeFiller().handle({ ...fill, waitMs: 4_000 });
    await vi.advanceTimersByTimeAsync(4_001);
    document.getElementById('step')?.insertAdjacentHTML('beforeend', '<input id="pw" type="password">');
    await vi.advanceTimersByTimeAsync(500);
    expect(input('pw').value).toBe('');
  });

  it('refuses a fill for another origin', () => {
    loadFixture('autocomplete.html');
    expect(makeFiller().handle({ ...fill, origin: 'https://evil.example' })).toEqual({ username: false, password: false });
    expect(input('user').value).toBe('');
    expect(input('pass').value).toBe('');
  });

  it('refuses a fill in a frame that is not same-origin with the top frame', () => {
    loadFixture('autocomplete.html');
    expect(makeFiller({ frameAllowed: () => false }).handle(fill)).toEqual({ username: false, password: false });
    expect(input('pass').value).toBe('');
  });
});
