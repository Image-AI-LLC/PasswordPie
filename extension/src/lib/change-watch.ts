import { parentOf } from './fields';
import { CHANGE_WATCH_MS } from './protocol';

const BUTTONS = 'button, input[type="submit"], input[type="image"], input[type="button"], [role="button"]';

/** The element and its ancestors, nearest first, crossing out of shadow roots. */
function lineage(el: Element): Element[] {
  const out: Element[] = [];
  for (let node: Element | null = el; node; node = parentOf(node)) out.push(node);
  return out;
}

/** A control that submits its form when pressed: `button` is a submit button unless its type says otherwise. */
function submitsForm(el: Element): HTMLFormElement | null {
  if (el instanceof HTMLButtonElement) return el.type === 'submit' ? el.form : null;
  if (el instanceof HTMLInputElement) return el.type === 'submit' || el.type === 'image' ? el.form : null;
  return null;
}

/** The browser keeps an invalid form from being submitted, unless the form or the button says not to check. */
function heldBack(form: HTMLFormElement, control: Element): boolean {
  if (form.noValidate) return false;
  if ((control instanceof HTMLButtonElement || control instanceof HTMLInputElement) && control.formNoValidate) return false;
  // Read, not checkValidity(): that would fire the page's `invalid` events a second time.
  return [...form.elements].some(
    (el) => (el instanceof HTMLInputElement || el instanceof HTMLSelectElement || el instanceof HTMLTextAreaElement) && el.willValidate && !el.validity.valid,
  );
}

/**
 * After the new password went into a page: notices the person submitting that form, and says so once. It presses
 * nothing and reads nothing but whether the boxes still hold the password it put there. Watches for 10 minutes.
 */
export class ChangeWatch {
  private readonly fields = new Set<HTMLInputElement>();
  private readonly forms = new Set<HTMLFormElement>();
  private timer: ReturnType<typeof setTimeout> | undefined;
  private stopped = false;

  constructor(
    private readonly document: Document,
    private readonly newPassword: string,
    private readonly report: () => void,
  ) {
    // Capture, so a page that stops the event in its own handler is still seen.
    document.addEventListener('click', this.onClick, true);
    document.addEventListener('keydown', this.onKeydown, true);
    this.timer = setTimeout(() => this.stop(), CHANGE_WATCH_MS);
  }

  /** A box the new password was filled into. */
  add(el: HTMLInputElement): void {
    if (this.stopped) return;
    this.fields.add(el);
    const form = el.form;
    if (form && !this.forms.has(form)) {
      this.forms.add(form);
      // On the form itself: `submit` does not leave a shadow root.
      form.addEventListener('submit', this.onSubmit, true);
    }
  }

  stop(): void {
    this.stopped = true;
    this.document.removeEventListener('click', this.onClick, true);
    this.document.removeEventListener('keydown', this.onKeydown, true);
    for (const form of this.forms) form.removeEventListener('submit', this.onSubmit, true);
    this.forms.clear();
    this.fields.clear();
    if (this.timer !== undefined) clearTimeout(this.timer);
    this.timer = undefined;
  }

  private readonly onSubmit = (event: Event): void => {
    const form = event.target;
    if (form instanceof HTMLFormElement && event.currentTarget === form) this.signal(form);
  };

  private readonly onClick = (event: Event): void => {
    const control = event.composedPath().find((node): node is Element => node instanceof Element && node.matches(BUTTONS));
    if (control) this.pressed(control);
  };

  // A page that submits by script may listen for Enter itself, with no click and no `submit`.
  private readonly onKeydown = (event: KeyboardEvent): void => {
    if (event.key !== 'Enter' || event.isComposing) return;
    const target = event.composedPath()[0];
    if (!(target instanceof Element)) return;
    if (target.matches(BUTTONS)) this.pressed(target);
    else if (target instanceof HTMLInputElement && this.fields.has(target) && !target.form) this.signal(null);
  };

  private pressed(control: Element): void {
    const form = submitsForm(control);
    if (form && this.forms.has(form)) {
      if (!heldBack(form, control)) this.signal(form);
      return;
    }
    // Boxes outside any form: the page submits by script, from some button next to them.
    const container = this.looseContainer();
    if (container && lineage(control).includes(container)) this.signal(null);
  }

  /** The nearest element that holds every box outside a form, and a button. */
  private looseContainer(): Element | null {
    const loose = [...this.fields].filter((el) => !el.form);
    const [first, ...rest] = loose;
    if (!first) return null;
    const others = rest.map(lineage);
    return (
      lineage(first)
        .slice(1)
        .find((node) => others.every((line) => line.includes(node)) && node.querySelector(BUTTONS) !== null) ?? null
    );
  }

  /** The form (or, for `null`, the boxes outside any form) is being submitted. */
  private signal(form: HTMLFormElement | null): void {
    if (this.stopped) return;
    // Only while a box still holds the password filled: one the person typed over is not the app's to ask about.
    const holds = [...this.fields].some((el) => el.form === form && el.value === this.newPassword);
    if (!holds) return;
    this.stop();
    this.report();
  }
}
