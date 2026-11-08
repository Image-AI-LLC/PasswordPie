// The content script's two-step code logic, one per frame. It looks for a code field only when the background asks
// (right after PasswordPie filled an account with a code), tells the background when one shows up, and fills the code
// the app sent. No React here: the content script runs on every page and must stay small.
import { codeFieldIsEmpty, fillCode, findCodeField } from './code-fields';
import type { CodeHintMessage, FrameMessage } from './protocol';

export const CODE_POLL_MS = 250;
export const HINT_MS = 8_000;
export const HINT_HOST_ID = 'passwordpie-code-hint';
const MAX_WAIT_MS = 30_000;

export interface CodeEnv {
  document: Document;
  origin: string;
  frameAllowed: () => boolean;
  /** An empty code field is on the page: the background asks the app for the code. */
  notifyCodeField: () => void;
  now?: () => number;
}

export class CodeFiller {
  private observer: MutationObserver | undefined;
  private poll: ReturnType<typeof setInterval> | undefined;
  private queued: ReturnType<typeof setTimeout> | undefined;
  private deadline = 0;
  private reported = false;
  private hint: { host: HTMLElement; timer: ReturnType<typeof setTimeout>; text: string; link?: string } | undefined;

  constructor(private readonly env: CodeEnv) {}

  /** Answers `code` with whether it filled; the others with nothing. */
  handle(msg: FrameMessage): boolean {
    if (msg.origin !== this.env.origin || !this.env.frameAllowed()) return false;
    switch (msg.type) {
      case 'watch-code':
        this.watch(msg.waitMs);
        return false;
      case 'code':
        this.reported = false;
        return this.fill(msg.code);
      case 'code-hint':
        this.reported = false;
        this.showHint(msg);
        return false;
    }
  }

  stop(): void {
    this.stopWatching();
    this.hideHint();
  }

  hintText(): string | undefined {
    return this.hint?.text;
  }

  hintLink(): string | undefined {
    return this.hint?.link;
  }

  private now(): number {
    return (this.env.now ?? Date.now)();
  }

  private watch(waitMs: number): void {
    // Each watch-code is a pick, or the next page of one: look again even after a report that got no answer. The
    // background asks the app at most once per pick, so a repeat for the same pick costs nothing.
    this.reported = false;
    this.deadline = this.now() + Math.min(waitMs, MAX_WAIT_MS);
    if (this.poll !== undefined) return;
    if (this.check()) return;
    const view = this.env.document.defaultView;
    const queue = (): void => {
      if (this.queued !== undefined) return;
      this.queued = setTimeout(() => {
        this.queued = undefined;
        this.check();
      }, 100);
    };
    if (view) {
      this.observer = new view.MutationObserver(queue);
      this.observer.observe(this.env.document, { childList: true, subtree: true });
    }
    this.poll = setInterval(() => this.check(), CODE_POLL_MS);
  }

  /** True once the field was found (or the wait is over). */
  private check(): boolean {
    if (this.now() > this.deadline) {
      this.stopWatching();
      return true;
    }
    const field = findCodeField(this.env.document);
    if (!field || !codeFieldIsEmpty(field)) return false;
    this.reported = true;
    this.stopWatching();
    this.env.notifyCodeField();
    return true;
  }

  private stopWatching(): void {
    this.observer?.disconnect();
    this.observer = undefined;
    if (this.poll !== undefined) clearInterval(this.poll);
    this.poll = undefined;
    if (this.queued !== undefined) clearTimeout(this.queued);
    this.queued = undefined;
  }

  private fill(code: string): boolean {
    const field = findCodeField(this.env.document);
    if (!field || !codeFieldIsEmpty(field)) return false;
    return fillCode(field, code);
  }

  /** A small note in the corner, in a closed shadow root so the page cannot read or restyle it. Takes no focus. */
  private showHint(msg: CodeHintMessage): void {
    this.hideHint();
    const doc = this.env.document;
    const host = doc.createElement('div');
    host.id = HINT_HOST_ID;
    const root = host.attachShadow({ mode: 'closed' });
    const text = 'PasswordPie Premium fills two-step codes for you.';
    root.innerHTML = `<style>
      :host { all: initial; position: fixed; z-index: 2147483647; right: 16px; bottom: 16px; }
      .box { display: flex; align-items: center; gap: 10px; max-width: 340px; padding: 10px 12px; border-radius: 10px;
        background: #FFF6E7; color: #302A24; border: 1px solid #C8BBAA; box-shadow: 0 4px 16px rgba(48,35,21,.18);
        font: 13px/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
      a { color: #A65312; font-weight: 600; text-decoration: none; white-space: nowrap; }
      button { all: unset; cursor: pointer; color: #70604F; font-size: 15px; padding: 0 2px; }
      @media (prefers-color-scheme: dark) {
        .box { background: #28231F; color: #FFF6E7; border-color: #776858; }
        a { color: #F6B469; } button { color: #D4C4B2; }
      }
    </style><div class="box" role="status"><span class="text"></span></div>`;
    const box = root.querySelector('.box');
    const span = root.querySelector('.text');
    if (span) span.textContent = text;
    if (box && msg.upgradeUrl) {
      const link = doc.createElement('a');
      link.href = msg.upgradeUrl;
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
      link.textContent = 'Upgrade';
      box.append(link);
    }
    const close = doc.createElement('button');
    close.setAttribute('aria-label', 'Close');
    close.textContent = '×';
    close.addEventListener('click', () => this.hideHint());
    box?.append(close);
    (doc.body ?? doc.documentElement).append(host);
    const timer = setTimeout(() => this.hideHint(), HINT_MS);
    this.hint = { host, timer, text, ...(msg.upgradeUrl ? { link: msg.upgradeUrl } : {}) };
  }

  private hideHint(): void {
    if (!this.hint) return;
    clearTimeout(this.hint.timer);
    this.hint.host.remove();
    this.hint = undefined;
  }
}
