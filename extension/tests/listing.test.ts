import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { NATIVE_APP } from '../src/lib/protocol';

// store/LISTING.md is what gets pasted into the Chrome Web Store dashboard, which refuses text over its field limits.
const listing = readFileSync(resolve(import.meta.dirname, '../store/LISTING.md'), 'utf8');

/** The ```text block under a heading line (`### Description`) or a bold label line (`**nativeMessaging**`). */
function block(label: string): string {
  const start = listing.indexOf(`\n${label}\n`);
  expect(start, `${label} is in LISTING.md`).toBeGreaterThanOrEqual(0);
  const match = /```text\n([\s\S]*?)\n```/.exec(listing.slice(start));
  if (!match?.[1]) throw new Error(`${label} has no text block`);
  return match[1];
}

/** Every bold label under "### Permission justifications", up to the next heading. */
function justifications(): string[] {
  const start = listing.indexOf('### Permission justifications');
  const end = listing.indexOf('\n### ', start + 1);
  return [...listing.slice(start, end).matchAll(/^\*\*(.+)\*\*$/gm)].map((m) => `**${m[1]}**`);
}

describe('store listing', () => {
  it('lists the justifications the dashboard asks for', () => {
    expect(justifications()).toEqual([
      '**nativeMessaging**',
      '**webNavigation**',
      '**alarms**',
      '**contextMenus**',
      '**Host permissions (<all_urls>)**',
    ]);
  });

  it('keeps every permission justification within the dashboard limit of 1000 characters', () => {
    for (const label of justifications()) {
      expect([...block(label)].length, label).toBeLessThanOrEqual(1000);
    }
  });

  it('keeps the description within the limit of 16000 characters', () => {
    expect([...block('### Description')].length).toBeLessThanOrEqual(16000);
  });

  it('names the host the extension connects to', () => {
    expect(block('**nativeMessaging**')).toContain(`(${NATIVE_APP})`);
  });
});
