// @vitest-environment node
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { CHROME_KEY } from '../manifest';

/** Chrome's extension ID: the first 128 bits of SHA-256 over the DER public key, each hex digit written as a–p. */
function chromeExtensionId(base64Key: string): string {
  const hex = createHash('sha256').update(Buffer.from(base64Key, 'base64')).digest('hex').slice(0, 32);
  return [...hex].map((digit) => String.fromCharCode(97 + Number.parseInt(digit, 16))).join('');
}

describe('extension ID', () => {
  it('is the one the app trusts: the key in manifest.ts pins the ID in BridgeConstants.chromeExtensionID', () => {
    const swift = readFileSync(new URL('../../Sources/PasswordPieBridge/BridgeTransport.swift', import.meta.url), 'utf8');
    const trusted = /static let chromeExtensionID = "([a-p]{32})"/.exec(swift)?.[1];
    expect(trusted).toBeDefined();
    expect(chromeExtensionId(CHROME_KEY)).toBe(trusted);
  });
});
