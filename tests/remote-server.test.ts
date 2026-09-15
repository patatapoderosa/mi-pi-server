/**
 * Remote daemon integration tests: boot in-process on 127.0.0.1, exercise
 * every endpoint, auth failures, migration, and bind resolution.
 * Run: npm test  (node --test tests/)
 */
import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import {
  mkdtempSync,
  rmSync,
  readFileSync,
  writeFileSync,
  mkdirSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createNonce, sha256Hex, signRequest } from "../shared/protocol.ts";
import {
  createRemoteServer,
  loadRemoteServerConfig,
  readAppVersion,
  type RemoteServerConfig,
} from "../server/pi-remote-server/server.ts";
import {
  getTailscaleIpv4,
  isTailscaleIpv4,
  resolveListenAddress,
} from "../server/pi-remote-server/tailscale.ts";
import {
  clampSkew,
  migrateLegacyConfig,
  stringList,
  validPort,
} from "../server/pi-remote-server/migrate.ts";
import { atomicWriteJson } from "../shared/store.ts";

const SECRET = "integration-secret-".repeat(4);

function testConfig(): RemoteServerConfig {
  return { port: 43128, maxSkewSeconds: 300, allowedServices: ["pi-server"] };
}

interface Started {
  server: Server;
  port: number;
  agentDir: string;
  cleanup: () => void;
}

async function boot(agentDir?: string): Promise<Started> {
  const owned = agentDir === undefined;
  const dir = agentDir ?? mkdtempSync(join(tmpdir(), "pi-remote-test-"));
  mkdirSync(join(dir, "secrets"), { recursive: true });
  writeFileSync(join(dir, "secrets", "remote-hmac"), SECRET);
  const { server } = createRemoteServer({
    agentDir: dir,
    hmac: SECRET,
    config: testConfig(),
    bindHost: "127.0.0.1",
    version: "test",
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.removeListener("error", reject);
      resolve();
    });
  });
  const port = (server.address() as AddressInfo).port;
  return {
    server,
    port,
    agentDir: dir,
    cleanup: () => {
      server.close();
      if (owned) rmSync(dir, { recursive: true, force: true });
    },
  };
}

function closeSocket(s: Started): Promise<void> {
  return new Promise((resolve) => {
    s.server.close();
    // give the socket a tick to release before rm -rf
    setTimeout(resolve, 50);
  });
}

function close(s: Started): Promise<void> {
  return new Promise((resolve) => {
    s.cleanup();
    // give the socket a tick to release before rm -rf
    setTimeout(resolve, 50);
  });
}

interface SignedOpts {
  method?: string;
  body?: string;
  ts?: number;
  nonce?: string;
  secret?: string;
  headers?: Record<string, string>;
  rawPath?: string;
}

/** Mirror of the Mac signing logic: sign EXACT bytes, then send them. */
async function signed(
  port: number,
  path: string,
  opts: SignedOpts = {},
): Promise<{ status: number; json: Record<string, unknown> }> {
  const method = opts.method ?? "GET";
  const body = opts.body ?? "";
  const ts = opts.ts ?? Math.floor(Date.now() / 1000);
  const nonce = opts.nonce ?? createNonce();
  const secret = opts.secret ?? SECRET;
  const sig = signRequest(secret, {
    method,
    path,
    ts,
    nonce,
    bodyHash: sha256Hex(body),
  });
  const res = await fetch(`http://127.0.0.1:${port}${opts.rawPath ?? path}`, {
    method,
    headers: {
      "content-type": "application/json",
      "x-pi-timestamp": String(ts),
      "x-pi-nonce": nonce,
      "x-pi-signature": sig,
      ...(opts.headers ?? {}),
    },
    body: method === "GET" ? undefined : body,
  });
  const json = (await res.json()) as Record<string, unknown>;
  return { status: res.status, json };
}

describe("unauthenticated surface", () => {
  let s: Started;
  beforeEach(async () => {
    s = await boot();
  });
  afterEach(async () => {
    await close(s);
    rmSync(s.agentDir, { recursive: true, force: true });
  });

  it("GET /v1/health answers without auth", async () => {
    const res = await fetch(`http://127.0.0.1:${s.port}/v1/health`);
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, unknown>;
    assert.equal(body["ok"], true);
    assert.equal(body["service"], "pi-remote-server");
  });

  it("GET /v1/status without auth is 401 missing_auth", async () => {
    const res = await fetch(`http://127.0.0.1:${s.port}/v1/status`);
    assert.equal(res.status, 401);
    const body = (await res.json()) as Record<string, unknown>;
    assert.equal(body["error"], "missing_auth");
  });

  it("unknown paths are 404", async () => {
    const r = await signed(s.port, "/v1/nope", {});
    assert.equal(r.status, 404);
    assert.equal(r.json["error"], "not_found");
  });

  it("query strings are rejected (not part of signed path)", async () => {
    const r = await signed(s.port, "/v1/status", { rawPath: "/v1/status?x=1" });
    assert.equal(r.status, 400);
    assert.equal(r.json["error"], "query_not_allowed");
  });
});

