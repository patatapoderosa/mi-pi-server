/**
 * Protocol tests: signing, verification, tampering, freshness, shape.
 * Run: npm test  (node --test tests/)
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  REMOTE_PREFIX,
  RESPONSE_PREFIX,
  b64urlDecode,
  b64urlEncode,
  canonicalize,
  createNonce,
  encodeEnvelope,
  encodeResponse,
  verifySignedText,
  verifyWireSignature,
} from "../shared/protocol.ts";

const SECRET = "test-secret-".repeat(4);
const NOW = 1_800_000_000;

function makeEnv(overrides: Record<string, unknown> = {}) {
  return encodeEnvelope(
    {
      op: "set_config",
      module: "example-monitor",
      patch: { intervalMinutes: 30 },
      ...overrides,
    } as never,
    SECRET,
  );
}

describe("canonicalize", () => {
  it("sorts keys recursively so signatures are deterministic", () => {
    const a = canonicalize({ z: 1, a: { d: 4, b: 2 }, m: [3, 1] });
    assert.equal(a, '{"a":{"b":2,"d":4},"m":[3,1],"z":1}');
  });
});

describe("b64url", () => {
  it("round-trips and rejects bad input", () => {
    const enc = b64urlEncode("hello world +/=");
    assert.match(enc, /^[A-Za-z0-9\-_]+$/);
    assert.equal(b64urlDecode(enc).toString("utf8"), "hello world +/=");
    assert.throws(() => b64urlDecode("***"), /bad_base64url/);
    assert.throws(() => b64urlDecode(""), /bad_base64url/);
  });
});

describe("verifySignedText (requests)", () => {
  it("accepts a valid envelope", () => {
    const r = verifySignedText(makeEnv(), REMOTE_PREFIX, { secret: SECRET });
    assert.equal(r.ok, true);
    if (r.ok) assert.equal(r.payload["op"], "set_config");
  });

  it("rejects a wrong signature", () => {
    const wire = makeEnv();
    const tampered = wire.slice(0, -1) + (wire.endsWith("0") ? "1" : "0");
    const r = verifySignedText(tampered, REMOTE_PREFIX, { secret: SECRET });
    assert.equal(r.ok, false);
    assert.equal(r.ok ? "" : r.error, "bad_signature");
  });

  it("rejects a wrong secret", () => {
    const r = verifySignedText(makeEnv(), REMOTE_PREFIX, {
      secret: "other-secret",
    });
    assert.equal(r.ok, false);
    assert.equal(r.ok ? "" : r.error, "bad_signature");
  });

  it("rejects a tampered payload (signature binds exact bytes)", () => {
    const wire = makeEnv();
    const [prefix, rest] = wire.split(" ");
    const [payload] = rest.split(".");
    const obj = JSON.parse(b64urlDecode(payload).toString("utf8")) as Record<
      string,
      unknown
    >;
    (obj["patch"] as Record<string, unknown>)["intervalMinutes"] = 1;
    const evil = `${prefix} ${b64urlEncode(JSON.stringify(obj))}.${rest.split(".")[1]}`;
    const r = verifySignedText(evil, REMOTE_PREFIX, { secret: SECRET });
    assert.equal(r.ok, false);
  });

  it("rejects expired timestamps", () => {
    const old = encodeEnvelope(
      { op: "ping", ts: NOW - 10_000 } as never,
      SECRET,
    );
    const r = verifySignedText(old, REMOTE_PREFIX, {
      secret: SECRET,
      nowSec: NOW,
      maxSkewSeconds: 300,
    });
    assert.equal(r.ok, false);
    assert.equal(r.ok ? "" : r.error, "ts_expired");
  });

  it("rejects future timestamps beyond skew", () => {
    const fut = encodeEnvelope(
      { op: "ping", ts: NOW + 10_000 } as never,
      SECRET,
    );
    const r = verifySignedText(fut, REMOTE_PREFIX, {
      secret: SECRET,
      nowSec: NOW,
      maxSkewSeconds: 300,
    });
    assert.equal(r.ok, false);
    assert.equal(r.ok ? "" : r.error, "ts_future");
  });

  it("accepts timestamps at the skew boundary", () => {
    const edge = encodeEnvelope({ op: "ping", ts: NOW - 300 } as never, SECRET);
    assert.equal(
      verifySignedText(edge, REMOTE_PREFIX, {
        secret: SECRET,
        nowSec: NOW,
        maxSkewSeconds: 300,
      }).ok,
      true,
    );
  });

  it("rejects malformed shapes", () => {
    for (const bad of [
      "hello",
      `${REMOTE_PREFIX}`,
      `${REMOTE_PREFIX} `,
      `${REMOTE_PREFIX} abc`,
      `${REMOTE_PREFIX} abc.`,
      `${REMOTE_PREFIX} .def`,
    ]) {
      const r = verifySignedText(bad, REMOTE_PREFIX, { secret: SECRET });
      assert.equal(r.ok, false, bad);
    }
  });

  it("rejects invalid op", () => {
    const wire = encodeEnvelope(
      { op: "run_command", command: "evil" } as never,
      SECRET,
    );
    const r = verifySignedText(wire, REMOTE_PREFIX, { secret: SECRET });
    assert.equal(r.ok, false);
    assert.equal(r.ok ? "" : r.error, "bad_op");
  });

  it("rejects non-object / non-JSON payloads", () => {
    const sig = "a".repeat(64);
    const arr = `${REMOTE_PREFIX} ${b64urlEncode("[1,2]")}.${"0".repeat(64)}`;
    void sig;
    assert.equal(
      verifySignedText(arr, REMOTE_PREFIX, { secret: SECRET }).ok,
      false,
    );
  });
});

describe("verifyWireSignature", () => {
  it("is strict about shape and length", () => {
    assert.equal(verifyWireSignature("e30", "xyz", SECRET), false);
    assert.equal(verifyWireSignature("e30", "00", SECRET), false);
  });
});

describe("responses", () => {
  it("correlates requestId and verifies with the same secret", () => {
    const requestId = `mac-test-${createNonce().slice(0, 8)}`;
    const wire = encodeResponse(
      { requestId, ok: true, body: { pong: true } },
      SECRET,
    );
    const r = verifySignedText(wire, RESPONSE_PREFIX, {
      secret: SECRET,
      checkEnvelope: false,
    });
    assert.equal(r.ok, true);
    if (r.ok) {
      assert.equal(r.payload["requestId"], requestId);
      assert.equal(r.payload["ok"], true);
    }
  });

  it("rejects responses signed with another secret", () => {
    const wire = encodeResponse({ ok: true }, SECRET);
    assert.equal(
      verifySignedText(wire, RESPONSE_PREFIX, {
        secret: "nope",
        checkEnvelope: false,
      }).ok,
      false,
    );
  });
});

describe("nonces", () => {
  it("are unique across calls", () => {
    const seen = new Set([
      createNonce(),
      createNonce(),
      createNonce(),
      createNonce(),
    ]);
    assert.equal(seen.size, 4);
  });
});
