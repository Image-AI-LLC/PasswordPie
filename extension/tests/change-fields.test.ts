import { beforeEach, describe, expect, it } from 'vitest';
import { findChangeFields } from '../src/lib/fields';
import { input, loadFixture } from './helpers';

beforeEach(() => {
  document.body.innerHTML = '';
});

describe('findChangeFields', () => {
  it('goes by autocomplete: the current password, and every new-password box', () => {
    loadFixture('change-password.html');
    const fields = findChangeFields(document);
    expect(fields.current).toBe(input('current'));
    expect(fields.fresh).toEqual([input('new'), input('confirm')]);
    expect(fields.username).toBeNull(); // the username field is readonly
  });

  it('two unmarked boxes are new and confirm: a reset by email asks for no current password', () => {
    loadFixture('change-reset-by-email.html');
    const fields = findChangeFields(document);
    expect(fields.current).toBeNull();
    expect(fields.fresh).toEqual([input('new'), input('confirm')]);
  });

  it('three unmarked boxes are current, new and confirm', () => {
    loadFixture('change-unmarked-three.html');
    const fields = findChangeFields(document);
    expect(fields.current).toBe(input('old'));
    expect(fields.fresh).toEqual([input('new'), input('confirm')]);
  });

  it('of more than three unmarked boxes, the first is current and the last two are new', () => {
    document.body.innerHTML = ['a', 'b', 'c', 'd'].map((id) => `<input id="${id}" type="password">`).join('');
    const fields = findChangeFields(document);
    expect(fields.current).toBe(input('a'));
    expect(fields.fresh).toEqual([input('c'), input('d')]);
  });

  it('a single unmarked box is a sign-in on the way: it takes the current password, never the new one', () => {
    loadFixture('plain.html');
    const fields = findChangeFields(document);
    expect(fields.current).toBe(input('pass'));
    expect(fields.fresh).toEqual([]);
    expect(fields.username).toBe(input('user'));
  });

  it('a single box marked new-password is the new password', () => {
    document.body.innerHTML = '<input id="only" type="password" autocomplete="new-password">';
    expect(findChangeFields(document)).toEqual({ username: null, current: null, fresh: [input('only')] });
  });

  it('a single box marked current-password is a sign-in on the way: it never gets the new password', () => {
    loadFixture('autocomplete.html');
    const fields = findChangeFields(document);
    expect(fields.current).toBe(input('pass'));
    expect(fields.fresh).toEqual([]);
    expect(fields.username).toBe(input('user'));
  });

  it('a box marked current-password is never a new one, whatever its place', () => {
    document.body.innerHTML = '<input id="new" type="password"><input id="old" type="password" autocomplete="current-password">';
    const fields = findChangeFields(document);
    expect(fields.current).toBe(input('old'));
    expect(fields.fresh).toEqual([input('new')]);
  });

  it('marked new boxes with an unmarked one before them: of three, the first is current', () => {
    document.body.innerHTML =
      '<input id="old" type="password"><input id="new" type="password" autocomplete="new-password"><input id="confirm" type="password" autocomplete="new-password">';
    const fields = findChangeFields(document);
    expect(fields.current).toBe(input('old'));
    expect(fields.fresh).toEqual([input('new'), input('confirm')]);
  });

  it('leaves hidden, disabled and readonly boxes out of the count', () => {
    document.body.innerHTML = `
      <input id="ghost" type="password" style="display:none">
      <input id="off" type="password" disabled>
      <input id="new" type="password">
      <input id="confirm" type="password">`;
    const fields = findChangeFields(document);
    expect(fields.current).toBeNull();
    expect(fields.fresh).toEqual([input('new'), input('confirm')]);
  });

  it('finds no box on a page without a password field', () => {
    loadFixture('email-step.html');
    const fields = findChangeFields(document);
    expect(fields.current).toBeNull();
    expect(fields.fresh).toEqual([]);
    expect(fields.username).toBe(input('email'));
  });
});
