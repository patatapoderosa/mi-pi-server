/**
 * Shared HTTP remote-control auth (Mac <-> Windows server over Tailscale).
 *
 * Transport: plain HTTP inside the tailnet. Tailscale already encrypts every
 * byte with WireGuard, so no TLS is needed here (documented choice, see
 * docs/ARCHITECTURE.md). This module authenticates the APPLICATION layer:
 *
 *   X-Pi-Timestamp: unix seconds, e.g. "1735689600"
 *   X-Pi-Nonce:     random string, e.g. 32 hex chars
 *   X-Pi-Signature: hex HMAC-SHA256(secret, base) where base is
 *     METHOD + "\n" + PATH + "\n" + TS + "\n" + NONCE + "\n" + SHA256(body)
 *
 * METHOD is uppercased ("GET"/"PATCH"/...), PATH is the URL pathname only
 * (no query string), body is the EXACT raw request bytes (empty string for
 * bodiless requests). Both sides must hash identical bytes.
 *
 * Verification order on the server: headers present+well-formed -> signature
 * (constant-time) -> timestamp freshness -> persisted anti-replay nonce ->
 * route/module/schema checks. Nonce persistence lives in shared/store.ts
 * (ReplayStore); callers check it after a successful verify.
 *
 * No enums / namespaces: this file must survive Node's native type-stripping
 * (node --test imports it directly) and Pi's jiti loader alike.
 */
import {
  createHash,
  createHmac,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";

export const PROTOCOL_VERSION = 1;
export const DEFAULT_REMOTE_PORT = 43128;
export const MAX_CLOCK_SKEW_SECONDS_DEFAULT = 300;
export const MIN_NONCE_LENGTH = 8;
export const MAX_NONCE_LENGTH = 128;

export const HEADER_TIMESTAMP = "x-pi-timestamp";
export const HEADER_NONCE = "x-pi-nonce";
export const HEADER_SIGNATURE = "x-pi-signature";

export function createNonce(): string {
  return randomBytes(16).toString("hex");
}

export function sha256Hex(data: string | Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}

export interface SignatureInput {
  method: string;
  /** URL pathname only, no query string. */
  path: string;
  ts: number;
  nonce: string;
  /** Lowercase hex SHA256 of the EXACT raw request body ("" hashed when empty). */
  bodyHash: string;
}

/** Canonical signature base. Newline-joined so fields cannot blur together. */
export function signatureBase(input: SignatureInput): string {
  return [
    input.method.toUpperCase(),
    input.path,
    String(input.ts),
    input.nonce,
    input.bodyHash.toLowerCase(),
  ].join("\n");
}

export function signRequest(secret: string, input: SignatureInput): string {
  return createHmac("sha256", secret)
    .update(signatureBase(input), "utf8")
    .digest("hex");
}

function isHex64(value: string): boolean {
  return /^[0-9a-fA-F]{64}$/.test(value);
}

export function verifySignature(
  signatureHex: string,
  secret: string,
  input: SignatureInput,
): boolean {
  if (!isHex64(signatureHex)) return false;
  const expected = createHmac("sha256", secret)
    .update(signatureBase(input), "utf8")
    .digest();
  let actual: Buffer;
  try {
    actual = Buffer.from(signatureHex, "hex");
  } catch {
    return false;
  }
  if (actual.length !== expected.length) return false;
  return timingSafeEqual(actual, expected);
}

export type Freshness = "ok" | "bad_ts" | "ts_future" | "ts_expired";

export function checkFreshness(
  ts: unknown,
  nowSec: number,
  maxSkewSeconds: number,
): Freshness {
  if (typeof ts !== "number" || !Number.isInteger(ts) || ts < 0) {
    return "bad_ts";
  }
  const skew = Math.abs(nowSec - ts);
  if (skew > maxSkewSeconds) {
    return ts > nowSec ? "ts_future" : "ts_expired";
  }
  return "ok";
}

export interface ParsedAuth {
  ts: number;
  nonce: string;
  signature: string;
}

export type ParseAuthResult =
  | { ok: true; auth: ParsedAuth }
  | { ok: false; error: string };

/**
 * Parse + shape-check the three auth headers. Does NOT check freshness,
 * signature, or replay: the caller does that next (needs secret + store).
 * Header lookup is case-insensitive; header names are expected lowercase.
 */
export function parseAuthHeaders(
  get: (name: string) => string | string[] | undefined,
): ParseAuthResult {
  const first = (v: string | string[] | undefined): string | undefined =>
    Array.isArray(v) ? v[0] : v;
  const tsRaw = first(get(HEADER_TIMESTAMP));
  const nonce = first(get(HEADER_NONCE));
  const signature = first(get(HEADER_SIGNATURE));
  if (
    typeof tsRaw !== "string" ||
    typeof nonce !== "string" ||
    typeof signature !== "string"
  ) {
    return { ok: false, error: "missing_auth" };
  }
  if (!/^\d{1,10}$/.test(tsRaw.trim())) {
    return { ok: false, error: "bad_ts" };
  }
  if (
    nonce.length < MIN_NONCE_LENGTH ||
    nonce.length > MAX_NONCE_LENGTH ||
    !/^[A-Za-z0-9_.-]+$/.test(nonce)
  ) {
    return { ok: false, error: "bad_nonce" };
  }
  if (!isHex64(signature)) {
    return { ok: false, error: "bad_signature_shape" };
  }
  return {
    ok: true,
    auth: { ts: Number.parseInt(tsRaw.trim(), 10), nonce, signature },
  };
}
