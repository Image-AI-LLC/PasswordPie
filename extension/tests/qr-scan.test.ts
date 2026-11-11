import QRCode from 'qrcode';
import { describe, expect, it } from 'vitest';
import { MAX_PAGE_IMAGES, pageQrCandidates, type Box } from '../src/lib/qr-page';
import {
  classifyQrText,
  decodeRgba,
  scanActiveTab,
  type ScanDeps,
} from '../src/lib/qr-scan';

const DEMO = 'otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo';

/** A QR code drawn as RGBA pixels, with a quiet zone, the way a screenshot holds it. */
function qrPixels(text: string, scale = 4): { data: Uint8ClampedArray; width: number; height: number } {
  const { modules } = QRCode.create(text, { errorCorrectionLevel: 'M' });
  const margin = 4;
  const side = (modules.size + margin * 2) * scale;
  const data = new Uint8ClampedArray(side * side * 4).fill(255);
  for (let y = 0; y < modules.size; y += 1) {
    for (let x = 0; x < modules.size; x += 1) {
      if (!modules.get(y, x)) continue;
      for (let dy = 0; dy < scale; dy += 1) {
        for (let dx = 0; dx < scale; dx += 1) {
          const offset = (((y + margin) * scale + dy) * side + (x + margin) * scale + dx) * 4;
          data[offset] = 0;
          data[offset + 1] = 0;
          data[offset + 2] = 0;
        }
      }
    }
  }
  return { data, width: side, height: side };
}

describe('classifyQrText', () => {
  it('tells two-step links from everything else', () => {
    expect(classifyQrText(DEMO)).toBe('totp');
    expect(classifyQrText(' OTPAUTH://TOTP/x?secret=A')).toBe('totp');
    expect(classifyQrText('otpauth://hotp/x?secret=A&counter=1')).toBe('hotp');
    expect(classifyQrText('otpauth-migration://offline?data=abc')).toBe('migration');
    expect(classifyQrText('https://example.com/2fa')).toBe('other');
    expect(classifyQrText('otpauth://totpx/x')).toBe('other');
  });
});

describe('decodeRgba', () => {
  it('reads a QR code with the bundled decoder', () => {
    const { data, width, height } = qrPixels(DEMO);
    expect(decodeRgba(data, width, height)).toBe(DEMO);
  });

  it('reads nothing from a blank picture', () => {
    expect(decodeRgba(new Uint8ClampedArray(100 * 100 * 4).fill(255), 100, 100)).toBeUndefined();
  });
});

describe('pageQrCandidates', () => {
  function page(html: string, boxes: Record<string, Box>): { doc: Document; boxOf: (el: Element) => Box } {
    document.body.innerHTML = html;
    return { doc: document, boxOf: (el) => boxes[el.id] ?? { top: 0, left: 0, width: 0, height: 0 } };
  }

  it('takes square pictures on screen: images, data URLs, canvases and SVGs', () => {
    const { doc, boxOf } = page(
      `<img id="qr" src="https://example.com/qr.png"><img id="data" src="data:image/png;base64,AAAA">
       <canvas id="canvas"></canvas><svg id="svg"><svg id="inner"></svg></svg>
       <img id="banner"><img id="tiny"><img id="below"><img id="hidden" style="display:none">`,
      {
        qr: { top: 100, left: 100, width: 200, height: 200 },
        data: { top: 100, left: 400, width: 150, height: 160 },
        canvas: { top: 300, left: 0, width: 128, height: 128 },
        svg: { top: 10, left: 10, width: 64, height: 64 },
        inner: { top: 10, left: 10, width: 64, height: 64 },
        banner: { top: 0, left: 0, width: 600, height: 80 },
        tiny: { top: 0, left: 0, width: 24, height: 24 },
        below: { top: 2000, left: 0, width: 200, height: 200 },
      },
    );
    const found = pageQrCandidates(doc, { width: 1200, height: 800 }, boxOf).map((el) => el.id);
    expect(found.sort()).toEqual(['canvas', 'data', 'qr', 'svg']);
  });

  it('reads at most eight', () => {
    const html = Array.from({ length: 12 }, (_, i) => `<img id="i${i}">`).join('');
    const boxes = Object.fromEntries(Array.from({ length: 12 }, (_, i) => [`i${i}`, { top: 0, left: i * 60, width: 50, height: 50 }]));
    const { doc, boxOf } = page(html, boxes);
    expect(pageQrCandidates(doc, { width: 2000, height: 800 }, boxOf)).toHaveLength(MAX_PAGE_IMAGES);
  });
});

