import { ChangeWatch } from './change-watch';
import { findChangeFields, findLoginFields } from './fields';
import type { FillMessage, FillResult } from './protocol';

export const WAIT_FOR_FIELDS_MS = 30_000;
export const POLL_MS = 250;

export interface PageEnv {
  document: Document;
  /** `location.origin` of this frame. */
  origin: string;
  /** True in the top frame, or in a frame that is same-origin with the top frame. */
  frameAllowed: () => boolean;
  /** Tells the background the password filled after the answer was sent. */
  notifyPasswordFilled: () => void;
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
  /** Change mode: the boxes already filled, so a later look does not write over what the person typed since. */
  private readonly filled = new Set<HTMLInputElement>();
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
    const result = { username: this.usernameEl !== null, password: this.passwordFilled };
    if (!this.passwordFilled) this.watch();
    return result;
  }

  stop(): void {
    this.observer?.disconnect();
    this.observer = undefined;
    if (this.poll !== undefined) clearInterval(this.poll);
    this.poll = undefined;
    if (this.queued !== undefined) clearTimeout(this.queued);
    this.queued = undefined;
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
    }
  }

  /**
   * A fill with a new password: the current one where the page asks for it, the new one in the new and confirm boxes.
   * Done once the new password is in; a sign-in page on the way gets the current one and the fill stays for the next page.
   */
  private attemptChange(newPassword: string): void {
    const { username, current, fresh } = findChangeFields(this.env.document);
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
      fillInput(el, newPassword);
      this.filled.add(el);
      this.passwordFilled = true;
      this.newPasswordFilled(el);
    }
  }

  private watch(): void {
    const view = this.env.document.defaultView;
    const check = (): void => {
      if (this.passwordFilled) return;
      if (this.now() > this.deadline) {
        this.stop();
        return;
      }
      this.attempt();
      if (this.passwordFilled) {
        this.stop();
        this.env.notifyPasswordFilled();
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