describe("authenticated happy paths", () => {
  let s: Started;
  beforeEach(async () => {
    s = await boot();
  });
  afterEach(async () => {
    await close(s);
    rmSync(s.agentDir, { recursive: true, force: true });
  });

  it("GET /v1/ping returns pong", async () => {
    const r = await signed(s.port, "/v1/ping", {});
    assert.equal(r.status, 200);
    assert.deepEqual(r.json["body"], { pong: true });
  });

  it("GET /v1/status returns the node status without secrets", async () => {
    const r = await signed(s.port, "/v1/status", {});
    assert.equal(r.status, 200);
    const body = r.json["body"] as Record<string, unknown>;
    assert.equal(body["online"], true);
    assert.ok(typeof body["hostname"] === "string");
    assert.ok(typeof body["node"] === "string");
    assert.ok(Array.isArray(body["modules"]));
    const names = (body["modules"] as Array<{ name: string }>).map(
      (m) => m.name,
    );
    assert.ok(names.includes("core"));
    assert.ok(names.includes("example-monitor"));
    const dumped = JSON.stringify(body);
    assert.ok(!dumped.includes(SECRET));
  });

  it("GET /v1/modules lists modules with configs", async () => {
    const r = await signed(s.port, "/v1/modules", {});
    assert.equal(r.status, 200);
    const mods = (
      r.json["body"] as {
        modules: Array<{ name: string; enabled: boolean | null }>;
      }
    ).modules;
    assert.equal(mods.length, 2);
    const mon = mods.find((m) => m.name === "example-monitor");
    assert.equal(mon?.enabled, true);
  });

  it("PATCH config writes to disk and reads back", async () => {
    const r = await signed(s.port, "/v1/modules/example-monitor/config", {
      method: "PATCH",
      body: JSON.stringify({ patch: { intervalMinutes: 45 } }),
    });
    assert.equal(r.status, 200);
    const onDisk = JSON.parse(
      readFileSync(
        join(s.agentDir, "server-config", "example-monitor.json"),
        "utf8",
      ),
    ) as Record<string, unknown>;
    assert.equal(onDisk["intervalMinutes"], 45);
    const st = await signed(s.port, "/v1/modules/example-monitor/status", {});
    assert.equal(
      (st.json["body"] as { config: Record<string, unknown> }).config[
        "intervalMinutes"
      ],
      45,
    );
  });

  it("POST enable/disable flips the enabled flag", async () => {
    const off = await signed(s.port, "/v1/modules/example-monitor/disable", {
      method: "POST",
      body: "{}",
    });
    assert.equal(off.status, 200);
    const st = await signed(s.port, "/v1/modules/example-monitor/status", {});
    assert.equal((st.json["body"] as { enabled: boolean }).enabled, false);
    const on = await signed(s.port, "/v1/modules/example-monitor/enable", {
      method: "POST",
      body: "{}",
    });
    assert.equal(on.status, 200);
    const st2 = await signed(s.port, "/v1/modules/example-monitor/status", {});
    assert.equal((st2.json["body"] as { enabled: boolean }).enabled, true);
  });

  it("enable on a module without an enabled field is 400", async () => {
    const r = await signed(s.port, "/v1/modules/core/enable", {
      method: "POST",
      body: "{}",
    });
    assert.equal(r.status, 400);
    assert.equal(r.json["error"], "no_enabled_field");
  });
});