describe('scanActiveTab', () => {
  function deps(overrides: Partial<ScanDeps> & { pictures?: Record<string, string[]> } = {}): { deps: ScanDeps; log: string[] } {
    const log: string[] = [];
    const pictures = overrides.pictures ?? { 'data:image/png;base64,page': [DEMO] };
    const base: ScanDeps = {
      activeTab: async () => ({ id: 7, windowId: 2, url: 'https://example.com/settings/2fa?step=1#qr' }),
      pageImages: async () => Object.keys(pictures).filter((key) => key.includes('page')),
      captureVisibleTab: async () => {
        log.push('capture');
        return 'data:image/png;base64,shot';
      },
      decode: async (url) => pictures[url] ?? [],
      sendScan: async (otpauth, url) => {
        log.push(`scan ${otpauth} ${url}`);
        return { type: 'scan', id: 1 };
      },
      startApp: async () => {
        log.push('show');
        return true;
      },
    };
    return { deps: { ...base, ...overrides }, log };
  }

  it('hands the page’s two-step link and only its origin to the app', async () => {
    const { deps: d, log } = deps();
    expect(await scanActiveTab(d)).toEqual({ kind: 'sent' });
    expect(log).toEqual([`scan ${DEMO} https://example.com/`]);
  });

  it('takes a picture of the tab only when the page has no readable QR code', async () => {
    const { deps: d, log } = deps({ pictures: { 'data:image/png;base64,shot': [DEMO] } });
    expect((await scanActiveTab(d)).kind).toBe('sent');
    expect(log).toEqual(['capture', `scan ${DEMO} https://example.com/`]);
  });

  it('ignores the picture when the visible tab is no longer the page that was asked about', async () => {
    for (const next of [{ id: 8, windowId: 2, url: 'https://example.com/' }, { id: 7, windowId: 2, url: 'https://evil.example/' }]) {
      let calls = 0;
      const { deps: d, log } = deps({
        pictures: { 'data:image/png;base64,shot': [DEMO] },
        activeTab: async () => (calls++ === 0 ? { id: 7, windowId: 2, url: 'https://example.com/settings' } : next),
      });
      expect(await scanActiveTab(d)).toEqual({ kind: 'none' });
      expect(log).toEqual(['capture']);
    }
  });

  it('says so when nothing is found, even when the browser refuses the picture', async () => {
    const { deps: d, log } = deps({ pictures: {}, captureVisibleTab: async () => Promise.reject(new Error('not allowed')) });
    expect(await scanActiveTab(d)).toEqual({ kind: 'none' });
    expect(log).toEqual([]);
  });

  it('sends nothing for codes PasswordPie does not take', async () => {
    for (const [text, kind] of [
      ['otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP', 'hotp'],
      ['otpauth-migration://offline?data=abc', 'migration'],
      ['https://example.com', 'not-otp'],
    ] as const) {
      const { deps: d, log } = deps({ pictures: { 'data:image/png;base64,page': [text] } });
      expect(await scanActiveTab(d)).toEqual({ kind });
      expect(log.filter((line) => line.startsWith('scan'))).toEqual([]);
    }
  });

  it('prefers a two-step code over another QR code on the page', async () => {
    const { deps: d } = deps({ pictures: { 'data:image/png;base64,page1': ['https://app.store/get'], 'data:image/png;base64,page2': [DEMO] } });
    expect((await scanActiveTab(d)).kind).toBe('sent');
  });

  it('does nothing on a page that is not a web page', async () => {
    const { deps: d, log } = deps({ activeTab: async () => ({ id: 1, url: 'chrome://settings/' }) });
    expect(await scanActiveTab(d)).toEqual({ kind: 'no-page' });
    expect(log).toEqual([]);
  });

  it('starts the app once when it is not running', async () => {
    let tries = 0;
    const { deps: d, log } = deps({
      sendScan: async () => {
        tries += 1;
        return tries === 1 ? { type: 'error', id: 1, code: 'app-unavailable' } : { type: 'scan', id: 2 };
      },
    });
    expect((await scanActiveTab(d)).kind).toBe('sent');
    expect(log).toContain('show');
    expect(tries).toBe(2);
  });

  it('passes on what the app said', async () => {
    for (const [answer, kind] of [
      [{ type: 'error', id: 1, code: 'bad-otp' }, 'refused'],
      [{ type: 'error', id: 1, code: 'bad-request' }, 'old-app'],
      [undefined, 'unreachable'],
    ] as const) {
      const { deps: d } = deps({ sendScan: async () => answer, startApp: async () => false });
      expect(await scanActiveTab(d)).toEqual({ kind });
    }
  });
});
