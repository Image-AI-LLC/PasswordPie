#!/usr/bin/env node
// Prints a passwordpie://activate link signed with the public test key, for trying activation on a debug App Store build.
// Only debug and `make install` builds trust that key. Usage: node Scripts/mint-activation-link.mjs [days] [plan]
import { createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const days = Number(process.argv[2] ?? 365);
const plan = process.argv[3] ?? "lifetime";
const here = dirname(fileURLToPath(import.meta.url));
const testKey = JSON.parse(readFileSync(join(here, "../extension/dev/test-key.json"), "utf8"));
const key = createPrivateKey({ key: { kty: "OKP", crv: "Ed25519", x: testKey.x, d: testKey.d }, format: "jwk" });
const b64 = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const iat = Math.floor(Date.now() / 1000);
const header = b64({ alg: "EdDSA", typ: "JWT", kid: "pp-test" });
const claims = b64({ iss: "https://passwordpie.com", aud: "passwordpie-activation", sub: "mock-user", premium: true, plan, iat, exp: iat + days * 86400 });
const signature = sign(null, Buffer.from(`${header}.${claims}`), key).toString("base64url");
console.log(`passwordpie://activate?token=${header}.${claims}.${signature}`);