describe("auth failures", () => {
  let s: Started;
  beforeEach(async () => {
    s = await boot();
  });
  afterEach(async () => {
    await close(s);
    rmSync(s.agentDir, { recursive: true, force: true });
  });

  it("wrong secret is 401 bad_signature", async () => {
    const r = await signed(s.port, "/v1/ping", { secret: "wrong" });
    assert.equal(r.status, 401);
    assert.equal(r.json["error"], "bad_signature");
  });

  it("tampered body is 401 (signature binds exact bytes)", async () => {
    const ts = Math.floor(Date.now() / 1000);
    const nonce = createNonce();
    const sig = signRequest(SECRET, {
      method: "PATCH",
      path: "/v1/modules/example-monitor/config",
      ts,
      nonce,
      bodyHash: sha256Hex('{"patch":{"intervalMinutes":30}}'),
    });
    const res = await fetch(
      `http://127.0.0.1:${s.port}/v1/modules/example-monitor/config`,
      {
        method: "PATCH",
        headers: {
          "content-type": "application/json",
          "x-pi-timestamp": String(ts),
          "x-pi-nonce": nonce,
          "x-pi-signature": sig,
        },
        body: '{"patch":{"intervalMinutes":31}}',
      },
    );
    assert.equal(res.status, 401);
    assert.equal(
      ((await res.json()) as Record<string, unknown>)["error"],
      "bad_signature",
    );
  });

  it("expired and future timestamps are rejected", async () => {
    const now = Math.floor(Date.now() / 1000);
    const old = await signed(s.port, "/v1/ping", { ts: now - 3600 });
    assert.equal(old.status, 401);
    assert.equal(old.json["error"], "ts_expired");
    const fut = await signed(s.port, "/v1/ping", { ts: now + 3600 });
    assert.equal(fut.status, 401);
    assert.equal(fut.json["error"], "ts_future");
  });

  it("duplicate nonce is 401 replay, also after restart", async () => {
    const nonce = createNonce();
    const first = await signed(s.port, "/v1/ping", { nonce });
    assert.equal(first.status, 200);
    const replay = await signed(s.port, "/v1/ping", {
      nonce,
      ts: Math.floor(Date.now() / 1000),
    });
    assert.equal(replay.status, 401);
    assert.equal(replay.json["error"], "replay");
    // restart: new server instance, same agent dir -> still rejected (disk persistence).
    // NOTE: closeSocket only (no rm): close() would delete the temp dir.
    await closeSocket(s);
    s = await boot(s.agentDir);
    const afterRestart = await signed(s.port, "/v1/ping", {
      nonce,
      ts: Math.floor(Date.now() / 1000),
    });
    assert.equal(afterRestart.status, 401);
    assert.equal(afterRestart.json["error"], "replay");
  });

  it("malformed JSON body is 400", async () => {
    const r = await signed(s.port, "/v1/modules/example-monitor/config", {
      method: "PATCH",
      body: "{not json",
    });
    assert.equal(r.status, 400);
    assert.equal(r.json["error"], "malformed_json");
  });

  it("unknown module is 404, invalid name is 404", async () => {
    const r = await signed(s.port, "/v1/modules/nope/status", {});
    assert.equal(r.status, 404);
    assert.equal(r.json["error"], "unknown_module");
    const r2 = await signed(s.port, "/v1/modules/not_a_module!/status", {});
    assert.equal(r2.status, 404);
  });

  it("invalid patch is 400 with details, file untouched", async () => {
    const before = await signed(
      s.port,
      "/v1/modules/example-monitor/status",
      {},
    );
    const bad = await signed(s.port, "/v1/modules/example-monitor/config", {
      method: "PATCH",
      body: JSON.stringify({ patch: { intervalMinutes: 99999, evil: 1 } }),
    });
    assert.equal(bad.status, 400);
    assert.equal(bad.json["error"], "invalid_patch");
    const after = await signed(
      s.port,
      "/v1/modules/example-monitor/status",
      {},
    );
    assert.deepEqual(after.json["body"], before.json["body"]);
  });

  it("oversized body is rejected and the server stays alive", async () => {
    const big = "x".repeat(300 * 1024);
    const ts = Math.floor(Date.now() / 1000);
    const nonce = createNonce();
    const sig = signRequest(SECRET, {
      method: "PATCH",
      path: "/v1/modules/example-monitor/config",
      ts,
      nonce,
      bodyHash: sha256Hex(big),
    });
    let rejected = false;
    try {
      const res2 = await fetch(
        `http://127.0.0.1:${s.port}/v1/modules/example-monitor/config`,
        {
          method: "PATCH",
          headers: {
            "content-type": "application/json",
            "x-pi-timestamp": String(ts),
            "x-pi-nonce": nonce,
            "x-pi-signature": sig,
          },
          body: big,
        },
      );
      rejected = res2.status === 413;
      try {
        await res2.arrayBuffer();
      } catch {
        // body already gone with the socket; status is what counts
      }
    } catch {
      rejected = true; // socket destroyed mid-upload: also a rejection
    }
    assert.equal(rejected, true);
    // liveness: a normal request right after still works
    const live = await signed(s.port, "/v1/ping", {});
    assert.equal(live.status, 200);
  });

  it("maintenance mode blocks mutations but not reads", async () => {
    atomicWriteJson(join(s.agentDir, "server-config", "core.json"), {
      maintenanceMode: true,
      remoteControlEnabled: true,
    });
    const w = await signed(s.port, "/v1/modules/example-monitor/config", {
      method: "PATCH",
      body: JSON.stringify({ patch: { intervalMinutes: 10 } }),
    });
    assert.equal(w.status, 403);
    assert.equal(w.json["error"], "maintenance");
    const r = await signed(s.port, "/v1/status", {});
    assert.equal(r.status, 200);
  });
});

