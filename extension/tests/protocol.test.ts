import { describe, expect, it } from 'vitest';
import { codeOfAnswer, parseFrameMessage, parsePopupMessage } from '../src/lib/protocol';

describe('code messages', () => {
  it('reads a code answer, a no-Premium answer, and treats anything else as none', () => {
    expect(codeOfAnswer({ type: 'code', id: 1, otp: { origin: 'https://a.example', code: '012345', expiresIn: 9 } })).toEqual({
      kind: 'code',
      origin: 'https://a.example',
      code: '012345',
    });
    expect(codeOfAnswer({ type: 'code', id: 1, premium: false })).toEqual({ kind: 'no-premium' });
    expect(codeOfAnswer({ type: 'code', id: 1 })).toEqual({ kind: 'none' });
    expect(codeOfAnswer({ type: 'error', id: 1, code: 'app-unavailable' })).toEqual({ kind: 'none' });
    expect(codeOfAnswer({ type: 'code', id: 1, otp: { origin: 'https://a.example', code: '<img src=x>' } })).toEqual({ kind: 'none' });
    expect(codeOfAnswer(undefined)).toEqual({ kind: 'none' });
  });

  it('keeps only an https upgrade link, or one on this Mac', () => {
    const hint = (upgradeUrl: string) => parseFrameMessage({ type: 'code-hint', origin: 'https://a.example', upgradeUrl });
    expect(hint('https://passwordpie.com/pricing')).toEqual({ type: 'code-hint', origin: 'https://a.example', upgradeUrl: 'https://passwordpie.com/pricing' });
    expect(hint('http://localhost:8787/pricing')).toHaveProperty('upgradeUrl', 'http://localhost:8787/pricing');
    expect(hint('javascript:alert(1)')).not.toHaveProperty('upgradeUrl');
    expect(hint('http://evil.example/')).not.toHaveProperty('upgradeUrl');
  });

  it('reads watch, code and popup messages and nothing else', () => {
    expect(parseFrameMessage({ type: 'watch-code', origin: 'https://a.example', waitMs: 5 })).toEqual({ type: 'watch-code', origin: 'https://a.example', waitMs: 5 });
    expect(parseFrameMessage({ type: 'watch-code', origin: 'https://a.example', waitMs: -1 })).toBeUndefined();
    expect(parseFrameMessage({ type: 'code', origin: 'https://a.example', code: '1' })).toEqual({ type: 'code', origin: 'https://a.example', code: '1' });
    expect(parseFrameMessage({ type: 'fill', origin: 'https://a.example' })).toBeUndefined();
    expect(parsePopupMessage({ type: 'open-panel' })).toEqual({ type: 'open-panel' });
    expect(parsePopupMessage({ type: 'show' })).toBeUndefined();
  });
});
