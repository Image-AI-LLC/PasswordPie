// Sending a sign-in form for an agent's login (docs/BROWSER_EXTENSION.md, "Agent logins"). Only after a fill the app
// marked `submit`, which only an approved `passwordpie login --submit` asks for. The form is sent the way a person would:
// its own button is pressed, so the site's handlers and validation run.

const BUTTON_WORDS = /^(sign[\s-]?in|log[\s-]?in|login|next|continue|submit|go)$/i;
/** The buttons of a username-only step of a sign-in. Narrower than the above: never Submit or Go. */
const NEXT_WORDS = /^(next|continue|sign[\s-]?in|log[\s-]?in|login)$/i;
/** How far up from the fields a button without a form is looked for. */
const NEARBY_LEVELS = 4;

function isShown(el: HTMLElement): boolean {
  if (el.hidden || el.getAttribute('aria-hidden') === 'true') return false;
  const view = el.ownerDocument.defaultView;
  if (!view) return false;
  if (typeof el.checkVisibility === 'function' && !el.checkVisibility({ visibilityProperty: true })) return false;
  for (let node: Element | null = el; node; node = node.parentElement) {
    if (node.hasAttribute('hidden')) return false;
    const style = view.getComputedStyle(node);
    if (style.display === 'none' || style.visibility === 'hidden') return false;
  }
  return true;
}

function enabled(el: HTMLElement): boolean {
  return !(el as HTMLButtonElement).disabled && el.getAttribute('aria-disabled') !== 'true';
}

function label(el: HTMLElement): string {
  const text = el instanceof HTMLInputElement ? el.value : (el.textContent ?? '');
  return (text || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();
}

/** The form's submit button: an explicit one first, then a `<button>` with no type (which submits by default). */
function formButton(form: HTMLFormElement): HTMLElement | undefined {
  const all = [...form.querySelectorAll<HTMLElement>('button, input[type="submit"], input[type="image"]')];
  // Buttons outside the form that name it with `form="…"` belong to it too.
  if (form.id) all.push(...form.ownerDocument.querySelectorAll<HTMLElement>(`[form="${CSS.escape(form.id)}"]`));
  const submits = all.filter((el) => {
    if (el instanceof HTMLButtonElement) return el.type === 'submit';
    return el instanceof HTMLInputElement && (el.type === 'submit' || el.type === 'image');
  });
  return submits.find((el) => isShown(el) && enabled(el));
}

/** No form around the field (a page built from divs): a button near it that says sign in, next or the like. */
function nearbyButton(field: HTMLInputElement, words = BUTTON_WORDS): HTMLElement | undefined {
  let scope: Element | null = field.parentElement;
  for (let level = 0; scope && level < NEARBY_LEVELS; level += 1) {
    const found = [...scope.querySelectorAll<HTMLElement>('button, [role="button"], input[type="button"], input[type="submit"]')].find(
      (el) => words.test(label(el)) && isShown(el) && enabled(el),
    );
    if (found) return found;
    // The body is the last place looked: never the whole document's `<html>`.
    if (scope === field.ownerDocument.body) break;
    scope = scope.parentElement;
  }
  return undefined;
}

/**
 * A username-only step of a sign-in (the password comes on the next page): presses its Next or Sign in button, in the
 * field's form or next to it. Nothing else: no `requestSubmit`, and no button that says anything else, since a lone
 * email field may as well be a password reset or a newsletter form. True when a button was pressed.
 */
export function pressNext(field: HTMLInputElement): boolean {
  const form = field.form ?? field.closest('form');
  const scope: ParentNode = form ?? field;
  const candidates = form ? [...form.querySelectorAll<HTMLElement>('button, input[type="submit"], input[type="image"], [role="button"]')] : [];
  // Buttons outside the form that name it with `form="…"` belong to it too.
  if (form?.id) candidates.push(...form.ownerDocument.querySelectorAll<HTMLElement>(`button[form="${CSS.escape(form.id)}"], input[form="${CSS.escape(form.id)}"]`));
  const inForm = candidates.find((el) => NEXT_WORDS.test(label(el)) && isShown(el) && enabled(el));
  const button = inForm ?? (scope === field ? nearbyButton(field, NEXT_WORDS) : undefined);
  if (!button) return false;
  button.click();
  return true;
}

/**
 * Sends the form `field` is in, as pressing its button would. True when something was pressed or the form was sent. Never
 * types, never presses Return, and never sends a form of another origin (the content script runs only where the fill may).
 */
export function submitForm(field: HTMLInputElement): boolean {
  const form = field.form ?? field.closest('form');
  if (form) {
    const button = formButton(form);
    if (button) {
      button.click();
      return true;
    }
    if (typeof form.requestSubmit === 'function') form.requestSubmit();
    else form.submit();
    return true;
  }
  const button = nearbyButton(field);
  if (!button) return false;
  button.click();
  return true;
}