describe("config loading", () => {
  it("defaults apply, invalid values fall back", () => {
    const dir = mkdtempSync(join(tmpdir(), "pi-remote-cfg-"));
    try {
      const d = loadRemoteServerConfig(dir);
      assert.equal(d.port, 43128);
      assert.equal(d.maxSkewSeconds, 300);
      assert.deepEqual(d.allowedServices, ["pi-server"]);
      assert.equal(d.bindHost, undefined);
      writeFileSync(
        join(dir, "remote-server.json"),
        JSON.stringify({
          port: 99999,
          maxSkewSeconds: 5,
          allowedServices: "x",
        }),
      );
      const d2 = loadRemoteServerConfig(dir);
      assert.equal(d2.port, 43128);
      assert.equal(d2.maxSkewSeconds, 30);
      assert.deepEqual(d2.allowedServices, ["pi-server"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("readAppVersion reads VERSION, then package.json, then dev", () => {
    const dir = mkdtempSync(join(tmpdir(), "pi-remote-ver-"));
    try {
      assert.equal(readAppVersion(dir), "dev");
      writeFileSync(
        join(dir, "package.json"),
        JSON.stringify({ version: "9.9.9" }),
      );
      assert.equal(readAppVersion(dir), "9.9.9");
      writeFileSync(join(dir, "VERSION"), "vX");
      assert.equal(readAppVersion(dir), "vX");
      assert.equal(readAppVersion(null), "dev");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("migration", () => {
  it("converts legacy remote-auth.json, preserves HMAC, removes legacy", () => {
    const dir = mkdtempSync(join(tmpdir(), "pi-remote-mig-"));
    try {
      mkdirSync(join(dir, "secrets"), { recursive: true });
      writeFileSync(join(dir, "secrets", "remote-hmac"), "keep-me");
      writeFileSync(
        join(dir, "remote-auth.json"),
        JSON.stringify({
          allowedControlBotId: 123,
          controlChatId: -456,
          maxSkewSeconds: 600,
          allowedServices: ["pi-server"],
        }),
      );
      const r = migrateLegacyConfig(dir);
      assert.equal(r.migrated, true);
      assert.ok(r.backupPath);
      const kept = readFileSync(join(dir, "secrets", "remote-hmac"), "utf8");
      assert.equal(kept, "keep-me");
      const cfg = JSON.parse(
        readFileSync(join(dir, "remote-server.json"), "utf8"),
      ) as Record<string, unknown>;
      assert.equal(cfg["port"], 43128);
      assert.equal(cfg["maxSkewSeconds"], 600);
      assert.ok(!("allowedControlBotId" in cfg));
      assert.ok(!("controlChatId" in cfg));
      let legacyGone = false;
      try {
        readFileSync(join(dir, "remote-auth.json"), "utf8");
      } catch {
        legacyGone = true;
      }
      assert.equal(legacyGone, true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("never overwrites an existing remote-server.json", () => {
    const dir = mkdtempSync(join(tmpdir(), "pi-remote-mig2-"));
    try {
      writeFileSync(
        join(dir, "remote-auth.json"),
        JSON.stringify({ allowedControlBotId: 1, controlChatId: 2 }),
      );
      writeFileSync(
        join(dir, "remote-server.json"),
        JSON.stringify({
          port: 1234,
          maxSkewSeconds: 300,
          allowedServices: [],
        }),
      );
      const r = migrateLegacyConfig(dir);
      assert.equal(r.migrated, true);
      const cfg = JSON.parse(
        readFileSync(join(dir, "remote-server.json"), "utf8"),
      ) as Record<string, unknown>;
      assert.equal(cfg["port"], 1234);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("no legacy file means no migration", () => {
    const dir = mkdtempSync(join(tmpdir(), "pi-remote-mig3-"));
    try {
      const r = migrateLegacyConfig(dir);
      assert.equal(r.migrated, false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("helpers clamp and default sanely", () => {
    assert.equal(clampSkew(600), 600);
    assert.equal(clampSkew(5), 30);
    assert.equal(clampSkew("x"), 300);
    assert.deepEqual(stringList(["a", 1]), ["a"]);
    assert.deepEqual(stringList([]), ["pi-server"]);
    assert.equal(validPort(43128), 43128);
    assert.equal(validPort(0), 43128);
    assert.equal(validPort(70000), 43128);
  });
});

describe("tailscale bind resolution", () => {
  it("validates the CGNAT range strictly", () => {
    assert.equal(isTailscaleIpv4("100.64.0.1"), true);
    assert.equal(isTailscaleIpv4("100.127.255.254"), true);
    assert.equal(isTailscaleIpv4("100.63.0.1"), false);
    assert.equal(isTailscaleIpv4("100.128.0.1"), false);
    assert.equal(isTailscaleIpv4("192.168.1.1"), false);
    assert.equal(isTailscaleIpv4("100.64.0.999"), false);
    assert.equal(isTailscaleIpv4("garbage"), false);
    assert.equal(isTailscaleIpv4(null), false);
  });

  it("reads the first valid line from tailscale output", () => {
    const ip = getTailscaleIpv4(() => "100.99.8.7\nfd7a:115c::123\n");
    assert.equal(ip, "100.99.8.7");
    assert.equal(
      getTailscaleIpv4(() => "nope"),
      null,
    );
    assert.equal(
      getTailscaleIpv4(() => {
        throw new Error("missing binary");
      }),
      null,
    );
  });

  it("prefers override, then tailscale, then loopback with warning", () => {
    const a = resolveListenAddress({ tailscaleIp: "100.99.8.7" });
    assert.deepEqual([a.host, a.source], ["100.99.8.7", "tailscale"]);
    const b = resolveListenAddress({
      bindOverride: "127.0.0.1",
      tailscaleIp: "100.99.8.7",
    });
    assert.deepEqual([b.host, b.source], ["127.0.0.1", "override"]);
    const c = resolveListenAddress({ tailscaleIp: null });
    assert.deepEqual([c.host, c.source], ["127.0.0.1", "loopback-fallback"]);
    assert.ok(typeof c.warning === "string");
  });
});

describe("client transport failures", () => {
  it("times out against a hanging server", async () => {
    const hanging = createServer(() => {
      // never respond
    });
    await new Promise<void>((resolve) =>
      hanging.listen(0, "127.0.0.1", resolve),
    );
    const port = (hanging.address() as AddressInfo).port;
    try {
      await fetch(`http://127.0.0.1:${port}/v1/ping`, {
        signal: AbortSignal.timeout(300),
      });
      assert.fail("should have timed out");
    } catch (err) {
      assert.ok(err instanceof Error);
    } finally {
      hanging.close();
    }
  });

  it("closed port surfaces a clear unreachable error", async () => {
    const probe = createServer();
    await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
    const port = (probe.address() as AddressInfo).port;
    await new Promise<void>((resolve) => probe.close(() => resolve()));
    try {
      await fetch(`http://127.0.0.1:${port}/v1/ping`, {
        signal: AbortSignal.timeout(3000),
      });
      assert.fail("should have refused");
    } catch (err) {
      assert.ok(err instanceof Error);
      assert.ok(!/HMAC|signature/i.test(err.message));
    }
  });
});

describe("server_model routes (fake pi on PATH)", () => {
  let s: Started;
  let binDir = "";
  let oldPath = "";
  let oldComSpec: string | undefined;

  function writeFakePi(dir: string): void {
    if (process.platform === "win32") {
      writeFileSync(
        join(dir, "pi.cmd"),
        "@echo off\r\n" +
          'if "%1"=="--list-models" (\r\n' +
          "  echo provider  model         context  max-out  thinking  images\r\n" +
          "  echo anthropic  claude-opus-4-8  200K  32K  yes  no\r\n" +
          "  echo openai  gpt-5.5  400K  128K  no  no\r\n" +
          "  exit /b 0\r\n" +
          ")\r\n" +
          'if "%1"=="auth" (\r\n' +
          '  if "%4"=="anthropic" (\r\n' +
          '    echo {"status":"ready","provider":"anthropic","authType":"api_key"}\r\n' +
          "    exit /b 0\r\n" +
          "  )\r\n" +
          '  echo {"status":"not_ready","provider":"%4","reason":"credentials_not_configured"}\r\n' +
          "  exit /b 1\r\n" +
          ")\r\n" +
          "exit /b 2\r\n",
      );
    } else {
      writeFileSync(
        join(dir, "pi"),
        "#!/bin/sh\n" +
          'if [ "$1" = "--list-models" ]; then\n' +
          '  printf "%s\\n" "provider  model         context  max-out  thinking  images" "anthropic  claude-opus-4-8  200K  32K  yes  no" "openai  gpt-5.5  400K  128K  no  no"\n' +
          "  exit 0\n" +
          "fi\n" +
          'if [ "$1" = "auth" ]; then\n' +
          '  if [ "$4" = "anthropic" ]; then\n' +
          '    printf "%s\\n" "{\\"status\\":\\"ready\\",\\"provider\\":\\"anthropic\\",\\"authType\\":\\"api_key\\"}"\n' +
          "    exit 0\n" +
          "  fi\n" +
          '  printf "%s\\n" "{\\"status\\":\\"not_ready\\",\\"provider\\":\\"$4\\",\\"reason\\":\\"credentials_not_configured\\"}"\n' +
          "  exit 1\n" +
          "fi\n" +
          "exit 2\n",
        { mode: 0o755 },
      );
    }
  }

  beforeEach(async () => {
    s = await boot();
    binDir = mkdtempSync(join(tmpdir(), "pi-fakebin-"));
    writeFakePi(binDir);
    oldPath = process.env.PATH ?? "";
    process.env.PATH =
      binDir + (process.platform === "win32" ? ";" : ":") + oldPath;
    oldComSpec = process.env.ComSpec;
  });

  afterEach(async () => {
    process.env.PATH = oldPath;
    if (oldComSpec === undefined) delete process.env.ComSpec;
    else process.env.ComSpec = oldComSpec;
    await close(s);
    rmSync(s.agentDir, { recursive: true, force: true });
    rmSync(binDir, { recursive: true, force: true });
  });

  it("GET /v1/model reports unset when no settings.json", async () => {
    const r = await signed(s.port, "/v1/model", {});
    assert.equal(r.status, 200);
    const b = r.json["body"] as Record<string, unknown>;
    assert.equal(b["provider"], null);
    assert.equal(b["source"], "unset");
    assert.equal(b["requiresRestart"], false);
    assert.equal(b["liveModel"], null);
    assert.ok(String(b["settingsPath"]).endsWith("settings.json"));
  });

  it("GET /v1/model reports configured default", async () => {
    writeFileSync(
      join(s.agentDir, "settings.json"),
      JSON.stringify({
        defaultProvider: "anthropic",
        defaultModel: "claude-opus-4-8",
        theme: "dark",
      }),
    );
    const r = await signed(s.port, "/v1/model", {});
    assert.equal(r.status, 200);
    const b = r.json["body"] as Record<string, unknown>;
    assert.equal(b["provider"], "anthropic");
    assert.equal(b["model"], "claude-opus-4-8");
    assert.equal(b["source"], "settings.json");
    assert.equal(b["requiresRestart"], true);
  });

  it("GET /v1/models lists catalog with per-provider auth", async () => {
    const r = await signed(s.port, "/v1/models", {});
    assert.equal(r.status, 200);
    const b = r.json["body"] as {
      models: Array<Record<string, unknown>>;
      truncated: boolean;
    };
    assert.equal(b.models.length, 2);
    const a = b.models[0];
    assert.equal(a["provider"], "anthropic");
    assert.equal(a["id"], "claude-opus-4-8");
    assert.equal(a["authenticated"], true);
    assert.equal(a["authType"], "api_key");
    assert.equal(a["thinking"], true);
    const o = b.models[1];
    assert.equal(o["provider"], "openai");
    assert.equal(o["authenticated"], false);
    assert.equal(b.truncated, false);
  });

  it("POST /v1/model/validate accepts a good selection dry-run", async () => {
    const r = await signed(s.port, "/v1/model/validate", {
      method: "POST",
      body: JSON.stringify({ provider: "anthropic", model: "claude-opus-4-8" }),
    });
    assert.equal(r.status, 200);
    const b = r.json["body"] as Record<string, unknown>;
    assert.equal(b["valid"], true);
    assert.equal(b["provider"], "anthropic");
  });

  it("POST /v1/model/validate rejects unknown model", async () => {
    const r = await signed(s.port, "/v1/model/validate", {
      method: "POST",
      body: JSON.stringify({ provider: "anthropic", model: "nope-99" }),
    });
    assert.equal(r.status, 400);
    assert.equal(r.json["error"], "model_not_found");
  });

  it("POST /v1/model/validate rejects unauthenticated provider", async () => {
    const r = await signed(s.port, "/v1/model/validate", {
      method: "POST",
      body: JSON.stringify({ provider: "openai", model: "gpt-5.5" }),
    });
    assert.equal(r.status, 400);
    assert.equal(r.json["error"], "provider_not_authenticated");
  });

  it("POST /v1/model writes default, preserves rest, backups", async () => {
    writeFileSync(
      join(s.agentDir, "settings.json"),
      JSON.stringify({ theme: "dark" }),
    );
    const r = await signed(s.port, "/v1/model", {
      method: "POST",
      body: JSON.stringify({
        provider: "anthropic",
        model: "claude-opus-4-8",
        thinkingLevel: "high",
      }),
    });
    assert.equal(r.status, 200);
    const b = r.json["body"] as Record<string, unknown>;
    assert.equal(b["provider"], "anthropic");
    assert.equal(b["thinkingLevel"], "high");
    assert.equal(b["requiresRestart"], true);
    assert.equal(b["applied"], false);
    assert.ok(typeof b["backup"] === "string");
    const raw = JSON.parse(
      readFileSync(join(s.agentDir, "settings.json"), "utf8"),
    ) as Record<string, unknown>;
    assert.equal(raw["theme"], "dark");
    assert.equal(raw["defaultModel"], "claude-opus-4-8");
  });

  it("POST /v1/model rejects bad thinking level and unknown fields", async () => {
    const bad = await signed(s.port, "/v1/model", {
      method: "POST",
      body: JSON.stringify({
        model: "claude-opus-4-8",
        thinkingLevel: "ultra",
      }),
    });
    assert.equal(bad.status, 400);
    assert.match(String(bad.json["error"]), /invalid_thinking_level/);
    const unk = await signed(s.port, "/v1/model", {
      method: "POST",
      body: JSON.stringify({ model: "x", shell: "rm -rf /" }),
    });
    assert.equal(unk.status, 400);
    assert.match(String(unk.json["error"]), /unknown_field/);
  });

  it("POST /v1/model honors maintenance gate", async () => {
    mkdirSync(join(s.agentDir, "server-config"), { recursive: true });
    writeFileSync(
      join(s.agentDir, "server-config", "core.json"),
      JSON.stringify({ maintenanceMode: true }),
    );
    const r = await signed(s.port, "/v1/model", {
      method: "POST",
      body: JSON.stringify({ provider: "anthropic", model: "claude-opus-4-8" }),
    });
    assert.equal(r.status, 403);
    assert.equal(r.json["error"], "maintenance");
  });
});

describe("server_doctor / server_update routes (v3 fixture, no spawn)", () => {
  let s: Started;
  let root = "";
  let dataDir = "";

  function writeJson(rel: string, v: unknown): void {
    const fp = join(root, rel);
    mkdirSync(join(fp, ".."), { recursive: true });
    writeFileSync(fp, JSON.stringify(v));
  }

  beforeEach(async () => {
    root = mkdtempSync(join(tmpdir(), "pi-v3route-test-"));
    dataDir = join(root, "data");
    mkdirSync(join(dataDir, "secrets"), { recursive: true });
    writeFileSync(join(dataDir, "secrets", "remote-hmac"), SECRET);
    // minimal release v9.9.9
    mkdirSync(join(root, "releases", "v9.9.9", "server"), { recursive: true });
    writeFileSync(join(root, "releases", "v9.9.9", "server", "pi-daemon.mjs"), "x");
    writeFileSync(join(root, "releases", "v9.9.9", "VERSION"), "v9.9.9");
    // bin scripts (existence only; never executed in these tests)
    mkdirSync(join(root, "bin"), { recursive: true });
    writeFileSync(join(root, "bin", "doctor.ps1"), "x");
    writeFileSync(join(root, "bin", "updater.ps1"), "x");
    writeJson("data/active-release.json", { schemaVersion: 1, version: "v9.9.9" });
    s = await boot(dataDir);
  });

  afterEach(async () => {
    await close(s);
    rmSync(root, { recursive: true, force: true });
  });

  it("GET /v1/doctor without report is 503", async () => {
    const r = await signed(s.port, "/v1/doctor", {});
    assert.equal(r.status, 503);
  });

  it("GET /v1/doctor returns cached report", async () => {
    writeJson("data/doctor-report.json", {
      schemaVersion: 1,
      timestamp: "t",
      status: "degraded",
      checks: [{ name: "x", ok: false, severity: "warning", detail: "d", recoverable: true }],
    });
    const r = await signed(s.port, "/v1/doctor", {});
    assert.equal(r.status, 200);
    const body = r.json["body"] as Record<string, unknown>;
    assert.equal(body["status"], "degraded");
    assert.equal((body["checks"] as unknown[]).length, 1);
  });

  it("GET /v1/doctor on pre-v3 layout is 501", async () => {
    const s2 = await boot();
    try {
      const r = await signed(s2.port, "/v1/doctor", {});
      assert.equal(r.status, 501);
      assert.equal(r.json["error"], "v3_unavailable");
    } finally {
      await close(s2);
      rmSync(s2.agentDir, { recursive: true, force: true });
    }
  });

  it("POST /v1/doctor validates body strictly", async () => {
    const malformed = await signed(s.port, "/v1/doctor", { method: "POST", body: "{{{" });
    assert.equal(malformed.status, 400);
    const onlyAlone = await signed(s.port, "/v1/doctor", {
      method: "POST",
      body: JSON.stringify({ only: ["tasks"] }),
    });
    assert.equal(onlyAlone.status, 400);
    assert.equal(onlyAlone.json["error"], "only_without_repair");
    const badTypes = await signed(s.port, "/v1/doctor", {
      method: "POST",
      body: JSON.stringify({ fresh: "yes" }),
    });
    assert.equal(badTypes.status, 400);
  });

  it("POST /v1/doctor repair with bad group never spawns", async () => {
    const r = await signed(s.port, "/v1/doctor", {
      method: "POST",
      body: JSON.stringify({ repair: true, only: ["tasks", "rm -rf"] }),
    });
    assert.equal(r.status, 500);
    assert.equal(r.json["error"], "bad_repair_group");
  });

  it("GET /v1/update returns pointer state", async () => {
    const r = await signed(s.port, "/v1/update", {});
    assert.equal(r.status, 200);
    const body = r.json["body"] as Record<string, unknown>;
    assert.equal(body["active"], "v9.9.9");
    assert.deepEqual(body["installed"], ["v9.9.9"]);
    assert.equal(body["pendingTransaction"], null);
  });

  it("POST /v1/update validates actions", async () => {
    const bad = await signed(s.port, "/v1/update", {
      method: "POST",
      body: JSON.stringify({ action: "reboot" }),
    });
    assert.equal(bad.status, 400);
    assert.equal(bad.json["error"], "bad_action");
    const planNoVer = await signed(s.port, "/v1/update", {
      method: "POST",
      body: JSON.stringify({ action: "plan" }),
    });
    assert.equal(planNoVer.status, 400);
    const verWithRollback = await signed(s.port, "/v1/update", {
      method: "POST",
      body: JSON.stringify({ action: "rollback", version: "v9.9.9" }),
    });
    assert.equal(verWithRollback.status, 400);
    assert.equal(verWithRollback.json["error"], "version_unexpected");
  });

  it("POST /v1/update plan reports risks honestly", async () => {
    const r = await signed(s.port, "/v1/update", {
      method: "POST",
      body: JSON.stringify({ action: "plan", version: "v9.9.9" }),
    });
    assert.equal(r.status, 200);
    const body = r.json["body"] as Record<string, unknown>;
    assert.equal(body["target"], "v9.9.9");
    assert.equal(body["noop"], true);
    assert.equal(body["candidatePresent"], true);
    assert.deepEqual(body["risks"], []);
  });

  it("POST /v1/update apply rejects bad version and pending tx", async () => {
    const bad = await signed(s.port, "/v1/update", {
      method: "POST",
      body: JSON.stringify({ action: "apply", version: "bogus" }),
    });
    assert.equal(bad.status, 400);
    writeJson("data/update-state.json", {
      schemaVersion: 1,
      transactionId: "tx-1",
      fromVersion: "v9.9.9",
      toVersion: "v9.9.10",
      phase: "health_verifying",
      previousVersion: "v9.9.9",
      startedAt: "t",
      updatedAt: "",
    });
    const pending = await signed(s.port, "/v1/update", {
      method: "POST",
      body: JSON.stringify({ action: "apply", version: "v9.9.10" }),
    });
    assert.equal(pending.status, 409);
    assert.equal(pending.json["error"], "transaction_pending");
  });

  it("POST /v1/update rollback without target is 409", async () => {
    const r = await signed(s.port, "/v1/update", {
      method: "POST",
      body: JSON.stringify({ action: "rollback" }),
    });
    assert.equal(r.status, 409);
    assert.equal(r.json["error"], "no_rollback_target");
  });

  it("POST /v1/update check returns shape (latest may be null offline)", async () => {
    const r = await signed(s.port, "/v1/update", {
      method: "POST",
      body: JSON.stringify({ action: "check", version: "v9.9.9" }),
    });
    assert.equal(r.status, 200);
    const body = r.json["body"] as Record<string, unknown>;
    assert.equal(body["active"], "v9.9.9");
    assert.equal(body["targetInstalled"], true);
    assert.ok("latest" in body && "updateAvailable" in body);
  });
});
