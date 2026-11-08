#!/usr/bin/env node
// A stand-in for passwordpie.com, for development and the demo (docs/ACCOUNTS.md, "Testing without the site").
// Node only, no dependencies:  node dev/mock-site.mjs   (PORT=8787 by default)
//
// - Better Auth bearer endpoints: any email with the password "password" signs in. Google accepts any access token.
// - GET /api/premium/entitlement and POST /api/premium/redeem, tokens signed with the TEST key in test-key.json.
//   PPIE-TEST-TEST-TEST works once per run; PPIE-USED-USED-USED answers "used"; PPIE-OLD2-OLD2-OLD2 answers "expired".
// - /demo/login: a two-step sign-in. Username and password, then a page with six code boxes. The demo account's
//   two-step secret is JBSWY3DPEHPK3PXP (otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo).
import { createHmac, createPrivateKey, randomBytes, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';

const PORT = Number(process.env.PORT ?? 8787);
const KEY = JSON.parse(readFileSync(new URL('./test-key.json', import.meta.url), 'utf8'));
const PRIVATE_KEY = createPrivateKey({ key: { kty: 'OKP', crv: 'Ed25519', x: KEY.x, d: KEY.d }, format: 'jwk' });
const DEMO_SECRET = 'JBSWY3DPEHPK3PXP';
const KEY_ALPHABET = /^PPIE-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}$/;

/** email → { id, email, name, premium: null | { plan, expiresAt } } */
const users = new Map();
/** session token → email */
const sessions = new Map();
const usedKeys = new Set(['PPIE-USED-USED-USED']);
const redeemTries = [];

function user(email, name = email.split('@')[0]) {
  if (!users.has(email)) users.set(email, { id: `user-${users.size + 1}`, email, name, premium: null });
  return users.get(email);
}

const b64url = (value) => Buffer.from(typeof value === 'string' ? value : JSON.stringify(value)).toString('base64url');

function entitlementToken(account) {
  const now = Math.floor(Date.now() / 1000);
  const end = account.premium.expiresAt ? Math.floor(Date.parse(account.premium.expiresAt) / 1000) : Infinity;
  const header = b64url({ alg: 'EdDSA', typ: 'JWT', kid: KEY.kid });
  const claims = b64url({
    iss: 'https://passwordpie.com',
    aud: 'passwordpie-app',
    sub: account.id,
    premium: true,
    plan: account.premium.plan,
    iat: now,
    exp: Math.min(now + 7 * 86400, end),
  });
  return `${header}.${claims}.${sign(null, Buffer.from(`${header}.${claims}`), PRIVATE_KEY).toString('base64url')}`;
}

function entitlement(account) {
  const p = account.premium;
  if (!p || (p.expiresAt && Date.parse(p.expiresAt) <= Date.now())) return { premium: false, plan: null, expiresAt: null, token: null };
  return { premium: true, plan: p.plan, expiresAt: p.expiresAt, token: entitlementToken(account) };
}

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
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': typeof body === 'string' ? 'text/html; charset=utf-8' : 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Expose-Headers': 'set-auth-token',
    ...headers,
  });
  res.end(text);
}

async function body(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString('utf8');
  if (!text) return {};
  if ((req.headers['content-type'] ?? '').includes('application/x-www-form-urlencoded')) return Object.fromEntries(new URLSearchParams(text));
  try {
    return JSON.parse(text);
  } catch {
    return {};
  }
}

function signedIn(req) {
  const match = /^Bearer (.+)$/.exec(req.headers.authorization ?? '');
  const email = match && sessions.get(match[1]);
  return email ? users.get(email) : undefined;
}

function startSession(res, account) {
  const token = randomBytes(24).toString('base64url');
  sessions.set(token, account.email);
  send(res, 200, { token, user: { id: account.id, email: account.email, name: account.name } }, { 'set-auth-token': token });
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
  const route = `${req.method} ${url.pathname}`;
  if (req.method === 'OPTIONS') return send(res, 204, '');
  switch (route) {
    case 'POST /api/auth/sign-in/email': {
      const { email, password } = await body(req);
      if (typeof email !== 'string' || password !== 'password') {
        return send(res, 401, { code: 'INVALID_EMAIL_OR_PASSWORD', message: 'Invalid email or password' });
      }
      return startSession(res, user(email.toLowerCase()));
    }
    case 'POST /api/auth/sign-up/email': {
      const { email, name } = await body(req);
      if (typeof email !== 'string') return send(res, 400, { message: 'Email is required' });
      return startSession(res, user(email.toLowerCase(), name));
    }
    case 'POST /api/auth/extension/google': {
      const { accessToken } = await body(req);
      if (typeof accessToken !== 'string' || !accessToken) return send(res, 400, { error: 'invalid' });
      const token = randomBytes(24).toString('base64url');
      sessions.set(token, user('google.user@example.com', 'Google User').email);
      return send(res, 200, { token });
    }
    case 'GET /api/auth/get-session': {
      const account = signedIn(req);
      if (!account) return send(res, 200, null);
      return send(res, 200, { session: { userId: account.id }, user: { id: account.id, email: account.email, name: account.name } });
    }
    case 'POST /api/auth/sign-out': {
      const match = /^Bearer (.+)$/.exec(req.headers.authorization ?? '');
      if (match) sessions.delete(match[1]);
      return send(res, 200, { success: true });
    }
    case 'GET /api/premium/entitlement': {
      const account = signedIn(req);
      return account ? send(res, 200, entitlement(account)) : send(res, 401, { error: 'unauthorized' });
    }
    case 'POST /api/premium/redeem': {
      const account = signedIn(req);
      if (!account) return send(res, 401, { error: 'unauthorized' });
      const now = Date.now();
      while (redeemTries.length && now - redeemTries[0] > 60_000) redeemTries.shift();
      if (redeemTries.push(now) > 10) return send(res, 429, { error: 'rate-limited' });
      const { code } = await body(req);
      if (typeof code !== 'string' || !KEY_ALPHABET.test(code)) return send(res, 400, { error: 'invalid' });
      if (code === 'PPIE-OLD2-OLD2-OLD2') return send(res, 400, { error: 'expired' });
      if (usedKeys.has(code)) return send(res, 400, { error: 'used' });
      if (code !== 'PPIE-TEST-TEST-TEST') return send(res, 400, { error: 'invalid' });
      usedKeys.add(code);
      account.premium = { plan: 'key', expiresAt: null };
      return send(res, 200, entitlement(account));
    }
    case 'GET /pricing':
      return send(res, 200, page('Pricing (mock)', '<h1>PasswordPie Premium</h1><p>Mock pricing page.</p>'));
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
      return send(res, 404, { error: 'not-found' });
  }
});

server.listen(PORT, () => console.log(`mock passwordpie.com on http://localhost:${PORT}  (demo: /demo/login)`));
