#!/usr/bin/env node
// Demo pages for the browser extension (docs/UX.md, "Premium in the browser" and "Scan a two-step QR code") and for the
// store promo video (extension/store/video). Node only, no dependencies:
//
//   node dev/mock-site.mjs                      http://localhost:8787/login   (PORT=8787 by default)
//   TLS_CERT=c.pem TLS_KEY=k.pem node dev/mock-site.mjs   the same over https
//
// The pages are a sign-in for Fernway, a made-up team workspace. The name, the leaf mark and the colours are invented
// for these pages and copy no real site; the video serves them as https://fernway.example (a reserved domain).
//
// - /login: email and password, then /login/verify: six code boxes, then /home, "Welcome back". Any username and password
//   work.
//   The two-step secret is JBSWY3DPEHPK3PXP (otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo).
// - /demo/login and /demo/code are the same two pages under their old addresses.
// - /change-password: the account's email as text, and the current, new and confirm boxes (docs/UX.md, "Reset Password
//   makes the new password for you"). Change goes to /change-password/done, "Password changed". Any passwords work.
//
// There is no account here: the extension signs in nowhere. For Premium in the app, open an activation link
// (node Scripts/mint-activation-link.mjs), signed with the TEST key in test-key.json.
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createServer as createHttpServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';

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

// A fern leaf: a stem and six leaflets.
const LEAF = `<svg viewBox="0 0 32 32" aria-hidden="true"><path fill="currentColor" d="M16 2c1.2 3.6 1.4 8.4.6 13.2-.7 4.4-2 8.5-3.6 12.8l-1.6-.6c1.5-4.1 2.8-8 3.4-12.2.8-4.6.6-9.1-.5-12.6z"/>
<path fill="currentColor" opacity=".9" d="M16.4 8.2c2.7-2.6 6.3-3.6 9.6-3-1 3.2-4 5.6-9.9 6zM15.4 9.4C12.6 7 9 6.2 5.7 7c1.2 3.1 4.3 5.3 10 5.4zM16.3 14.3c2.9-2.3 6.6-3 9.8-2.1-1.2 3.1-4.4 5.2-10.2 5.2zM15 15.4c-2.8-2.4-6.4-3.2-9.7-2.4 1.2 3.1 4.3 5.3 10 5.4zM15.5 20.6c2.7-2 6.1-2.5 9.1-1.6-1.2 2.9-4.2 4.8-9.5 4.6zM14 21.3c-2.6-2-6-2.6-9-1.7 1.3 2.9 4.3 4.7 9.6 4.5z"/></svg>`;

const STYLE = `
*{box-sizing:border-box}
html,body{margin:0;height:100%}
body{font:16px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;color:#1C2B25;background:#F4F3EE;
  -webkit-font-smoothing:antialiased;display:flex;min-height:100vh}
.brand{flex:0 0 36%;background:#173D31;color:#EAF1E8;padding:40px 48px;display:flex;flex-direction:column}
.logo{display:flex;align-items:center;gap:10px;font-weight:700;font-size:22px;letter-spacing:-.3px}
.logo svg{width:30px;height:30px;color:#8FD3A8}
.brand p{margin:auto 0 0;color:#B5CDBF;font-size:16px;max-width:300px}
main{flex:1;display:flex;align-items:center;justify-content:center;padding:40px}
.card{width:380px}
h1{font-size:28px;letter-spacing:-.5px;margin:0 0 6px;font-weight:700}
.sub{margin:0 0 28px;color:#5B6B64}
label{display:block;font-size:14px;font-weight:600;margin:0 0 6px}
.row{display:flex;justify-content:space-between;align-items:baseline}
.row a{font-size:14px}
input{font:inherit;width:100%;height:46px;padding:0 14px;border:1px solid #C9CFC9;border-radius:10px;background:#fff;
  color:#1C2B25;margin:0 0 18px;outline:none}
input:focus{border-color:#1F6B50;box-shadow:0 0 0 3px rgba(31,107,80,.18)}
.check{display:flex;align-items:center;gap:8px;font-size:14px;font-weight:400;color:#3D4C45;margin:2px 0 22px}
.check input{width:16px;height:16px;margin:0;accent-color:#1F6B50}
button{font:inherit;font-weight:650;width:100%;height:48px;border:0;border-radius:10px;background:#1F6B50;color:#fff;cursor:pointer}
a{color:#1F6B50;text-decoration:none;font-weight:600}
.foot{margin-top:26px;padding-top:22px;border-top:1px solid #DFE2DC;font-size:14px;color:#5B6B64;text-align:center}
.boxes{display:flex;gap:10px;margin:0 0 26px}
.boxes input{width:52px;height:60px;margin:0;padding:0;text-align:center;font-size:26px;font-weight:600;
  font-variant-numeric:tabular-nums}
.boxes input:nth-child(3){margin-right:14px}
.home{flex:1;display:flex;flex-direction:column}
.bar{display:flex;align-items:center;justify-content:space-between;padding:18px 40px;background:#173D31;color:#EAF1E8}
.avatar{width:36px;height:36px;border-radius:50%;background:#8FD3A8;color:#173D31;display:grid;place-items:center;font-weight:700}
.welcome{padding:48px 40px}
.welcome h1{font-size:32px}
.tiles{display:grid;grid-template-columns:repeat(3,1fr);gap:18px;margin-top:28px;max-width:900px}
.tile{background:#fff;border:1px solid #DFE2DC;border-radius:14px;padding:20px;min-height:120px}
.tile b{display:block;margin-bottom:6px}
.tile span{color:#5B6B64;font-size:14px}
`;

