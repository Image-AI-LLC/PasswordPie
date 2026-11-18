// Sending a sign-in form for an agent's login (docs/BROWSER_EXTENSION.md, "Agent logins"). Only after a fill the app
// marked `submit`, which only an approved `passwordpie login --submit` asks for. The form is sent the way a person would:
// its own button is pressed, so the site's handlers and validation run.

const BUTTON_WORDS = /^(sign[\s-]?in|log[\s-]?in|login|next|continue|submit|go)$/i;

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
    return true;
  });
  return submits.find((el) => isShown(el) && enabled(el));
}

/** No form around the field (a page built from divs): a button near it that says sign in, next or the like. */
function nearbyButton(field: HTMLInputElement): HTMLElement | undefined {
  for (let scope: Element | null = field.parentElement; scope; scope = scope.parentElement) {
    const found = [...scope.querySelectorAll<HTMLElement>('button, [role="button"], input[type="button"]')].find(
      (el) => BUTTON_WORDS.test(label(el)) && isShown(el) && enabled(el),
    );
    if (found) return found;
  }
  return undefined;
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
