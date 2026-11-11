#!/usr/bin/env node
// Prints a passwordpie://activate link signed with the public test key, for trying activation on a debug build of either
// channel. Only debug and `make install` builds trust that key.
// Usage: node Scripts/mint-activation-link.mjs [days] [plan] [audience]
//   days      how long it lasts; negative for a link that has already run out (default 365)
//   audience  passwordpie-activation (default), or passwordpie-app to check that a token made for anything else is refused
import { createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const days = Number(process.argv[2] ?? 365);
const plan = process.argv[3] ?? "lifetime";
const aud = process.argv[4] ?? "passwordpie-activation";
const here = dirname(fileURLToPath(import.meta.url));
const testKey = JSON.parse(readFileSync(join(here, "../extension/dev/test-key.json"), "utf8"));
const key = createPrivateKey({ key: { kty: "OKP", crv: "Ed25519", x: testKey.x, d: testKey.d }, format: "jwk" });
const b64 = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const exp = now + Math.round(days * 86400);
// A real token is issued before it runs out, so an expired one was issued a day before its end.
const iat = Math.min(now, exp - 86400);
const header = b64({ alg: "EdDSA", typ: "JWT", kid: "pp-test" });
const claims = b64({ iss: "https://passwordpie.com", aud, sub: "mock-user", premium: true, plan, iat, exp });
const signature = sign(null, Buffer.from(`${header}.${claims}`), key).toString("base64url");
console.log(`passwordpie://activate?token=${header}.${claims}.${signature}`);
