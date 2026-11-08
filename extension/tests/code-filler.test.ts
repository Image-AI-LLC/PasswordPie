import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CodeFiller, HINT_HOST_ID, HINT_MS } from '../src/lib/code-filler';
import { input, loadFixture } from './helpers';

const ORIGIN = 'https://example.com';
let filler: CodeFiller | undefined;
let found = 0;

function make(frameAllowed = true): CodeFiller {
  filler = new CodeFiller({ document, origin: location.origin, frameAllowed: () => frameAllowed, notifyCodeField: () => void (found += 1) });
  return filler;
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'Date'] });
  document.body.innerHTML = '';
  found = 0;
});

afterEach(() => {
  filler?.stop();
  filler = undefined;
  vi.useRealTimers();
});

describe('CodeFiller', () => {
  it('reports a code field that is already there', () => {
    loadFixture('code-autocomplete.html');
    make().handle({ type: 'watch-code', origin: ORIGIN, waitMs: 30_000 });
    expect(found).toBe(1);
  });

  it('reports a code field that appears later, once', async () => {
    make().handle({ type: 'watch-code', origin: ORIGIN, waitMs: 30_000 });
    expect(found).toBe(0);
    document.body.innerHTML = '<input id="otp" autocomplete="one-time-code">';
    await vi.advanceTimersByTimeAsync(300);
    expect(found).toBe(1);
    await vi.advanceTimersByTimeAsync(2_000);
    expect(found).toBe(1);
  });

  it('a second watch while still looking starts no second watcher', async () => {
    const f = make();
    f.handle({ type: 'watch-code', origin: ORIGIN, waitMs: 30_000 });
    f.handle({ type: 'watch-code', origin: ORIGIN, waitMs: 30_000 });
    document.body.innerHTML = '<input autocomplete="one-time-code">';
    await vi.advanceTimersByTimeAsync(1_000);
    expect(found).toBe(1);
  });

  it('reports again for a later watch once the code was filled', () => {
    loadFixture('code-autocomplete.html');
    const f = make();
    f.handle({ type: 'watch-code', origin: ORIGIN, waitMs: 30_000 });
    expect(found).toBe(1);
    expect(f.handle({ type: 'code', origin: ORIGIN, code: '123456' })).toBe(true);
    input('otp').value = '';
    f.handle({ type: 'watch-code', origin: ORIGIN, waitMs: 30_000 });
    expect(found).toBe(2);
  });

  it('stops looking when the wait is over', async () => {
    make().handle({ type: 'watch-code', origin: ORIGIN, waitMs: 1_000 });
    await vi.advanceTimersByTimeAsync(1_500);
    document.body.innerHTML = '<input autocomplete="one-time-code">';
    await vi.advanceTimersByTimeAsync(1_000);
    expect(found).toBe(0);
  });

  it('ignores a field the user already typed in', () => {
    loadFixture('code-autocomplete.html');
    input('otp').value = '1';
    make().handle({ type: 'watch-code', origin: ORIGIN, waitMs: 30_000 });
    expect(found).toBe(0);
  });

  it('does nothing for another origin or a cross-origin frame', () => {
    loadFixture('code-autocomplete.html');
    make().handle({ type: 'watch-code', origin: 'https://evil.example', waitMs: 30_000 });
    filler?.stop();
    make(false).handle({ type: 'watch-code', origin: ORIGIN, waitMs: 30_000 });
    expect(found).toBe(0);
    expect(make(false).handle({ type: 'code', origin: ORIGIN, code: '123456' })).toBe(false);
    expect(input('otp').value).toBe('');
  });

  it('fills the code it is sent', () => {
    loadFixture('code-split.html');
    const f = make();
    f.handle({ type: 'watch-code', origin: ORIGIN, waitMs: 30_000 });
    expect(f.handle({ type: 'code', origin: ORIGIN, code: '135790' })).toBe(true);
    expect(['d1', 'd2', 'd3', 'd4', 'd5', 'd6'].map((id) => input(id).value).join('')).toBe('135790');
  });

  it('fills nothing for a code of another origin', () => {
    loadFixture('code-autocomplete.html');
    expect(make().handle({ type: 'code', origin: 'https://evil.example', code: '123456' })).toBe(false);
    expect(input('otp').value).toBe('');
  });

  it('shows a quiet hint with an upgrade link, and it goes away', async () => {
    loadFixture('code-autocomplete.html');
    make().handle({ type: 'code-hint', origin: ORIGIN, upgradeUrl: 'https://passwordpie.com/pricing' });
    const host = document.getElementById(HINT_HOST_ID);
    expect(host).not.toBeNull();
    expect(input('otp').value).toBe('');
    expect(document.activeElement).not.toBe(host);
    await vi.advanceTimersByTimeAsync(HINT_MS + 10);
    expect(document.getElementById(HINT_HOST_ID)).toBeNull();
  });

  it('the hint carries no link when there is no upgrade URL', () => {
    make().handle({ type: 'code-hint', origin: ORIGIN });
    expect(filler?.hintText()).toContain('Premium');
    expect(filler?.hintLink()).toBeUndefined();
    make().handle({ type: 'code-hint', origin: ORIGIN, upgradeUrl: 'https://passwordpie.com/pricing' });
    expect(filler?.hintLink()).toBe('https://passwordpie.com/pricing');
  });

  it('a later pick reports again after a report that got no answer', () => {
    loadFixture('code-autocomplete.html');
    const f = make();
    f.handle({ type: 'watch-code', origin: ORIGIN, waitMs: 30_000 });
    expect(found).toBe(1);
    vi.advanceTimersByTime(10_000);
    f.handle({ type: 'watch-code', origin: ORIGIN, waitMs: 30_000 });
    expect(found).toBe(2);
  });
});
