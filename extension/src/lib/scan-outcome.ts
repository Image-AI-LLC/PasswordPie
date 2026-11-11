// What a scan did, and the line the page's note shows for it. Apart from the decoder so the content script stays small.

export type ScanOutcome =
  | { kind: 'sent' }
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

/** The line for each outcome. `sent` shows nothing: the app's window is the answer. */
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
