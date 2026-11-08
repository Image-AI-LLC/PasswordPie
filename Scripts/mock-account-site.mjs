#!/usr/bin/env node
// A stand-in for passwordpie.com's account and Premium API, for running the app against it (docs/CHANNELS.md, "Testing the
// account without the site"). TEST ONLY: passes are signed with the public test key (extension/dev/test-key.json), which
// only debug builds trust, and Apple's signature on a transaction is not checked.
//
//   node Scripts/mock-account-site.mjs [port]        (default 8788)
//   PASSWORDPIE_SITE_URL=http://localhost:8788 .build/debug/PasswordPie
//
// Accounts are made on first sign-in. The key PPIE-TEST-TEST-TEST gives a year of Premium once.
import { createPrivateKey, randomBytes, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const port = Number(process.argv[2] ?? 8788);
const here = dirname(fileURLToPath(import.meta.url));
const testKey = JSON.parse(readFileSync(join(here, "../extension/dev/test-key.json"), "utf8"));
const privateKey = createPrivateKey({ key: { kty: "OKP", crv: "Ed25519", x: testKey.x, d: testKey.d }, format: "jwk" });

const users = new Map(); // email -> { id, premium: { plan, expiresAt } | null }
const sessions = new Map(); // token -> email
const codes = new Map(); // one-time code -> token
const usedKeys = new Set();

const b64url = (data) => Buffer.from(data).toString("base64url");
const token = () => randomBytes(24).toString("base64url");
const esc = (text) => String(text).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

function user(email) {
  if (!users.has(email)) users.set(email, { id: `user-${users.size + 1}`, premium: null });
  return users.get(email);
}

function premiumOf(email) {
  const own = user(email).premium;
  if (own && (!own.expiresAt || new Date(own.expiresAt) > new Date())) return own;
  return null;
}

function pass(email, premium) {
  const now = Math.floor(Date.now() / 1000);
  let exp = now + 7 * 86400;
  if (premium.expiresAt) exp = Math.min(exp, Math.floor(new Date(premium.expiresAt).getTime() / 1000));
  const header = b64url(JSON.stringify({ alg: "EdDSA", typ: "JWT", kid: testKey.kid }));
  const claims = b64url(JSON.stringify({
    iss: "https://passwordpie.com", aud: "passwordpie-app", sub: user(email).id, premium: true, plan: premium.plan, iat: now, exp,
  }));
  return `${header}.${claims}.${b64url(sign(null, Buffer.from(`${header}.${claims}`), privateKey))}`;
}

function entitlement(email) {
  const premium = premiumOf(email);
  if (!premium) return { premium: false, plan: null, expiresAt: null, token: null };
  return { premium: true, plan: premium.plan, expiresAt: premium.expiresAt, token: pass(email, premium) };
}

function send(res, status, body, headers = {}) {
  const text = typeof body === "string" ? body : JSON.stringify(body);
  res.writeHead(status, { "content-type": typeof body === "string" ? "text/html; charset=utf-8" : "application/json", ...headers });
  res.end(text);
}

async function readBody(req) {
  let text = "";
  for await (const chunk of req) text += chunk;
  if ((req.headers["content-type"] ?? "").includes("application/x-www-form-urlencoded")) return Object.fromEntries(new URLSearchParams(text));
  try { return JSON.parse(text || "{}"); } catch { return {}; }
}

function signInPage(params) {
  const provider = params.get("provider");
  const hidden = ["state", "callback"].map((n) => `<input type="hidden" name="${n}" value="${esc(params.get(n) ?? "")}">`).join("");
  const apple = `<form method="post" action="/app/sign-in">${hidden}<input type="hidden" name="email" value="ada@privaterelay.appleid.com">
    <button class="apple"> Continue with Apple</button></form>`;
  const others = `<form method="post" action="/app/sign-in">${hidden}
    <input name="email" placeholder="Email" value="ada@example.com"><input name="password" type="password" placeholder="Password" value="password">
    <button>Sign in</button></form>`;
  return `<!doctype html><meta name="viewport" content="width=device-width"><title>Sign in to PasswordPie (mock)</title>
  <style>body{font:15px -apple-system,sans-serif;max-width:340px;margin:40px auto;color:#302a24;background:#fff6e7}
  button,input{display:block;width:100%;box-sizing:border-box;margin:8px 0;padding:10px;border-radius:8px;border:1px solid #c8bbaa;font:inherit}
  .apple{background:#000;color:#fff;border:0}small{color:#70604f}</style>
  <h2>Sign in to PasswordPie</h2><small>Mock site for testing. Nothing here is real.</small>
  ${provider === "apple" ? apple : apple + "<hr>" + others}`;
}

function completeSignIn(res, body) {
  const session = token();
  sessions.set(session, body.email);
  user(body.email);
  const code = token();
  codes.set(code, session);
  const callback = new URL(body.callback || "passwordpie://auth");
  callback.searchParams.set("code", code);
  callback.searchParams.set("state", body.state ?? "");
  res.writeHead(302, { location: callback.toString() });
  res.end();
}

createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${port}`);
  const auth = (req.headers.authorization ?? "").replace(/^Bearer /, "");
  const email = sessions.get(auth);
  console.log(new Date().toISOString(), req.method, url.pathname, email ? `(${email})` : "");

  if (req.method === "GET" && url.pathname === "/app/sign-in") {
    // MOCK_AUTO_APPLE=1: Sign in with Apple completes at once, as when Safari already knows the Apple Account.
    if (process.env.MOCK_AUTO_APPLE === "1" && url.searchParams.get("provider") === "apple") {
      return completeSignIn(res, { email: "ada@privaterelay.appleid.com", state: url.searchParams.get("state"), callback: url.searchParams.get("callback") });
    }
    return send(res, 200, signInPage(url.searchParams));
  }
  if (req.method === "POST" && url.pathname === "/app/sign-in") return completeSignIn(res, await readBody(req));
  if (req.method === "POST" && url.pathname === "/api/auth/app/exchange") {
    const { code } = await readBody(req);
    const session = codes.get(code);
    codes.delete(code);
    return session ? send(res, 200, { token: session }) : send(res, 400, { error: "invalid-code" });
  }
  if (url.pathname === "/mock/state") return send(res, 200, { users: [...users] });

  if (url.pathname.startsWith("/api/")) {
    if (url.pathname === "/api/auth/get-session") return send(res, 200, email ? { session: { id: "s" }, user: { id: user(email).id, email } } : null);
    if (!email) return send(res, 401, { error: "unauthorized" });
    if (url.pathname === "/api/auth/sign-out") {
      sessions.delete(auth);
      return send(res, 200, { success: true });
    }
    if (url.pathname === "/api/premium/entitlement") return send(res, 200, entitlement(email));
    if (url.pathname === "/api/premium/redeem") {
      const { code } = await readBody(req);
      const normalized = String(code ?? "").toUpperCase();
      if (normalized !== "PPIE-TEST-TEST-TEST") return send(res, 400, { error: "invalid" });
      if (usedKeys.has(normalized)) return send(res, 400, { error: "used" });
      usedKeys.add(normalized);
      user(email).premium = { plan: "key", expiresAt: new Date(Date.now() + 365 * 86400e3).toISOString() };
      return send(res, 200, entitlement(email));
    }
  }
  if (url.pathname === "/pricing" || url.pathname === "/redeem") {
    return send(res, 200, `<!doctype html><title>Redeem (mock)</title><body style="font:15px -apple-system;margin:40px">
      <p>Mock page. Redeem with: <code>curl -X POST -H 'Authorization: Bearer &lt;session&gt;' -d '{"code":"PPIE-TEST-TEST-TEST"}' localhost:${port}/api/premium/redeem</code>
      or <a href="/mock/redeem-latest">redeem for the last signed-in account</a>.</p>`);
  }
  if (url.pathname === "/mock/redeem-latest") {
    const latest = [...sessions.values()].at(-1);
    if (!latest) return send(res, 404, "<p>No one is signed in.</p>");
    user(latest).premium = { plan: "key", expiresAt: new Date(Date.now() + 365 * 86400e3).toISOString() };
    return send(res, 200, `<p>Redeemed PPIE-TEST-TEST-TEST for ${esc(latest)}. Back in PasswordPie, press Check Again.</p>`);
  }
  send(res, 404, { error: "not-found" });
}).listen(port, "127.0.0.1", () => console.log(`mock passwordpie.com on http://localhost:${port}`));
