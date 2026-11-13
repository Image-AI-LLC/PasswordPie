// Finds the sign-in fields of a page: the document and its open shadow roots.

export interface LoginFields {
  username: HTMLInputElement | null;
  password: HTMLInputElement | null;
}

const TEXT_TYPES = new Set(['text', 'email', 'tel']);
const USERNAME_HINT = /user|email|login|account|identifier|phone/i;
const SEARCH_NAMES = new Set(['q', 'search']);

/** All inputs under `root`, in document order, descending into open shadow roots. */
export function collectInputs(root: Document | ShadowRoot | Element): HTMLInputElement[] {
  const out: HTMLInputElement[] = [];
  const walk = (node: Document | ShadowRoot | Element): void => {
    for (const el of node.querySelectorAll('*')) {
      if (el instanceof HTMLInputElement) out.push(el);
      if (el.shadowRoot) walk(el.shadowRoot);
    }
  };
  if (root instanceof Element && root.shadowRoot) walk(root.shadowRoot);
  walk(root);
  return out;
}

export function tokens(el: HTMLInputElement): string[] {
  return (el.getAttribute('autocomplete') ?? '').toLowerCase().split(/\s+/).filter(Boolean);
}

/** The element's parent, crossing out of a shadow root to its host. */
export function parentOf(el: Element): Element | null {
  if (el.parentElement) return el.parentElement;
  const root = el.getRootNode();
  return root instanceof ShadowRoot ? root.host : null;
}

function isVisible(el: HTMLInputElement): boolean {
  if (el.type === 'hidden') return false;
  if (el.getAttribute('aria-hidden') === 'true') return false;
  const view = el.ownerDocument.defaultView;
  if (!view) return false;
  // Real browsers: checkVisibility covers display, content-visibility and visibility; tiny boxes are decoys.
  if (typeof el.checkVisibility === 'function') {
    if (!el.checkVisibility({ visibilityProperty: true })) return false;
    const box = el.getBoundingClientRect();
    if (box.width < 2 || box.height < 2) return false;
  }
  if (view.getComputedStyle(el).visibility === 'hidden') return false;
  for (let node: Element | null = el; node; node = parentOf(node)) {
    if (node.hasAttribute('hidden')) return false;
    if (view.getComputedStyle(node).display === 'none') return false;
  }
  return true;
}

export function isUsable(el: HTMLInputElement): boolean {
  return !el.disabled && !el.readOnly && isVisible(el);
}

export function isSearch(el: HTMLInputElement): boolean {
  if (el.type === 'search') return true;
  if (SEARCH_NAMES.has(el.name.toLowerCase())) return true;
  for (let node: Element | null = el; node; node = parentOf(node)) {
    if (node.getAttribute('role') === 'search') return true;
  }
  return false;
}

function isTextLike(el: HTMLInputElement): boolean {
  return TEXT_TYPES.has(el.type) && !isSearch(el);
}

function hasUsernameAutocomplete(el: HTMLInputElement): boolean {
  const t = tokens(el);
  return t.includes('username') || t.includes('email');
}

function looksLikeUsername(el: HTMLInputElement): boolean {
  if (el.type === 'email' || hasUsernameAutocomplete(el)) return true;
  const labels = [el.name, el.id, el.placeholder, el.getAttribute('aria-label') ?? ''];
  return labels.some((label) => USERNAME_HINT.test(label));
}

function choosePassword(passwords: HTMLInputElement[], all: HTMLInputElement[]): HTMLInputElement | null {
  const current = passwords.find((el) => tokens(el).includes('current-password'));
  if (current) return current;
  const plain = passwords.filter((el) => !tokens(el).includes('new-password'));
  const pool = plain.length > 0 ? plain : passwords;
  // A form with one password field is a sign-in; a form with two or more is sign-up or change-password.
  const passwordsInForm = (el: HTMLInputElement): number =>
    el.form ? all.filter((other) => other.type === 'password' && other.form === el.form).length : 1;
  return pool.find((el) => passwordsInForm(el) === 1) ?? pool[0] ?? null;
}

function chooseUsername(password: HTMLInputElement, inputs: HTMLInputElement[]): HTMLInputElement | null {
  const form = password.form;
  const index = inputs.indexOf(password);
  // Same form as the password, or, for a password outside any form, inputs outside any form.
  const scope = inputs.filter((el) => el !== password && isTextLike(el) && el.form === form);
  const hinted = scope.find(hasUsernameAutocomplete);
  if (hinted) return hinted;
  const before = scope.filter((el) => inputs.indexOf(el) < index);
  return before.at(-1) ?? null;
}

function chooseLoneUsername(inputs: HTMLInputElement[]): HTMLInputElement | null {
  const candidates = inputs.filter(isTextLike);
  const hinted = candidates.find(hasUsernameAutocomplete);
  if (hinted) return hinted;
  const looking = candidates.filter(looksLikeUsername);
  return looking.length === 1 ? (looking[0] ?? null) : null;
}

/** The fields of a page that changes a password (docs/UX.md, "Reset Password makes the new password for you"). */
export interface ChangeFields {
  username: HTMLInputElement | null;
  /** Where the page asks for the password it knows. */
  current: HTMLInputElement | null;
  /** The new password's boxes: the new one and its confirmation. */
  fresh: HTMLInputElement[];
}

export function findChangeFields(root: Document | ShadowRoot | Element): ChangeFields {
  const inputs = collectInputs(root).filter(isUsable);
  const passwords = inputs.filter((el) => el.type === 'password');
  const marked = passwords.filter((el) => tokens(el).includes('new-password'));
  const first = passwords[0];
  // Unmarked: three boxes are current, new, confirm. One box alone is a sign-in on the way to the page (a reset link
  // opened while signed out): it takes the current password, never the new one.
  const positional = passwords.length >= 3 || passwords.length === 1;
  const current =
    passwords.find((el) => tokens(el).includes('current-password')) ??
    (positional && first && !marked.includes(first) ? first : null);
  // Unmarked: two boxes are new and confirm (a reset by email); of three or more, the last two.
  const fresh = (marked.length > 0 ? marked : passwords.slice(-2)).filter((el) => el !== current);
  const anchor = current ?? fresh[0];
  const username = anchor ? chooseUsername(anchor, inputs) : chooseLoneUsername(inputs);
  return { username, current, fresh };
}

export function findLoginFields(root: Document | ShadowRoot | Element): LoginFields {
  const inputs = collectInputs(root).filter(isUsable);
  const passwords = inputs.filter((el) => el.type === 'password');
  const password = choosePassword(passwords, inputs);
  const username = password ? chooseUsername(password, inputs) : chooseLoneUsername(inputs);
  return { username, password };
}
