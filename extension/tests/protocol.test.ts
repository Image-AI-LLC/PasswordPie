import { describe, expect, it } from 'vitest';
import { codeOfAnswer, parseContentMessage, parseFrameMessage } from '../src/lib/protocol';

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

  it('the hint carries nothing but its origin: the extension links to no shop', () => {
    const hint = parseFrameMessage({ type: 'code-hint', origin: 'https://a.example', upgradeUrl: 'https://passwordpie.com/pricing' });
    expect(hint).toEqual({ type: 'code-hint', origin: 'https://a.example' });
  });

  it('reads watch, code and upgrade messages and nothing else', () => {
    expect(parseFrameMessage({ type: 'watch-code', origin: 'https://a.example', waitMs: 5 })).toEqual({ type: 'watch-code', origin: 'https://a.example', waitMs: 5 });
    expect(parseFrameMessage({ type: 'watch-code', origin: 'https://a.example', waitMs: -1 })).toBeUndefined();
    expect(parseFrameMessage({ type: 'code', origin: 'https://a.example', code: '1' })).toEqual({ type: 'code', origin: 'https://a.example', code: '1' });
    expect(parseFrameMessage({ type: 'fill', origin: 'https://a.example' })).toBeUndefined();
    expect(parseContentMessage({ type: 'upgrade' })).toEqual({ type: 'upgrade' });
    expect(parseContentMessage({ type: 'open-panel' })).toBeUndefined();
  });
});
