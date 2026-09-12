/**
 * pi-daemon spawn tests: Windows-correct .cmd execution (Bug: bare
 * child_process.spawn of npm's pi.cmd fails with ENOENT on win32 because
 * CreateProcess has no PATHEXT handling — cmd.exe /d /s /c is required).
 * Run: npm test  (node --test tests/)
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildPiSpawn, spawnPi } from "../server/spawn-pi.mjs";

describe("buildPiSpawn routing", () => {
  it("win32 + .cmd routes through ComSpec with fixed args only", () => {
    const r = buildPiSpawn("C:\\npm\\pi.cmd", "win32");
    assert.match(r.command, /cmd\.exe$/i);
    assert.deepEqual(r.args, [
      "/d",
      "/s",
      "/c",
      '"C:\\npm\\pi.cmd"',
      "--mode",
      "rpc",
    ]);
  });

  it("win32 + bare name still needs cmd (CreateProcess has no PATHEXT)", () => {
    const r = buildPiSpawn("pi", "win32");
    assert.match(r.command, /cmd\.exe$/i);
    assert.ok(r.args.includes('"pi"'));
  });

  it("win32 + .exe spawns directly", () => {
    const r = buildPiSpawn("C:\\x\\pi.exe", "win32");
    assert.equal(r.command, "C:\\x\\pi.exe");
    assert.deepEqual(r.args, ["--mode", "rpc"]);
  });

  it("posix spawns directly", () => {
    const r = buildPiSpawn("/usr/local/bin/pi", "linux");
    assert.equal(r.command, "/usr/local/bin/pi");
    assert.deepEqual(r.args, ["--mode", "rpc"]);
  });

  it("empty falls back to 'pi'", () => {
    const r = buildPiSpawn("", "linux");
    assert.equal(r.command, "pi");
  });
});

function runAndCapture(
  target: string,
  timeoutMs = 10000,
): Promise<{ out: string; err: string; code: number | null }> {
  return new Promise((resolve, reject) => {
    let out = "";
    let err = "";
    let done = false;
    const child = spawnPi(target);
    const timer = setTimeout(() => {
      if (!done) {
        done = true;
        try {
          child.kill();
        } catch {
          /* already exited */
        }
        reject(new Error("spawn timed out (no output). stdout=" + out + " stderr=" + err));
      }
    }, timeoutMs);
    child.stdout?.on("data", (d: unknown) => {
      out += String(d);
    });
    child.stderr?.on("data", (d: unknown) => {
      err += String(d);
    });
    child.on("error", (e: Error) => {
      if (!done) {
        done = true;
        clearTimeout(timer);
        reject(e);
      }
    });
    child.on("close", (code: number | null) => {
      if (!done) {
        done = true;
        clearTimeout(timer);
        resolve({ out, err, code });
      }
    });
  });
}

describe("spawnPi real execution (production path)", () => {
  it(
    "executes a temp script and captures output",
    { timeout: 15000 },
    async () => {
      const dir = mkdtempSync(join(tmpdir(), "spawn-pi-test-"));
      try {
        const marker = "SPAWN-OK-987654321";
        let target: string;
        if (process.platform === "win32") {
          target = join(dir, "fake-pi.cmd");
          writeFileSync(target, `@echo ${marker}\r\n`);
        } else {
          target = join(dir, "fake-pi.sh");
          writeFileSync(target, `#!/bin/sh\necho ${marker}\n`);
          chmodSync(target, 0o755);
        }
        const got = await runAndCapture(target);
        assert.match(
          got.out,
          new RegExp(marker),
          "exit=" + got.code + " stderr=" + got.err,
        );
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    },
  );
});
