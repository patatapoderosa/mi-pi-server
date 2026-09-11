/**
 * Shared remote-control protocol (Mac <-> old-PC server over Telegram).
 *
 * Transport reality (verified, Bot API >= 10.0, May 2026):
 * Telegram bots STILL cannot DM each other directly. Bot-to-bot delivery only
 * works inside groups / business chats, and only after each bot opts in to
 * "bot-to-bot communication mode" via @BotFather. So the Mac side uses the
 * ControlBot token over plain HTTPS (`sendMessage`) to post into a PRIVATE
 * group that contains ServerBot + ControlBot (+ owner). ServerBot's one and
 * only getUpdates loop (owned by @llblab/pi-telegram) observes that message,
 * and pi-remote-config intercepts it via the public update-handler registry.
 *
 * Wire format:
 *   PI_REMOTE_V1 <payloadB64url>.<sigB64url>
 * where payload is canonical JSON (sorted keys) and sig is
 * HMAC-SHA256(secret, payloadB64url-ascii).
 *
 * Response (server -> Mac, same group chat):
 *   PI_REMOTE_RESP_V1 <payloadB64url>.<sigB64url>
 *
 * No enums / namespaces: this file must survive Node's native type-stripping
 * (node --test imports it directly) and Pi's jiti loader alike.
 */
import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

export const PROTOCOL_VERSION = 1;
export const REMOTE_PREFIX = "PI_REMOTE_V1";
export const RESPONSE_PREFIX = "PI_REMOTE_RESP_V1";
export const MAX_CLOCK_SKEW_SECONDS_DEFAULT = 300;

export const REMOTE_OPS = [
 "set_config",
 "get_status",
 "ping",
 "service",
] as const;
export type RemoteOp = (typeof REMOTE_OPS)[number];

export interface SetConfigEnvelope {
 v: 1;
 ts: number;
 nonce: string;
 op: "set_config";
 module: string;
 patch: Record<string, string | number | boolean>;
 requestId?: string;
}

export interface ServiceEnvelope {
 v: 1;
 ts: number;
 nonce: string;
 op: "service";
 service: string;
 action: "restart" | "status";
 requestId?: string;
}

export interface SimpleEnvelope {
 v: 1;
 ts: number;
 nonce: string;
 op: "get_status" | "ping";
 requestId?: string;
}

export type RemoteEnvelope =
 | SetConfigEnvelope
 | ServiceEnvelope
 | SimpleEnvelope;

export interface RemoteResponse {
 v: 1;
 ts: number;
 nonce: string;
 requestId?: string;
 ok: boolean;
 /** Machine-readable result for ok responses. */
 body?: unknown;
 /** Short machine-readable error code for failures. */
 error?: string;
 /** Human-readable detail (safe to display, never contains secrets). */
 message?: string;
}

export function isRemoteOp(value: unknown): value is RemoteOp {
 return (
  typeof value === "string" && (REMOTE_OPS as readonly string[]).includes(value)
 );
}

/** URL-safe base64 without padding. */
export function b64urlEncode(input: string | Buffer): string {
 const buf = typeof input === "string" ? Buffer.from(input, "utf8") : input;
 return buf
  .toString("base64")
  .replace(/\+/g, "-")
  .replace(/\//g, "_")
  .replace(/=+$/g, "");
}

export function b64urlDecode(input: string): Buffer {
 if (!/^[A-Za-z0-9\-_]*$/.test(input) || input.length === 0) {
  throw new Error("bad_base64url");
 }
 const padded = input.replace(/-/g, "+").replace(/_/g, "/");
 return Buffer.from(padded, "base64");
}

/** Deterministic JSON: object keys sorted recursively. Arrays keep order. */
export function canonicalize(value: unknown): string {
 if (value === null || value === undefined) return "null";
 if (Array.isArray(value))
  return `[${value.map((v) => canonicalize(v)).join(",")}]`;
 if (typeof value === "object") {
  const entries = Object.entries(value as Record<string, unknown>)
   .filter(([, v]) => v !== undefined)
   .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalize(v)}`).join(",")}}`;
 }
 return JSON.stringify(value) ?? "null";
}

export function createNonce(): string {
 return randomBytes(16).toString("hex");
}

function hmacHex(secret: string, data: string): Buffer {
 return createHmac("sha256", secret).update(data, "utf8").digest();
}

