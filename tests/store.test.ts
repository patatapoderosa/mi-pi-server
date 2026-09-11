/**
 * Store tests: atomic writes, backups, persistent anti-replay.
 * Run: npm test  (node --test tests/)
 */
import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  ReplayStore,
  atomicWriteJson,
  backupFile,
  readJsonFile,
} from "../shared/store.ts";

const NOW = 1_800_000_000;
let dir = "";

beforeEach(() => {
  dir = join(
    tmpdir(),
    `pi-remote-test-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}`,
  );
  mkdirSync(dir, { recursive: true });
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("atomicWriteJson", () => {
  it("writes valid JSON and leaves no tmp files behind", () => {
    const f = join(dir, "sub", "cfg.json");
    atomicWriteJson(f, { a: 1 }, 0o600);
    assert.deepEqual(JSON.parse(readFileSync(f, "utf8")), { a: 1 });
    assert.deepEqual(readdirSync(join(dir, "sub")), ["cfg.json"]);
  });

  it("overwrites atomically (never a half-written file)", () => {
    const f = join(dir, "cfg.json");
    atomicWriteJson(f, { n: 1 });
    atomicWriteJson(f, { n: 2 });
    assert.deepEqual(JSON.parse(readFileSync(f, "utf8")), { n: 2 });
  });
});

describe("backupFile", () => {
  it("copies existing files and returns null for missing ones", () => {
    assert.equal(backupFile(join(dir, "nope.json")), null);
    const f = join(dir, "cfg.json");
    writeFileSync(f, '{"a":1}');
    const bak = backupFile(f);
    assert.ok(bak && existsSync(bak));
    assert.equal(readFileSync(bak, "utf8"), '{"a":1}');
  });
});

describe("readJsonFile", () => {
  it("falls back on missing or corrupt files (server must not crash)", () => {
    assert.deepEqual(readJsonFile(join(dir, "missing.json"), { d: 1 }), {
      d: 1,
    });
    const f = join(dir, "corrupt.json");
    writeFileSync(f, "{not json");
    assert.deepEqual(readJsonFile(f, { d: 2 }), { d: 2 });
  });
});

describe("ReplayStore", () => {
  it("rejects duplicate nonces and survives restart (disk persistence)", () => {
    const f = join(dir, "remote-state.json");
    const s1 = new ReplayStore(f, 600);
    assert.equal(s1.has("abc12345", NOW), false);
    s1.add("abc12345", NOW, NOW);
    assert.equal(s1.has("abc12345", NOW), true);

    // Simulate a process restart: reload from the same file.
    const s2 = new ReplayStore(f, 600);
    assert.equal(s2.has("abc12345", NOW), true);
  });

  it("expires nonces outside the window and prunes on write", () => {
    const f = join(dir, "remote-state.json");
    const s = new ReplayStore(f, 600);
    s.add("old-nonce-1", NOW - 10_000, NOW - 10_000);
    assert.equal(s.has("old-nonce-1", NOW), false);
    const snap = s.snapshot();
    assert.ok(!snap.nonces.some((e) => e.n === "old-nonce-1"));
  });

  it("records last update and last error for status reporting", () => {
    const f = join(dir, "remote-state.json");
    const s = new ReplayStore(f, 600);
    s.recordUpdate({
      at: NOW,
      op: "set_config",
      module: "example-monitor",
      ok: true,
    });
    s.recordError("remote_handler", "boom");
    const snap = new ReplayStore(f, 600).snapshot();
    assert.equal(snap.lastRemoteUpdate?.op, "set_config");
    assert.equal(snap.lastError?.where, "remote_handler");
  });
});
