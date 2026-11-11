#!/usr/bin/env node
// Demo pages for the browser extension (docs/UX.md, "Premium in the browser" and "Scan a two-step QR code").
// Node only, no dependencies:  node dev/mock-site.mjs   (PORT=8787 by default)
//
// - /demo/login: a two-step sign-in. Username and password, then a page with six code boxes. The demo account's
//   two-step secret is JBSWY3DPEHPK3PXP (otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo).
//
// There is no account here: the extension signs in nowhere. For Premium in the app, open an activation link
// (node Scripts/mint-activation-link.mjs), signed with the TEST key in test-key.json.
import { createHmac } from 'node:crypto';
import { createServer } from 'node:http';

const PORT = Number(process.env.PORT ?? 8787);
const DEMO_SECRET = 'JBSWY3DPEHPK3PXP';

function totp(secret, at = Date.now()) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = '';
  for (const c of secret) bits += alphabet.indexOf(c).toString(2).padStart(5, '0');
  const key = Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2)));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(at / 30000)));
  const mac = createHmac('sha1', key).update(counter).digest();
  const offset = mac[mac.length - 1] & 0xf;
  return String((mac.readUInt32BE(offset) & 0x7fffffff) % 1_000_000).padStart(6, '0');
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8', ...headers });
  res.end(body);
}

async function body(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString('utf8');
  if (!text) return {};
  return Object.fromEntries(new URLSearchParams(text));
}

const page = (title, content) => `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title>
<style>body{font:15px -apple-system,sans-serif;max-width:360px;margin:60px auto;color:#302A24;background:#FFF6E7}
input{font-size:15px;padding:6px;margin:4px 0}.boxes input{width:28px;text-align:center}button{font-size:15px;padding:6px 14px}</style>
</head><body>${content}</body></html>`;

const LOGIN = page('Demo sign-in', `<h1>Demo sign-in</h1>
<form method="post" action="/demo/login">
  <label>Username<br><input name="username" autocomplete="username"></label><br>
  <label>Password<br><input name="password" type="password" autocomplete="current-password"></label><br>
  <button>Sign In</button>
</form>`);

const CODE = page('Two-step verification', `<h1>Two-step verification</h1>
<p>Enter the 6-digit code from your authenticator app.</p>
<form method="post" action="/demo/code"><div class="boxes">
${[1, 2, 3, 4, 5, 6].map((i) => `<input name="d${i}" maxlength="1" inputmode="numeric" aria-label="Digit ${i}">`).join('')}
</div><br><button>Verify</button></form>`);

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://localhost:${PORT}`);
  switch (`${req.method} ${url.pathname}`) {
    case 'GET /':
    case 'GET /demo/login':
      return send(res, 200, LOGIN);
    case 'POST /demo/login':
      return send(res, 303, '', { Location: '/demo/code' });
    case 'GET /demo/code':
      return send(res, 200, CODE);
    case 'POST /demo/code': {
      const fields = await body(req);
      const entered = [1, 2, 3, 4, 5, 6].map((i) => fields[`d${i}`] ?? '').join('');
      const ok = [-1, 0].some((step) => totp(DEMO_SECRET, Date.now() + step * 30_000) === entered);
      return send(res, ok ? 200 : 401, page('Demo', ok ? '<h1>Signed in ✓</h1>' : '<h1>Wrong code</h1><a href="/demo/code">Try again</a>'));
    }
    default:
      return send(res, 404, page('Not found', '<h1>Not found</h1>'));
  }
});

server.listen(PORT, () => console.log(`demo pages on http://localhost:${PORT}/demo/login`));
