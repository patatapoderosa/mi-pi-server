/**
 * HTTP HMAC auth tests: signing, verification, tampering, freshness, shape.
 * Run: npm test  (node --test tests/)
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  HEADER_NONCE,
  HEADER_SIGNATURE,
  HEADER_TIMESTAMP,
  checkFreshness,
  createNonce,
  parseAuthHeaders,
  sha256Hex,
  signRequest,
  signatureBase,
  verifySignature,
  type SignatureInput,
} from "../shared/protocol.ts";

const SECRET = "test-secret-".repeat(4);
const NOW = 1_800_000_000;

function input(overrides: Partial<SignatureInput> = {}): SignatureInput {
  return {
    method: "PATCH",
    path: "/v1/modules/example-monitor/config",
    ts: NOW,
    nonce: "a".repeat(32),
    bodyHash: sha256Hex('{"patch":{"intervalMinutes":30}}'),
    ...overrides,
  };
}

describe("signatureBase", () => {
  it("joins METHOD/PATH/TS/NONCE/BODYHASH with newlines, method uppercased", () => {
    assert.equal(
      signatureBase(input({ method: "patch" })),
      "PATCH\n/v1/modules/example-monitor/config\n1800000000\n" +
        "a".repeat(32) +
        "\n" +
        sha256Hex('{"patch":{"intervalMinutes":30}}'),
    );
  });
});

describe("sign/verify roundtrip", () => {
  it("accepts a valid signature", () => {
    const sig = signRequest(SECRET, input());
    assert.equal(verifySignature(sig, SECRET, input()), true);
  });

  it("rejects a wrong secret", () => {
    const sig = signRequest(SECRET, input());
    assert.equal(verifySignature(sig, "other-secret", input()), false);
  });

  it("rejects a flipped hex char", () => {
    const sig = signRequest(SECRET, input());
    const bad = sig.slice(0, -1) + (sig.endsWith("0") ? "1" : "0");
    assert.equal(verifySignature(bad, SECRET, input()), false);
  });

  it("rejects malformed signature shapes", () => {
    assert.equal(verifySignature("xyz", SECRET, input()), false);
    assert.equal(verifySignature("", SECRET, input()), false);
    assert.equal(verifySignature("00".repeat(32), SECRET, input()), false);
  });

  it("binds the exact body bytes (trailing space matters)", () => {
    const sig = signRequest(SECRET, input());
    const other = { ...input(), bodyHash: sha256Hex('{"patch":{"intervalMinutes":30}} ') };
    assert.equal(verifySignature(sig, SECRET, other), false);
  });

  it("binds method and path", () => {
    const sig = signRequest(SECRET, input());
    assert.equal(verifySignature(sig, SECRET, input({ method: "GET" })), false);
    assert.equal(
      verifySignature(sig, SECRET, input({ path: "/v1/status" })),
      false,
    );
  });

  it("binds timestamp and nonce", () => {
    const sig = signRequest(SECRET, input());
    assert.equal(verifySignature(sig, SECRET, input({ ts: NOW + 1 })), false);
    assert.equal(
      verifySignature(sig, SECRET, input({ nonce: "b".repeat(32) })),
      false,
    );
  });
});

describe("checkFreshness", () => {
  it("accepts fresh, rejects expired and future", () => {
    assert.equal(checkFreshness(NOW, NOW, 300), "ok");
    assert.equal(checkFreshness(NOW - 300, NOW, 300), "ok");
    assert.equal(checkFreshness(NOW - 301, NOW, 300), "ts_expired");
    assert.equal(checkFreshness(NOW + 301, NOW, 300), "ts_future");
  });
  it("rejects non-integer and negative ts", () => {
    assert.equal(checkFreshness(1.5, NOW, 300), "bad_ts");
    assert.equal(checkFreshness("x", NOW, 300), "bad_ts");
    assert.equal(checkFreshness(-5, NOW, 300), "bad_ts");
  });
});

describe("parseAuthHeaders", () => {
  const headers = () => ({
    [HEADER_TIMESTAMP]: String(NOW),
    [HEADER_NONCE]: "c".repeat(32),
    [HEADER_SIGNATURE]: "0".repeat(64),
  });
  const get = (h: Record<string, string>) => (n: string) => h[n];

  it("parses valid headers", () => {
    const r = parseAuthHeaders(get(headers()));
    assert.equal(r.ok, true);
    if (r.ok) {
      assert.equal(r.auth.ts, NOW);
      assert.equal(r.auth.nonce, "c".repeat(32));
    }
  });

  it("rejects missing headers", () => {
    const h = headers();
    delete (h as Record<string, string>)[HEADER_NONCE];
    const r = parseAuthHeaders(get(h));
    assert.equal(r.ok, false);
    if (!r.ok) assert.equal(r.error, "missing_auth");
  });

  it("rejects malformed ts and nonce", () => {
    const h1 = { ...headers(), [HEADER_TIMESTAMP]: "not-a-number" };
    assert.equal(parseAuthHeaders(get(h1)).ok, false);
    const h2 = { ...headers(), [HEADER_NONCE]: "short" };
    const r2 = parseAuthHeaders(get(h2));
    assert.equal(r2.ok, false);
    if (!r2.ok) assert.equal(r2.error, "bad_nonce");
    const h3 = { ...headers(), [HEADER_NONCE]: "has space in it................" };
    assert.equal(parseAuthHeaders(get(h3)).ok, false);
  });

  it("rejects malformed signature shape", () => {
    const h = { ...headers(), [HEADER_SIGNATURE]: "zzz" };
    const r = parseAuthHeaders(get(h));
    assert.equal(r.ok, false);
    if (!r.ok) assert.equal(r.error, "bad_signature_shape");
  });
});

describe("nonces", () => {
  it("are unique 32-hex strings", () => {
    const seen = new Set([createNonce(), createNonce(), createNonce()]);
    assert.equal(seen.size, 3);
    for (const n of seen) assert.match(n, /^[0-9a-f]{32}$/);
  });
});
