// Finds and fills the two-step code field of a page: one field, or one box per digit. Only looked for after PasswordPie
// filled an account that has a code, on that account's origin (docs/BROWSER_EXTENSION.md, "Two-step codes").
import { collectInputs, findLoginFields, isSearch, isUsable, tokens } from './fields';
import { fillInput } from './page-filler';

export type CodeField = { kind: 'single'; input: HTMLInputElement } | { kind: 'split'; inputs: HTMLInputElement[] };

const CODE_TYPES = new Set(['text', 'tel', 'number']);
const CODE_HINT =
  /otp|totp|one.?time|2fa|two.?(factor|step)|mfa|multi.?factor|verif|auth(entication|enticator)?.?code|security.?code|passcode|\bcode\b|\botc\b/i;
const NOT_CODE = /zip|postal|post.?code|promo|coupon|voucher|discount|gift|referr|invite|country|area|captcha|phone|mobile|card|cvc|cvv/i;
const MIN_SPLIT = 4;
const MAX_SPLIT = 8;

function labelText(el: HTMLInputElement): string {
  const labels = Array.from(el.labels ?? []).map((label) => label.textContent ?? '');
  return [el.name, el.id, el.placeholder, el.getAttribute('aria-label') ?? '', ...labels].join(' ');
}

function isCodeType(el: HTMLInputElement): boolean {
  return CODE_TYPES.has(el.type) && !isSearch(el) && !tokens(el).some((t) => t === 'username' || t === 'email');
}

function hinted(el: HTMLInputElement): boolean {
  if (tokens(el).includes('one-time-code')) return true;
  const text = labelText(el);
  return CODE_HINT.test(text) && !NOT_CODE.test(text);
}

/** A field that only takes 6 to 8 characters, digits by the look of it. */
function codeShaped(el: HTMLInputElement): boolean {
  const numeric = el.inputMode === 'numeric' || el.type === 'tel' || el.type === 'number' || /\d/.test(el.pattern);
  return numeric && el.maxLength >= 6 && el.maxLength <= 8 && !NOT_CODE.test(labelText(el));
}

/** Runs of 4 to 8 one-character boxes next to each other in document order. */
function splitRun(inputs: HTMLInputElement[]): HTMLInputElement[] | null {
  let run: HTMLInputElement[] = [];
  const done = (): HTMLInputElement[] | null => (run.length >= MIN_SPLIT && run.length <= MAX_SPLIT ? run : null);
  for (const el of inputs) {
    if (isCodeType(el) && el.maxLength === 1 && !NOT_CODE.test(labelText(el)) && (run.length === 0 || run[0]?.form === el.form)) {
      run.push(el);
      continue;
    }
    const found = done();
    if (found) return found;
    run = isCodeType(el) && el.maxLength === 1 ? [el] : [];
  }
  return done();
}

export function findCodeField(root: Document | ShadowRoot | Element): CodeField | null {
  const login = findLoginFields(root);
  const inputs = collectInputs(root)
    .filter(isUsable)
    .filter((el) => el !== login.username && el !== login.password);
  const candidates = inputs.filter(isCodeType);

  // Split boxes often mark the first box (or each one) with one-time-code: the whole run is the field then.
  const split = splitRun(inputs);
  const byAutocomplete = candidates.find((el) => tokens(el).includes('one-time-code'));
  if (byAutocomplete && !split?.includes(byAutocomplete)) return { kind: 'single', input: byAutocomplete };
  if (split) return { kind: 'split', inputs: split };

  const byHint = candidates.filter((el) => el.maxLength !== 1 && hinted(el));
  if (byHint.length === 1 && byHint[0]) return { kind: 'single', input: byHint[0] };

  // A field shaped like a code, with nothing else on the page: only when no sign-in field is in sight.
  if (login.username || login.password) return null;
  const shaped = candidates.filter(codeShaped);
  return shaped.length === 1 && candidates.length === 1 && shaped[0] ? { kind: 'single', input: shaped[0] } : null;
}

/** True when the field is still empty: the user has not typed a code. */
export function codeFieldIsEmpty(field: CodeField): boolean {
  return field.kind === 'single' ? field.input.value === '' : field.inputs.every((el) => el.value === '');
}

/** Fills the code the way typing would. Never submits. False when it does not fit the boxes. */
export function fillCode(field: CodeField, code: string): boolean {
  if (field.kind === 'single') {
    if (field.input.maxLength > 0 && code.length > field.input.maxLength) return false;
    fillInput(field.input, code);
    return true;
  }
  if (code.length > field.inputs.length) return false;
  [...code].forEach((digit, index) => {
    const box = field.inputs[index];
    if (box) fillInput(box, digit);
  });
  return true;
}
