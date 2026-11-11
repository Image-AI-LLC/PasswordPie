// The small note in the corner of a page: why a two-step code was not filled (code-filler.ts), or why a scan handed
// nothing over. In a closed shadow root, so the page cannot read it or reach its buttons; the host's own rules are
// !important, which beats any rule the page writes for the host element. Takes no focus.
// No React here: the content script runs on every page and must stay small.

import { isRecord } from './protocol';
import { SCAN_MESSAGES, type ScanOutcome } from './scan-outcome';

export const NOTE_MS = 8_000;
export const SCAN_NOTE_HOST_ID = 'passwordpie-scan-note';

const NOTE_STYLE = `
      :host { all: initial !important; position: fixed !important; z-index: 2147483647 !important;
        right: 16px !important; bottom: 16px !important; }
      .box { display: flex; align-items: center; gap: 10px; max-width: 340px; padding: 10px 12px; border-radius: 10px;
        background: #FFF6E7; color: #302A24; border: 1px solid #C8BBAA; box-shadow: 0 4px 16px rgba(48,35,21,.18);
        font: 13px/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
      button { all: unset; cursor: pointer; color: #70604F; font-size: 15px; padding: 0 2px; }
      button.action { color: #A65312; font-size: 13px; font-weight: 600; white-space: nowrap; }
      @media (prefers-color-scheme: dark) {
        .box { background: #28231F; color: #FFF6E7; border-color: #776858; }
        button { color: #D4C4B2; } button.action { color: #F6B469; }
      }
    `;

/**
 * Adds the note to the page. The caller removes its `host` (`onClose`, or its own timer). `action` is the note's one
 * button, such as Upgrade: it goes nowhere by itself, the caller decides what a click does.
 */
export function addNote(
  doc: Document,
  note: { id: string; text: string; action?: { label: string; run: () => void }; onClose: () => void },
): { host: HTMLElement; action?: HTMLButtonElement } {
  const host = doc.createElement('div');
  host.id = note.id;
  const root = host.attachShadow({ mode: 'closed' });
  root.innerHTML = `<style>${NOTE_STYLE}</style><div class="box" role="status"><span class="text"></span></div>`;
  const box = root.querySelector('.box');
  const span = root.querySelector('.text');
  if (span) span.textContent = note.text;
  let action: HTMLButtonElement | undefined;
  if (box && note.action) {
    const { label, run } = note.action;
    action = doc.createElement('button');
    action.className = 'action';
    action.textContent = label;
    action.addEventListener('click', run);
    box.append(action);
  }
  const close = doc.createElement('button');
  close.setAttribute('aria-label', 'Close');
  close.textContent = '×';
  close.addEventListener('click', note.onClose);
  box?.append(close);
  (doc.body ?? doc.documentElement).append(host);
  return { host, ...(action ? { action } : {}) };
}

/** background → content script of the top frame: what a scan found, when it handed nothing to the app. */
export interface ScanNoteMessage {
  type: 'scan-note';
  kind: ScanOutcome['kind'];
}

export function isScanNoteMessage(value: unknown): value is ScanNoteMessage {
  return isRecord(value) && value.type === 'scan-note' && typeof value.kind === 'string' && Object.hasOwn(SCAN_MESSAGES, value.kind);
}

/** Shows the line for a scan's outcome for 8 seconds, in place of an older one. */
export function showScanNote(doc: Document, kind: ScanOutcome['kind']): { text: string; hide: () => void } {
  doc.getElementById(SCAN_NOTE_HOST_ID)?.remove();
  const text = SCAN_MESSAGES[kind];
  let timer: ReturnType<typeof setTimeout> | undefined;
  const hide = (): void => {
    if (timer !== undefined) clearTimeout(timer);
    host.remove();
  };
  const { host } = addNote(doc, { id: SCAN_NOTE_HOST_ID, text, onClose: hide });
  timer = setTimeout(hide, NOTE_MS);
  return { text, hide };
}
