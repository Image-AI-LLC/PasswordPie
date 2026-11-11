// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { NOTE_MS, SCAN_NOTE_HOST_ID, isScanNoteMessage, showScanNote } from '../src/lib/page-note';

afterEach(() => {
  vi.useRealTimers();
  document.body.innerHTML = '';
});

describe('the scan note', () => {
  it('accepts only an outcome it has a line for', () => {
    expect(isScanNoteMessage({ type: 'scan-note', kind: 'none' })).toBe(true);
    expect(isScanNoteMessage({ type: 'scan-note', kind: 'nonsense' })).toBe(false);
    expect(isScanNoteMessage({ type: 'scan-note', kind: 'toString' })).toBe(false);
    expect(isScanNoteMessage({ type: 'qr-images' })).toBe(false);
    expect(isScanNoteMessage(null)).toBe(false);
  });

  it('shows the line for 8 seconds, in a host the page cannot read', () => {
    vi.useFakeTimers();
    const note = showScanNote(document, 'none');
    const host = document.getElementById(SCAN_NOTE_HOST_ID);
    expect(note.text).toBe('No QR code found on this page.');
    expect(host).not.toBeNull();
    expect(host?.shadowRoot).toBeNull(); // closed
    vi.advanceTimersByTime(NOTE_MS - 1);
    expect(document.getElementById(SCAN_NOTE_HOST_ID)).not.toBeNull();
    vi.advanceTimersByTime(1);
    expect(document.getElementById(SCAN_NOTE_HOST_ID)).toBeNull();
  });

  it('a newer note replaces the one showing', () => {
    showScanNote(document, 'none');
    const second = showScanNote(document, 'hotp');
    expect(document.querySelectorAll(`#${SCAN_NOTE_HOST_ID}`)).toHaveLength(1);
    expect(second.text).toContain('HOTP');
    second.hide();
    expect(document.getElementById(SCAN_NOTE_HOST_ID)).toBeNull();
  });
});
