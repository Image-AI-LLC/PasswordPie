import { beforeEach, describe, expect, it } from 'vitest';
import { findLoginFields } from '../src/lib/fields';
import { input, loadFixture } from './helpers';

beforeEach(() => {
  document.body.innerHTML = '';
});

describe('findLoginFields', () => {
  it('uses autocomplete="username" and "current-password"', () => {
    loadFixture('autocomplete.html');
    const fields = findLoginFields(document);
    expect(fields.username).toBe(input('user'));
    expect(fields.password).toBe(input('pass'));
  });

  it('finds a form with no attributes and never takes the search box', () => {
    loadFixture('plain.html');
    const fields = findLoginFields(document);
    expect(fields.username).toBe(input('user'));
    expect(fields.password).toBe(input('pass'));
  });

  it('chooses the sign-in password on a sign-up + sign-in page (autocomplete hints)', () => {
    loadFixture('signup-signin.html');
    const fields = findLoginFields(document);
    expect(fields.password).toBe(input('signin-pass'));
    expect(fields.username).toBe(input('signin-email'));
  });

  it('chooses the sign-in password on a sign-up + sign-in page with no hints', () => {
    loadFixture('signup-signin-plain.html');
    const fields = findLoginFields(document);
    expect(fields.password).toBe(input('signin-pass'));
    expect(fields.username).toBe(input('signin-user'));
  });

  it('fills only the current password on a change-password page', () => {
    loadFixture('change-password.html');
    const fields = findLoginFields(document);
    expect(fields.password).toBe(input('current'));
    expect(fields.username).toBeNull(); // the username field is readonly
  });

  it('ignores hidden, disabled and readonly decoys and search boxes', () => {
    loadFixture('decoys.html');
    const fields = findLoginFields(document);
    expect(fields.username).toBe(input('user'));
    expect(fields.password).toBe(input('pass'));
  });

  it('never uses a search box as the username', () => {
    document.body.innerHTML = `
      <input id="s1" type="search" name="login">
      <div role="search"><input id="s2" type="text" name="email"></div>
      <input id="s3" type="text" name="q" autocomplete="username">`;
    expect(findLoginFields(document)).toEqual({ username: null, password: null });
  });

  it('finds the step-one email field when there is no password field', () => {
    loadFixture('email-step.html');
    const fields = findLoginFields(document);
    expect(fields.username).toBe(input('email'));
    expect(fields.password).toBeNull();
  });

  it('finds a lone username field by its name or label', () => {
    document.body.innerHTML = `<input id="acct" type="text" aria-label="Account ID"><input id="other" type="text" name="nickname">`;
    expect(findLoginFields(document).username).toBe(input('acct'));
  });

  it('takes nothing when no password field and no field looks like a username', () => {
    document.body.innerHTML = `<input type="text" name="city"><input type="text" name="zip">`;
    expect(findLoginFields(document)).toEqual({ username: null, password: null });
  });

  it('finds a login form inside an open shadow root, nested', () => {
    document.body.innerHTML = '<login-box></login-box>';
    const host = document.querySelector('login-box');
    if (!host) throw new Error('no host');
    const outer = host.attachShadow({ mode: 'open' });
    outer.innerHTML = '<div><inner-form></inner-form></div>';
    const innerHost = outer.querySelector('inner-form');
    if (!innerHost) throw new Error('no inner host');
    const inner = innerHost.attachShadow({ mode: 'open' });
    inner.innerHTML = '<form><input id="u" type="email"><input id="p" type="password"></form>';
    const fields = findLoginFields(document);
    expect(fields.username).toBe(input('u', inner));
    expect(fields.password).toBe(input('p', inner));
  });

  it('respects display:none set on a shadow host', () => {
    document.body.innerHTML = '<login-box style="display:none"></login-box>';
    const host = document.querySelector('login-box');
    if (!host) throw new Error('no host');
    host.attachShadow({ mode: 'open' }).innerHTML = '<input type="password">';
    expect(findLoginFields(document).password).toBeNull();
  });
});
