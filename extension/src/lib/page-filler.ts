import { ChangeWatch } from './change-watch';
import { findChangeFields, findLoginFields } from './fields';
import { submitForm } from './form-submit';
import type { FillMessage, FillResult } from './protocol';

export const WAIT_FOR_FIELDS_MS = 30_000;
export const POLL_MS = 250;
/**
 * An agent's login on a page that shows only the username (a two-step sign-in): how long to wait for a password field
 * before pressing Next. The password then goes in on the next page, or when the same page shows its field.
 */
export const USERNAME_SUBMIT_DELAY_MS = 800;

export interface PageEnv {
  document: Document;
  /** `location.origin` of this frame. */
  origin: string;
  /** True in the top frame, or in a frame that is same-origin with the top frame. */
  frameAllowed: () => boolean;
  /** Tells the background the password filled after the answer was sent, and whether the form was then sent. */
  notifyPasswordFilled: (submitted: boolean) => void;
  /** Tells the background the form the new password went into is being submitted. */
  notifyChanged?: () => void;
  now?: () => number;
}

const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;

/** Sets the value the way typing would, so React/Vue controlled inputs see it. Never submits. */
export function fillInput(el: HTMLInputElement, value: string): void {
  el.focus();
  if (valueSetter) valueSetter.call(el, value);
  else el.value = value;
  el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
  el.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
}

/** Waiting for fields to appear after a fill arrived: two-step sign-in or an SPA still rendering. */
class Session {
  private usernameEl: HTMLInputElement | null = null;
  private passwordFilled = false;
  /** An agent's login: the form was sent after the password, or the username-only step was. Each at most once. */
  private submitted = false;
  private usernameSubmitted = false;
  private usernameTimer: ReturnType<typeof setTimeout> | undefined;
  /** Change mode: the boxes already filled, so a later look does not write over what the person typed since. */
  private readonly filled = new Set<HTMLInputElement>();
  /** Change mode: the boxes given the new password. */
  private readonly freshFilled = new Set<HTMLInputElement>();
  private observer: MutationObserver | undefined;
  private poll: ReturnType<typeof setInterval> | undefined;
  private queued: ReturnType<typeof setTimeout> | undefined;
  private readonly deadline: number;

  constructor(
    private readonly env: PageEnv,
    private readonly msg: FillMessage,
    private readonly now: () => number,
    /** A box took the new password. */
    private readonly newPasswordFilled: (el: HTMLInputElement) => void,
  ) {
    this.deadline = now() + Math.min(msg.waitMs ?? WAIT_FOR_FIELDS_MS, WAIT_FOR_FIELDS_MS);
  }

  /** Fills what is there now; keeps watching for the rest. */
  begin(): FillResult {
    this.attempt();
    const result: FillResult = { username: this.usernameEl !== null, password: this.passwordFilled };
    if (this.submitted) result.submitted = true;
    // A fill with a new password keeps looking: a page may show or enable its confirm box only once the new one is filled.
    if (!this.passwordFilled || this.msg.newPassword !== undefined) this.watch();
    if (!this.passwordFilled) this.planUsernameSubmit();
    return result;
  }

  /** An agent's login on a username-only page: press Next if no password field shows up in a moment. Once. */
  private planUsernameSubmit(): void {
    if (this.msg.submit !== true || this.usernameEl === null || this.usernameSubmitted) return;
    this.usernameTimer = setTimeout(() => {
      this.usernameTimer = undefined;
      const username = this.usernameEl;
      if (this.passwordFilled || this.usernameSubmitted || !username?.isConnected || this.now() > this.deadline) return;
      this.usernameSubmitted = true;
      submitForm(username);
    }, USERNAME_SUBMIT_DELAY_MS);
  }

  stop(): void {
    this.observer?.disconnect();
    this.observer = undefined;
    if (this.poll !== undefined) clearInterval(this.poll);
    this.poll = undefined;
    if (this.queued !== undefined) clearTimeout(this.queued);
    this.queued = undefined;
    if (this.usernameTimer !== undefined) clearTimeout(this.usernameTimer);
    this.usernameTimer = undefined;
  }

