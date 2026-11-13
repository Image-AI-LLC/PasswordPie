import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PageFiller, type PageEnv } from '../src/lib/page-filler';
import type { FillMessage } from '../src/lib/protocol';
import { input, loadFixture } from './helpers';

const ORIGIN = 'https://example.com';
const fill: FillMessage = { type: 'fill', origin: ORIGIN, username: 'octocat', password: 's3cret', newPassword: 'N3w-pass' };

let filler: PageFiller | undefined;
let notified = 0;
let changed = 0;
let submits = 0;

function makeFiller(overrides: Partial<PageEnv> = {}): PageFiller {
  filler = new PageFiller({
    document,
    origin: location.origin,
    frameAllowed: () => true,
    notifyPasswordFilled: () => {
      notified += 1;
    },
    notifyChanged: () => {
      changed += 1;
    },
    ...overrides,
  });
  return filler;
}

function button(id: string): HTMLElement {
  const el = document.getElementById(id);
  if (!el) throw new Error(`no #${id}`);
  return el;
}

/** Counts submits and keeps jsdom from navigating. */
function countSubmits(): void {
  for (const form of document.querySelectorAll('form')) {
    form.addEventListener('submit', (e) => {
      submits += 1;
      e.preventDefault();
    });
  }
}

function pressEnter(el: HTMLElement): void {
  el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, composed: true }));
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'Date'] });
  document.body.innerHTML = '';
  notified = 0;
  changed = 0;
  submits = 0;
});

afterEach(() => {
  filler?.stop();
  filler = undefined;
  vi.useRealTimers();
});

describe('PageFiller with a new password', () => {
  it('fills the current password, and the new one in the new and confirm boxes, and never submits', () => {
    loadFixture('change-password-page.html');
    countSubmits();
    const events: string[] = [];
    for (const id of ['current', 'new', 'confirm']) {
      for (const type of ['input', 'change']) input(id).addEventListener(type, () => events.push(`${id}:${type}`));
    }

    expect(makeFiller().handle(fill)).toEqual({ username: false, password: true });
    expect(input('current').value).toBe('s3cret');
    expect(input('new').value).toBe('N3w-pass');
    expect(input('confirm').value).toBe('N3w-pass');
    expect(input('site-search').value).toBe('');
    expect(events).toEqual(['current:input', 'current:change', 'new:input', 'new:change', 'confirm:input', 'confirm:change']);
    expect(submits).toBe(0);
    expect(changed).toBe(0);
  });

  it('a reset by email: both boxes get the new password, and the current one goes nowhere', () => {
    loadFixture('change-reset-by-email.html');
    expect(makeFiller().handle(fill)).toEqual({ username: false, password: true });
    expect(input('new').value).toBe('N3w-pass');
    expect(input('confirm').value).toBe('N3w-pass');
  });

  it('three boxes with no hints: current, new, confirm', () => {
    loadFixture('change-unmarked-three.html');
    makeFiller().handle(fill);
    expect(input('old').value).toBe('s3cret');
    expect(input('new').value).toBe('N3w-pass');
    expect(input('confirm').value).toBe('N3w-pass');
  });

  it('a sign-in on the way gets the current password only, and the fill stays for the next page', async () => {
    loadFixture('autocomplete.html');
    expect(makeFiller().handle(fill)).toEqual({ username: true, password: false });
    expect(input('user').value).toBe('octocat');
    expect(input('pass').value).toBe('s3cret');

    // What the person types afterwards is theirs: the watch does not fill the box again.
    input('pass').value = 'typed';
    await vi.advanceTimersByTimeAsync(1_000);
    expect(input('pass').value).toBe('typed');
    expect(notified).toBe(0);
  });

  it('a sign-in with one unmarked box gets the current password, never the new one, and nothing is told', () => {
    loadFixture('plain.html');
    countSubmits();
    expect(makeFiller().handle(fill)).toEqual({ username: true, password: false });
    expect(input('user').value).toBe('octocat');
    expect(input('pass').value).toBe('s3cret');
    document.querySelector('form')?.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    expect(submits).toBe(1);
    expect(changed).toBe(0);
    expect(notified).toBe(0);
  });

  it('waits for a form that renders late', async () => {
    expect(makeFiller().handle(fill)).toEqual({ username: false, password: false });
    await vi.advanceTimersByTimeAsync(1_000);
    loadFixture('change-password-page.html');
    await vi.advanceTimersByTimeAsync(100);
    expect(input('current').value).toBe('s3cret');
    expect(input('new').value).toBe('N3w-pass');
    expect(input('confirm').value).toBe('N3w-pass');
    expect(notified).toBe(1);
  });

  it('refuses another origin and a frame that is not same-origin with the top frame', () => {
    loadFixture('change-password-page.html');
    countSubmits();
    expect(makeFiller().handle({ ...fill, origin: 'https://evil.example' })).toEqual({ username: false, password: false });
    expect(makeFiller({ frameAllowed: () => false }).handle(fill)).toEqual({ username: false, password: false });
    for (const id of ['current', 'new', 'confirm']) expect(input(id).value, id).toBe('');
    button('go').click();
    expect(changed).toBe(0);
  });

  it('without a new password a change-password page is filled as before, and nothing is watched', () => {
    loadFixture('change-password-page.html');
    countSubmits();
    const { newPassword: _none, ...plain } = fill;
    expect(makeFiller().handle(plain)).toEqual({ username: false, password: true });
    expect(input('current').value).toBe('s3cret');
    expect(input('new').value).toBe('');
    expect(input('confirm').value).toBe('');
    button('go').click();
    expect(submits).toBe(1);
    expect(changed).toBe(0);
  });
});

