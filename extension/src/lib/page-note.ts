// The small note in the corner of a page: why a two-step code was not filled (code-filler.ts), or why a scan from a
// right-click menu handed nothing over. In a closed shadow root, so the page cannot read or restyle it. Takes no focus.
// No React here: the content script runs on every page and must stay small.

import { isRecord } from './protocol';
import { SCAN_MESSAGES, type ScanOutcome } from './scan-outcome';

export const NOTE_MS = 8_000;
export const SCAN_NOTE_HOST_ID = 'passwordpie-scan-note';

const NOTE_STYLE = `
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
    `;

/** Adds the note to the page and returns its host. The caller removes it (`onClose`, or its own timer). */
export function addNote(
  doc: Document,
  note: { id: string; text: string; link?: { href: string; label: string }; onClose: () => void },
): HTMLElement {
  const host = doc.createElement('div');
  host.id = note.id;
  const root = host.attachShadow({ mode: 'closed' });
  root.innerHTML = `<style>${NOTE_STYLE}</style><div class="box" role="status"><span class="text"></span></div>`;
  const box = root.querySelector('.box');
  const span = root.querySelector('.text');
  if (span) span.textContent = note.text;
  if (box && note.link) {
    const link = doc.createElement('a');
    link.href = note.link.href;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.textContent = note.link.label;
    box.append(link);
  }
  const close = doc.createElement('button');
  close.setAttribute('aria-label', 'Close');
  close.textContent = '×';
  close.addEventListener('click', note.onClose);
  box?.append(close);
  (doc.body ?? doc.documentElement).append(host);
  return host;
}

/** background → content script of the top frame: what a scan from a menu found, when it handed nothing to the app. */
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
  const host = addNote(doc, { id: SCAN_NOTE_HOST_ID, text, onClose: hide });
  timer = setTimeout(hide, NOTE_MS);
  return { text, hide };
}