/** Sign an envelope -> full wire string. Adds v/ts/nonce defaults when absent. */
export function encodeEnvelope(
 env: Omit<RemoteEnvelope, "v" | "ts" | "nonce"> &
  Partial<Pick<RemoteEnvelope, "v" | "ts" | "nonce">>,
 secret: string,
): string {
 const full = {
  v: 1 as const,
  ts: Math.floor(Date.now() / 1000),
  nonce: createNonce(),
  ...env,
 };
 const payloadB64 = b64urlEncode(canonicalize(full));
 const sig = hmacHex(secret, payloadB64).toString("hex");
 return `${REMOTE_PREFIX} ${payloadB64}.${sig}`;
}

export function encodeResponse(
 resp: Omit<RemoteResponse, "v" | "ts" | "nonce"> &
  Partial<Pick<RemoteResponse, "v" | "ts" | "nonce">>,
 secret: string,
): string {
 const full = {
  v: 1 as const,
  ts: Math.floor(Date.now() / 1000),
  nonce: createNonce(),
  ...resp,
 };
 const payloadB64 = b64urlEncode(canonicalize(full));
 const sig = hmacHex(secret, payloadB64).toString("hex");
 return `${RESPONSE_PREFIX} ${payloadB64}.${sig}`;
}

function splitWire(
 text: string,
 prefix: string,
): { payloadB64: string; sigHex: string } | { error: string } {
 const trimmed = text.trim();
 if (!trimmed.startsWith(prefix + " ")) return { error: "bad_prefix" };
 const rest =
  trimmed
   .slice(prefix.length + 1)
   .trim()
   .split(/\s+/)[0] ?? "";
 const dot = rest.lastIndexOf(".");
 if (dot <= 0 || dot === rest.length - 1) return { error: "bad_shape" };
 return { payloadB64: rest.slice(0, dot), sigHex: rest.slice(dot + 1) };
}

export function verifyWireSignature(
 payloadB64: string,
 sigHex: string,
 secret: string,
): boolean {
 if (!/^[0-9a-fA-F]{64}$/.test(sigHex)) return false;
 const expected = hmacHex(secret, payloadB64);
 let actual: Buffer;
 try {
  actual = Buffer.from(sigHex, "hex");
 } catch {
  return false;
 }
 if (actual.length !== expected.length) return false;
 return timingSafeEqual(actual, expected);
}

export interface VerifyOptions {
 secret: string;
 nowSec?: number;
 maxSkewSeconds?: number;
 /** When false, skips structural envelope checks (used for responses). */
 checkEnvelope?: boolean;
}

export type VerifyResult =
 | { ok: true; payload: Record<string, unknown> }
 | { ok: false; error: string };

/**
 * Verify prefix + base64 + JSON + HMAC + timestamp freshness + v.
 * Anti-replay (nonce persistence) is intentionally NOT here: it needs disk
 * state, see shared/store.ts ReplayStore. Callers must check the nonce after
 * a successful verify.
 */
export function verifySignedText(
 text: string,
 prefix: string,
 opts: VerifyOptions,
): VerifyResult {
 const split = splitWire(text, prefix);
 if ("error" in split) return { ok: false, error: split.error };
 let payload: unknown;
 try {
  payload = JSON.parse(b64urlDecode(split.payloadB64).toString("utf8"));
 } catch {
  return { ok: false, error: "bad_payload" };
 }
 if (
  typeof payload !== "object" ||
  payload === null ||
  Array.isArray(payload)
 ) {
  return { ok: false, error: "bad_payload" };
 }
 if (!verifyWireSignature(split.payloadB64, split.sigHex, opts.secret)) {
  return { ok: false, error: "bad_signature" };
 }
 const rec = payload as Record<string, unknown>;
 if (rec["v"] !== PROTOCOL_VERSION) return { ok: false, error: "bad_version" };
 if (typeof rec["ts"] !== "number" || !Number.isFinite(rec["ts"]))
  return { ok: false, error: "bad_ts" };
 if (
  typeof rec["nonce"] !== "string" ||
  rec["nonce"].length < 8 ||
  rec["nonce"].length > 128
 ) {
  return { ok: false, error: "bad_nonce" };
 }
 const now = opts.nowSec ?? Math.floor(Date.now() / 1000);
 const skew = Math.abs(now - (rec["ts"] as number));
 if (skew > (opts.maxSkewSeconds ?? MAX_CLOCK_SKEW_SECONDS_DEFAULT)) {
  return {
   ok: false,
   error: (rec["ts"] as number) > now ? "ts_future" : "ts_expired",
  };
 }
 if (opts.checkEnvelope !== false && !isRemoteOp(rec["op"])) {
  return { ok: false, error: "bad_op" };
 }
 return { ok: true, payload: rec };
}
