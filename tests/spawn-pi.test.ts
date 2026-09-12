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
import { buildPiSpawn, spawnPi, stopPi } from "../server/spawn-pi.mjs";

describe("buildPiSpawn routing", () => {
  it("win32 + .cmd routes through ComSpec with one verbatim tail", () => {
    const r = buildPiSpawn("C:\\npm\\pi.cmd", "win32");
    assert.match(r.command, /cmd\.exe$/i);
    assert.deepEqual(r.args, [
      "/d",
      "/s",
      "/c",
      '""C:\\npm\\pi.cmd" --mode rpc"',
    ]);
    assert.equal(r.windowsVerbatimArguments, true);
  });

  it("win32 + bare name still needs cmd (CreateProcess has no PATHEXT)", () => {
    const r = buildPiSpawn("pi", "win32");
    assert.match(r.command, /cmd\.exe$/i);
    assert.deepEqual(r.args, ["/d", "/s", "/c", '""pi" --mode rpc"']);
  });

  it("win32 + .exe spawns directly", () => {
    const r = buildPiSpawn("C:\\x\\pi.exe", "win32");
    assert.equal(r.command, "C:\\x\\pi.exe");
    assert.deepEqual(r.args, ["--mode", "rpc"]);
    assert.equal(r.windowsVerbatimArguments, false);
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
        reject(
          new Error(
            "spawn timed out (no output). stdout=" + out + " stderr=" + err,
          ),
        );
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
  it("executes a temp script and captures output", {
    timeout: 15000,
  }, async () => {
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
  });
});

describe("stopPi tree kill", () => {
  it("never throws on null/exited children", () => {
    assert.doesNotThrow(() => stopPi(null));
    assert.doesNotThrow(() => stopPi(undefined));
    assert.doesNotThrow(() =>
      stopPi({
        exitCode: 0,
      } as unknown as import("node:child_process").ChildProcess),
    );
  });

  it("kills a long-running child (and its subtree on win32)", {
    timeout: 20000,
  }, async () => {
    const dir = mkdtempSync(join(tmpdir(), "spawn-pi-kill-"));
    try {
      let target: string;
      if (process.platform === "win32") {
        // Grandchild ping.exe must die with the tree: if only cmd.exe
        // died, ping would hold stdout open and close would never fire.
        target = join(dir, "sleeper.cmd");
        writeFileSync(target, "@ping -n 20 127.0.0.1 >nul\r\n");
      } else {
        target = join(dir, "sleeper.sh");
        writeFileSync(target, "#!/bin/sh\nsleep 20\n");
        chmodSync(target, 0o755);
      }
      const child = spawnPi(target);
      await new Promise((r) => setTimeout(r, 1500));
      assert.equal(child.exitCode, null);
      stopPi(child, "SIGTERM");
      const code = await new Promise<number | null>((resolve) => {
        const t = setTimeout(() => resolve(424242), 12000);
        // NOTE: 'exit' (process gone), not 'close' (also waits for stdio
        // pipes inherited by grandchildren).
        child.on("exit", (c) => {
          clearTimeout(t);
          resolve(c);
        });
      });
      assert.notEqual(code, 424242, "child did not exit after stopPi");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