  private attempt(): void {
    if (this.msg.newPassword !== undefined) {
      this.attemptChange(this.msg.newPassword);
      return;
    }
    const { username, password } = findLoginFields(this.env.document);
    if (username && username !== this.usernameEl) {
      fillInput(username, this.msg.username);
      this.usernameEl = username;
    }
    if (password) {
      fillInput(password, this.msg.password);
      this.passwordFilled = true;
      // An agent's login asked for the form to be sent: its own button, once, right after the password went in.
      if (this.msg.submit === true && !this.submitted) this.submitted = submitForm(password);
    }
  }

  /**
   * A fill with a new password: the current one where the page asks for it, the new one in the new and confirm boxes.
   * Done once the new password is in; a sign-in page on the way gets the current one and the fill stays for the next page.
   */
  private attemptChange(newPassword: string): void {
    const { username, current, fresh } = findChangeFields(this.env.document);
    if (this.passwordFilled) {
      // The new password is in: only a box that belongs with one still holding it is filled now (a confirm box shown
      // late), and it goes into two boxes at most. A sign-in the page shows after the change is not this fill's.
      const held = [...this.freshFilled].filter((el) => el.isConnected && el.value === newPassword);
      for (const el of fresh) {
        if (held.length >= 2) break;
        if (this.filled.has(el) || !held.some((other) => other.form === el.form)) continue;
        this.fillFresh(el, newPassword);
        held.push(el);
      }
      return;
    }
    if (username && username !== this.usernameEl) {
      fillInput(username, this.msg.username);
      this.usernameEl = username;
    }
    if (current && !this.filled.has(current)) {
      fillInput(current, this.msg.password);
      this.filled.add(current);
    }
    for (const el of fresh) {
      if (this.filled.has(el)) continue;
      this.fillFresh(el, newPassword);
    }
  }

  private fillFresh(el: HTMLInputElement, newPassword: string): void {
    fillInput(el, newPassword);
    this.filled.add(el);
    this.freshFilled.add(el);
    this.passwordFilled = true;
    this.newPasswordFilled(el);
  }

  private watch(): void {
    const view = this.env.document.defaultView;
    const change = this.msg.newPassword !== undefined;
    const check = (): void => {
      const before = this.passwordFilled;
      if (before && !change) return;
      if (this.now() > this.deadline) {
        this.stop();
        return;
      }
      this.attempt();
      if (this.passwordFilled && !before) {
        if (!change) this.stop();
        this.env.notifyPasswordFilled(this.submitted);
      }
    };
    // At most one scan per 100 ms however busy the page is. Only added and removed nodes wake it; a field shown by a
    // class or style change is found by the poll below, so animations and style churn cost nothing.
    const queue = (): void => {
      if (this.queued !== undefined) return;
      this.queued = setTimeout(() => {
        this.queued = undefined;
        check();
      }, 100);
    };
    if (view) {
      this.observer = new view.MutationObserver(queue);
      this.observer.observe(this.env.document, { childList: true, subtree: true });
    }
    // Shadow roots do not report to the document's observer, and attribute changes are not observed.
    this.poll = setInterval(check, POLL_MS);
  }
}

/** The content script's fill logic, one per frame. */
export class PageFiller {
  private session: Session | undefined;
  private changeWatch: ChangeWatch | undefined;

  constructor(private readonly env: PageEnv) {}

  handle(msg: FillMessage): FillResult {
    if (msg.origin !== this.env.origin || !this.env.frameAllowed()) return { username: false, password: false };
    this.stop();
    const { notifyChanged } = this.env;
    // The origin and frame checks above are the only way here: the new password goes where the current one may.
    const changeWatch =
      msg.newPassword !== undefined && notifyChanged ? new ChangeWatch(this.env.document, msg.newPassword, notifyChanged) : undefined;
    this.changeWatch = changeWatch;
    this.session = new Session(this.env, msg, this.env.now ?? Date.now, (el) => changeWatch?.add(el));
    return this.session.begin();
  }

  stop(): void {
    this.session?.stop();
    this.session = undefined;
    this.changeWatch?.stop();
    this.changeWatch = undefined;
  }
}

/** Top frame, or a frame whose top is the same origin. */
export function sameOriginWithTop(win: Window): boolean {
  if (win.top === win) return true;
  try {
    return win.top !== null && win.top.location.origin === win.location.origin;
  } catch {
    return false;
  }
}
