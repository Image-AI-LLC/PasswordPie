import { afterEach, describe, expect, it } from 'vitest';
import { fillCode, findCodeField } from '../src/lib/code-fields';
import { input, loadFixture } from './helpers';

afterEach(() => {
  document.body.innerHTML = '';
});

function ids(found: ReturnType<typeof findCodeField>): string[] {
  if (!found) return [];
  return found.kind === 'single' ? [found.input.id] : found.inputs.map((el) => el.id);
}

describe('findCodeField', () => {
  it('finds autocomplete="one-time-code"', () => {
    loadFixture('code-autocomplete.html');
    expect(ids(findCodeField(document))).toEqual(['otp']);
  });

  it('finds a field by its name or id, ignoring hidden tokens and search', () => {
    loadFixture('code-named.html');
    expect(ids(findCodeField(document))).toEqual(['app_totp']);
  });

  it('finds a field by its label', () => {
    loadFixture('code-labelled.html');
    expect(ids(findCodeField(document))).toEqual(['c']);
  });

  it('finds a lone six-digit numeric field', () => {
    loadFixture('code-numeric.html');
    expect(ids(findCodeField(document))).toEqual(['c']);
  });

  it('finds a code split into one box per digit', () => {
    loadFixture('code-split.html');
    expect(ids(findCodeField(document))).toEqual(['d1', 'd2', 'd3', 'd4', 'd5', 'd6']);
  });

  it('takes the whole run when the boxes carry one-time-code, and fills one digit each', () => {
    for (const marked of ['first', 'every']) {
      document.body.innerHTML = [1, 2, 3, 4, 5, 6]
        .map((i) => `<input id="b${i}" maxlength="1" inputmode="numeric"${marked === 'every' || i === 1 ? ' autocomplete="one-time-code"' : ''}>`)
        .join('');
      const found = findCodeField(document);
      expect(ids(found)).toEqual(['b1', 'b2', 'b3', 'b4', 'b5', 'b6']);
      expect(found && fillCode(found, '123456')).toBe(true);
      expect([1, 2, 3, 4, 5, 6].map((i) => input(`b${i}`).value).join('')).toBe('123456');
    }
  });

  it('ignores zip, promo, country, phone, captcha, hidden, disabled and short box runs', () => {
    loadFixture('code-decoys.html');
    expect(findCodeField(document)).toBeNull();
  });

  it('does not take an unlabelled numeric field next to a sign-in form', () => {
    loadFixture('code-with-login.html');
    expect(findCodeField(document)).toBeNull();
  });

  it('takes a labelled code field even on the sign-in form', () => {
    document.body.innerHTML = `<form>
      <input id="user" type="email" autocomplete="username">
      <input id="pass" type="password" autocomplete="current-password">
      <input id="mfa" name="mfacode" type="text">
    </form>`;
    expect(ids(findCodeField(document))).toEqual(['mfa']);
  });

  it('never takes the username or password field', () => {
    document.body.innerHTML = `<input id="user" name="otp_user" type="email"><input id="pass" name="otp" type="password">`;
    expect(findCodeField(document)).toBeNull();
  });

  it('looks inside open shadow roots', () => {
    const host = document.createElement('div');
    document.body.append(host);
    host.attachShadow({ mode: 'open' }).innerHTML = '<input id="s" autocomplete="one-time-code">';
    const found = findCodeField(document);
    expect(found?.kind).toBe('single');
  });
});

describe('fillCode', () => {
  it('fills a single field with input and change events', () => {
    loadFixture('code-autocomplete.html');
    const events: string[] = [];
    for (const type of ['input', 'change']) input('otp').addEventListener(type, () => events.push(type));
    const found = findCodeField(document);
    expect(found && fillCode(found, '123456')).toBe(true);
    expect(input('otp').value).toBe('123456');
    expect(events).toEqual(['input', 'change']);
  });

  it('puts one digit in each box', () => {
    loadFixture('code-split.html');
    const found = findCodeField(document);
    expect(found && fillCode(found, '987654')).toBe(true);
    expect(['d1', 'd2', 'd3', 'd4', 'd5', 'd6'].map((id) => input(id).value).join('')).toBe('987654');
  });

  it('refuses a code longer than the boxes', () => {
    loadFixture('code-split.html');
    const found = findCodeField(document);
    expect(found && fillCode(found, '12345678')).toBe(false);
    expect(input('d1').value).toBe('');
  });

  it('refuses a code longer than the single field maxlength', () => {
    loadFixture('code-numeric.html');
    const found = findCodeField(document);
    expect(found && fillCode(found, '12345678')).toBe(false);
    expect(input('c').value).toBe('');
  });

  it('never submits', () => {
    loadFixture('code-autocomplete.html');
    let submitted = false;
    document.querySelector('form')?.addEventListener('submit', (e) => {
      submitted = true;
      e.preventDefault();
    });
    const found = findCodeField(document);
    if (found) fillCode(found, '123456');
    expect(submitted).toBe(false);
  });
});
