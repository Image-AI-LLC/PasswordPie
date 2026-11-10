// What "Scan QR code on this page" did, and the popup's line for it. Apart from the decoder so the popup stays small.

import { isRecord } from './protocol';

export type ScanOutcome =
  | { kind: 'sent'; issuer: string; account: string }
  | { kind: 'none' }
  | { kind: 'not-otp' }
  | { kind: 'hotp' }
  | { kind: 'migration' }
  | { kind: 'no-page' }
  /** The app could not use the link (its secret or settings). */
  | { kind: 'refused' }
  | { kind: 'unreachable' }
  /** An app from before `scan`. */
  | { kind: 'old-app' };

/** The popup's line for each outcome. */
export const SCAN_MESSAGES: Record<ScanOutcome['kind'], string> = {
  sent: 'Sent to PasswordPie. Choose the item there and press Add.',
  none: 'No QR code found on this page.',
  'not-otp': 'This QR code is not a two-step code.',
  hotp: 'This is a counter-based (HOTP) code. PasswordPie makes time-based codes only.',
  migration: 'This is a Google Authenticator export. Scan the QR code the website shows instead.',
  'no-page': 'Open the page with the QR code first.',
  refused: 'PasswordPie could not use this code: its secret or settings are not valid.',
  unreachable: 'Open PasswordPie on this Mac, then scan again.',
  'old-app': 'Update PasswordPie on this Mac to scan QR codes.',
};

export function parseScanOutcome(value: unknown): ScanOutcome {
  if (!isRecord(value) || typeof value.kind !== 'string' || !Object.hasOwn(SCAN_MESSAGES, value.kind)) return { kind: 'unreachable' };
  if (value.kind === 'sent') {
    return { kind: 'sent', issuer: typeof value.issuer === 'string' ? value.issuer : '', account: typeof value.account === 'string' ? value.account : '' };
  }
  return { kind: value.kind as Exclude<ScanOutcome['kind'], 'sent'> };
}