const page = (title, content) => `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title>
<link rel="icon" href="/favicon.svg"><style>${STYLE}</style></head><body>${content}</body></html>`;

const BRAND = `<aside class="brand"><div class="logo">${LEAF}Fernway</div>
<p>Plans, notes and files for small teams.</p></aside>`;

const LOGIN = (action) => page('Sign in · Fernway', `${BRAND}<main><form class="card" method="post" action="${action}" novalidate>
  <h1>Sign in to Fernway</h1><p class="sub">Welcome back. Pick up where your team left off.</p>
  <label for="email">Email</label>
  <input id="email" name="username" type="email" autocomplete="username">
  <div class="row"><label for="password">Password</label><a href="#" tabindex="-1">Forgot password?</a></div>
  <input id="password" name="password" type="password" autocomplete="current-password">
  <label class="check"><input type="checkbox" checked> Keep me signed in</label>
  <button>Sign in</button>
  <p class="foot">New to Fernway? <a href="#">Create an account</a></p>
</form></main>`);

const CODE = (action) => page('Two-step verification · Fernway', `${BRAND}<main><form class="card" method="post" action="${action}">
  <h1>Two-step verification</h1><p class="sub">Enter the 6-digit code from your authenticator app.</p>
  <div class="boxes">
  ${[1, 2, 3, 4, 5, 6].map((i) => `<input name="d${i}" maxlength="1" inputmode="numeric" autocomplete="one-time-code" aria-label="Digit ${i}">`).join('')}
  </div>
  <button>Verify</button>
  <p class="foot">Can't use your app? <a href="#">Use a recovery code</a></p>
</form></main>`);

const HOME = page('Home · Fernway', `<div class="home"><div class="bar"><div class="logo">${LEAF}Fernway</div><div class="avatar">S</div></div>
<div class="welcome"><h1>Welcome back, Sam</h1><p class="sub">Three things changed since yesterday.</p>
<div class="tiles"><div class="tile"><b>Q1 roadmap</b><span>2 new comments</span></div>
<div class="tile"><b>Design review notes</b><span>Edited 1 hour ago</span></div>
<div class="tile"><b>Launch checklist</b><span>4 of 9 done</span></div></div></div></div>`);

const CHANGE = page('Change password · Fernway', `${BRAND}<main><form class="card" method="post" action="/change-password">
  <h1>Change your password</h1><p class="sub">Signed in as <b>sam@fernway.example</b></p>
  <label for="current">Current password</label>
  <input id="current" name="current" type="password" autocomplete="current-password">
  <label for="new">New password</label>
  <input id="new" name="new" type="password" autocomplete="new-password">
  <label for="confirm">Confirm new password</label>
  <input id="confirm" name="confirm" type="password" autocomplete="new-password">
  <button>Change</button>
</form></main>`);

const CHANGED = page('Password changed · Fernway', `${BRAND}<main><div class="card"><h1>Password changed</h1>
<p class="sub">Use your new password the next time you sign in.</p><a href="/home">Back to Fernway</a></div></main>`);

const WRONG = (retry) => page('Two-step verification · Fernway', `${BRAND}<main><div class="card"><h1>That code didn't work</h1>
<p class="sub">Codes change every 30 seconds.</p><a href="${retry}">Try again</a></div></main>`);

const FAVICON = LEAF.replace('<svg ', '<svg xmlns="http://www.w3.org/2000/svg" ').replaceAll('currentColor', '#1F6B50');

async function verify(req, res, retry) {
  const fields = await body(req);
  const entered = [1, 2, 3, 4, 5, 6].map((i) => fields[`d${i}`] ?? '').join('');
  const ok = [-1, 0].some((step) => totp(DEMO_SECRET, Date.now() + step * 30_000) === entered);
  return ok ? send(res, 303, '', { Location: '/home' }) : send(res, 401, WRONG(retry));
}

async function handle(req, res) {
  const url = new URL(req.url ?? '/', 'http://localhost');
  switch (`${req.method} ${url.pathname}`) {
    case 'GET /':
      return send(res, 303, '', { Location: '/login' });
    case 'GET /login':
      return send(res, 200, LOGIN('/login'));
    case 'POST /login':
      return send(res, 303, '', { Location: '/login/verify' });
    case 'GET /login/verify':
      return send(res, 200, CODE('/login/verify'));
    case 'POST /login/verify':
      return verify(req, res, '/login/verify');
    case 'GET /demo/login':
      return send(res, 200, LOGIN('/demo/login'));
    case 'POST /demo/login':
      return send(res, 303, '', { Location: '/demo/code' });
    case 'GET /demo/code':
      return send(res, 200, CODE('/demo/code'));
    case 'POST /demo/code':
      return verify(req, res, '/demo/code');
    case 'GET /change-password':
      return send(res, 200, CHANGE);
    case 'POST /change-password':
      return send(res, 303, '', { Location: '/change-password/done' });
    case 'GET /change-password/done':
      return send(res, 200, CHANGED);
    case 'GET /home':
      return send(res, 200, HOME);
    case 'GET /favicon.svg':
      return send(res, 200, FAVICON, { 'Content-Type': 'image/svg+xml' });
    default:
      return send(res, 404, page('Not found · Fernway', '<main><h1>Not found</h1></main>'));
  }
}

const tls = process.env.TLS_CERT && process.env.TLS_KEY
  ? { cert: readFileSync(process.env.TLS_CERT), key: readFileSync(process.env.TLS_KEY) }
  : null;
const server = tls ? createHttpsServer(tls, handle) : createHttpServer(handle);
server.listen(PORT, () => console.log(`demo pages on ${tls ? 'https' : 'http'}://localhost:${PORT}/login`));