describe('telling the app the form was submitted', () => {
  it('says so once when the form is submitted', () => {
    loadFixture('change-password-page.html');
    countSubmits();
    makeFiller().handle(fill);
    button('go').click();
    button('go').click();
    expect(submits).toBe(2);
    expect(changed).toBe(1);
  });

  it('a submit event alone is enough: Enter in a box', () => {
    loadFixture('change-password-page.html');
    countSubmits();
    makeFiller().handle(fill);
    document.getElementById('change')?.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    expect(changed).toBe(1);
  });

  it('a click on the submit button counts when the page sends the form by script, with no submit event', () => {
    loadFixture('change-password-page.html');
    makeFiller().handle(fill);
    // The page's own handler takes the click and stops it.
    button('go').addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
    });
    button('go').click();
    expect(changed).toBe(1);
  });

  it('Enter on the submit button counts', () => {
    loadFixture('change-password-page.html');
    makeFiller().handle(fill);
    pressEnter(button('go'));
    expect(changed).toBe(1);
  });

  it('other buttons do not count: Show in the form, a menu outside it', () => {
    loadFixture('change-password-page.html');
    makeFiller().handle(fill);
    button('show').click();
    button('menu').click();
    pressEnter(button('show'));
    expect(changed).toBe(0);
  });

  it('says nothing when no new password went in: a sign-in on the way', () => {
    loadFixture('autocomplete.html');
    countSubmits();
    makeFiller().handle(fill);
    document.querySelector('form')?.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    expect(submits).toBe(1);
    expect(changed).toBe(0);
  });

  it('says nothing when the person typed another password over the one filled', () => {
    loadFixture('change-password-page.html');
    countSubmits();
    makeFiller().handle(fill);
    input('new').value = 'my-own';
    input('confirm').value = 'my-own';
    button('go').click();
    expect(changed).toBe(0);
  });

  it('says nothing when the browser holds the form back as invalid', () => {
    loadFixture('change-password-page.html');
    document.getElementById('change')?.insertAdjacentHTML('afterbegin', '<input id="agree" type="checkbox" required>');
    // jsdom would submit all the same; a browser shows its bubble on the empty box instead, and no submit follows.
    button('go').addEventListener('click', (e) => e.preventDefault());
    makeFiller().handle(fill);
    button('go').click();
    expect(changed).toBe(0);
    input('agree').checked = true;
    button('go').click();
    expect(changed).toBe(1);
  });

  it('boxes outside any form: a button next to them counts, one elsewhere on the page does not', () => {
    loadFixture('change-scripted.html');
    makeFiller().handle(fill);
    expect(input('new').value).toBe('N3w-pass');
    button('menu').click();
    expect(changed).toBe(0);
    button('go').click();
    button('go').click();
    expect(changed).toBe(1);
  });

  it('boxes outside any form: Enter in a filled box counts', () => {
    loadFixture('change-scripted.html');
    makeFiller().handle(fill);
    pressEnter(input('confirm'));
    expect(changed).toBe(1);
  });

  it('a form filled late is watched too', async () => {
    makeFiller().handle(fill);
    await vi.advanceTimersByTimeAsync(1_000);
    loadFixture('change-password-page.html');
    countSubmits();
    await vi.advanceTimersByTimeAsync(100);
    button('go').click();
    expect(changed).toBe(1);
  });

  it('stops watching after 10 minutes', async () => {
    loadFixture('change-password-page.html');
    countSubmits();
    makeFiller().handle(fill);
    await vi.advanceTimersByTimeAsync(600_001);
    button('go').click();
    expect(submits).toBe(1);
    expect(changed).toBe(0);
  });

  it('stops watching when the filler is stopped', () => {
    loadFixture('change-password-page.html');
    countSubmits();
    makeFiller().handle(fill);
    filler?.stop();
    button('go').click();
    expect(changed).toBe(0);
  });
});
