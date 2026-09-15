/**
 * Unit tests for server/pi-remote-server/update.ts (pure helpers, no network,
 * no spawn). Route-level tests live in tests/remote-server.test.ts.
 * Run: npm test (node --test tests/)
 */
import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import {
  buildDoctorArgv,
  buildUpdaterArgv,
  checkLatestRelease,
  downloadRelease,
  isKnownPhase,
  isReleaseVersion,
  isRepairGroup,
  isTerminalPhase,
  isUpdateAction,
  listInstalledReleases,
  readActivePointer,
  readDoctorReport,
  readHistoryTail,
  readUpdateState,
  releaseArtifactUrls,
  resolveReleaseDir,
  v3Available,
  type FetchImpl,
} from "../server/pi-remote-server/update.ts";

let root = "";
let dataDir = "";

function freshRoot(): string {
  root = mkdtempSync(join(tmpdir(), "pi-update-test-"));
  dataDir = join(root, "data");
  mkdirSync(dataDir, { recursive: true });
  return root;
}

function writeJson(rel: string, v: unknown): void {
  const fp = join(root, rel);
  mkdirSync(join(fp, ".."), { recursive: true });
  writeFileSync(fp, JSON.stringify(v));
}

function makeRelease(ver: string): void {
  const d = join(root, "releases", ver);
  mkdirSync(join(d, "server"), { recursive: true });
  writeFileSync(join(d, "server", "pi-daemon.mjs"), "x");
  writeFileSync(join(d, "VERSION"), ver);
}

beforeEach(() => {
  freshRoot();
});

afterEach(() => {
  if (root !== "") rmSync(root, { recursive: true, force: true });
  root = "";
});

describe("isReleaseVersion", () => {
  it("accepts vX.Y.Z and prerelease", () => {
    assert.equal(isReleaseVersion("v0.3.0"), true);
    assert.equal(isReleaseVersion("v10.20.30-rc.1"), true);
  });
  it("rejects traversal, drive, UNC, empty", () => {
    assert.equal(isReleaseVersion("../../foo"), false);
    assert.equal(isReleaseVersion("C:\\x\\v0.3.0"), false);
    assert.equal(isReleaseVersion("\\\\srv\\v0.3.0"), false);
    assert.equal(isReleaseVersion("0.3.0"), false);
    assert.equal(isReleaseVersion(""), false);
    assert.equal(isReleaseVersion(null), false);
  });
});

describe("readActivePointer", () => {
  it("missing file fails closed", () => {
    const r = readActivePointer(root);
    assert.equal(r.ok, false);
  });
  it("round-trips a valid pointer", () => {
    writeJson("data/active-release.json", { schemaVersion: 1, version: "v0.3.0" });
    const r = readActivePointer(root);
    assert.equal(r.ok, true);
    assert.equal(r.version, "v0.3.0");
  });
  it("rejects corrupt, bad schema, bad version", () => {
    writeFileSync(join(dataDir, "active-release.json"), "not-json{{{");
    assert.equal(readActivePointer(root).ok, false);
    writeJson("data/active-release.json", { schemaVersion: 99, version: "v0.3.0" });
    assert.equal(readActivePointer(root).error, "pointer_bad_schema");
    writeJson("data/active-release.json", { schemaVersion: 1, version: "../../evil" });
    assert.equal(readActivePointer(root).error, "pointer_bad_version");
  });
});

describe("resolveReleaseDir", () => {
  it("resolves a valid release", () => {
    makeRelease("v0.3.0");
    const r = resolveReleaseDir(root, "v0.3.0");
    assert.equal(r.ok, true);
    assert.equal(r.dir, join(root, "releases", "v0.3.0"));
  });
  it("rejects missing release and bad versions", () => {
    assert.equal(resolveReleaseDir(root, "v9.9.9").error, "release_missing");
    assert.equal(resolveReleaseDir(root, "../../x").error, "bad_version");
  });
  it("rejects format-passing traversal suffix", () => {
    assert.equal(isReleaseVersion("v1.2.3-.."), true);
    assert.equal(resolveReleaseDir(root, "v1.2.3-..").ok, false);
  });
  it("rejects release without daemon", () => {
    mkdirSync(join(root, "releases", "v0.3.1"), { recursive: true });
    assert.equal(resolveReleaseDir(root, "v0.3.1").error, "release_minimal_manifest");
  });
});

describe("listInstalledReleases", () => {
  it("lists, sorts, filters", () => {
    makeRelease("v0.3.1");
    makeRelease("v0.3.0");
    mkdirSync(join(root, "releases", "junk"), { recursive: true });
    mkdirSync(join(root, "releases", "v0.3.2"), { recursive: true });
    assert.deepEqual(listInstalledReleases(root), ["v0.3.0", "v0.3.1"]);
  });
  it("empty when absent", () => {
    assert.deepEqual(listInstalledReleases(root), []);
  });
});

describe("readUpdateState", () => {
  it("missing means no transaction", () => {
    const s = readUpdateState(root);
    assert.equal(s.found, false);
    assert.equal(s.corrupt, false);
  });
  it("reads a valid state", () => {
    writeJson("data/update-state.json", {
      schemaVersion: 1,
      transactionId: "tx-1",
      fromVersion: "v0.3.0",
      toVersion: "v0.3.1",
      phase: "health_verifying",
      previousVersion: "v0.3.0",
      startedAt: "t",
      updatedAt: "",
    });
    const s = readUpdateState(root);
    assert.equal(s.found, true);
    assert.equal(s.corrupt, false);
    assert.equal(s.phase, "health_verifying");
  });
  it("unknown phase is corrupt", () => {
    writeJson("data/update-state.json", {
      schemaVersion: 1,
      transactionId: "tx-1",
      fromVersion: "v0.3.0",
      toVersion: "v0.3.1",
      phase: "flying",
      previousVersion: "v0.3.0",
      startedAt: "t",
      updatedAt: "",
    });
    const s = readUpdateState(root);
    assert.equal(s.corrupt, true);
  });
  it("phase helpers", () => {
    assert.equal(isKnownPhase("pointer_switched"), true);
    assert.equal(isKnownPhase("flying"), false);
    assert.equal(isTerminalPhase("completed"), true);
    assert.equal(isTerminalPhase("health_verifying"), false);
  });
});

describe("readHistoryTail", () => {
  it("tails entries and skips corrupt lines", () => {
    const lines = [
      JSON.stringify({ timestamp: "t1", transactionId: "a", fromVersion: "v0.3.0", toVersion: "v0.3.1", result: "completed", rollback: false }),
      "garbage{{{",
      JSON.stringify({ timestamp: "t2", transactionId: "b", fromVersion: "v0.3.1", toVersion: "v0.3.2", result: "update_failed_rollback_healthy", rollback: true }),
    ].join("\n");
    writeFileSync(join(dataDir, "update-history.jsonl"), lines);
    const tail = readHistoryTail(root, 5);
    assert.equal(tail.length, 2);
    assert.equal(tail[1].result, "update_failed_rollback_healthy");
    assert.equal(tail[1].rollback, true);
    assert.equal(readHistoryTail(root, 1).length, 1);
  });
  it("missing file is empty", () => {
    assert.deepEqual(readHistoryTail(root, 5), []);
  });
});

describe("readDoctorReport", () => {
  it("reads a valid report", () => {
    writeJson("data/doctor-report.json", {
      schemaVersion: 1,
      timestamp: "t",
      status: "degraded",
      checks: [{ name: "x", ok: false, severity: "warning", detail: "d", recoverable: true }],
    });
    const r = readDoctorReport(root);
    assert.equal(r.ok, true);
    assert.equal(r.status, "degraded");
    assert.equal(r.checks.length, 1);
  });
  it("rejects missing and invalid", () => {
    assert.equal(readDoctorReport(root).error, "report_missing");
    writeJson("data/doctor-report.json", { schemaVersion: 1, status: "bogus", checks: [] });
    assert.equal(readDoctorReport(root).error, "report_invalid");
  });
});

describe("releaseArtifactUrls", () => {
  it("builds fixed github urls", () => {
    const u = releaseArtifactUrls("v0.3.0");
    assert.equal(u.ok, true);
    assert.equal(u.zip, "https://github.com/patatapoderosa/mi-pi-server/releases/download/v0.3.0/mi-pi-server-windows.zip");
    assert.equal(u.sums, "https://github.com/patatapoderosa/mi-pi-server/releases/download/v0.3.0/SHA256SUMS.txt");
  });
  it("rejects bad versions", () => {
    assert.equal(releaseArtifactUrls("../../x").error, "bad_version");
  });
});

describe("downloadRelease (fake fetch, no network)", () => {
  const zipBytes = Buffer.from("fake-zip-bytes");
  const goodHash = createHash("sha256").update(zipBytes).digest("hex");
  const fakeFetch: FetchImpl = async (url) => {
    if (url.endsWith(".zip")) return { ok: true, status: 200, body: zipBytes, error: "" };
    return { ok: true, status: 200, body: Buffer.from(`${goodHash}  mi-pi-server-windows.zip\n`), error: "" };
  };
  it("verifies and writes", async () => {
    const dest = join(root, "rel.zip");
    const r = await downloadRelease("v0.3.0", dest, fakeFetch);
    assert.equal(r.ok, true);
    assert.equal(r.bytes, zipBytes.length);
  });
  it("checksum mismatch fails closed", async () => {
    const bad: FetchImpl = async (url) => {
      if (url.endsWith(".zip")) return { ok: true, status: 200, body: Buffer.from("tampered"), error: "" };
      return { ok: true, status: 200, body: Buffer.from(`${goodHash}  mi-pi-server-windows.zip\n`), error: "" };
    };
    const r = await downloadRelease("v0.3.0", join(root, "x.zip"), bad);
    assert.equal(r.error, "checksum_mismatch");
  });
  it("unparseable sums and zip errors", async () => {
    const badSums: FetchImpl = async (url) => {
      if (url.endsWith(".zip")) return { ok: true, status: 200, body: zipBytes, error: "" };
      return { ok: true, status: 200, body: Buffer.from("nonsense"), error: "" };
    };
    assert.equal((await downloadRelease("v0.3.0", join(root, "a.zip"), badSums)).error, "sums_unparseable");
    const zipFail: FetchImpl = async () => ({ ok: false, status: 404, body: Buffer.alloc(0), error: "http_404" });
    assert.equal((await downloadRelease("v0.3.0", join(root, "b.zip"), zipFail)).error, "zip_http_404");
    assert.equal((await downloadRelease("bogus", join(root, "c.zip"), fakeFetch)).error, "bad_version");
  });
});

describe("checkLatestRelease (fake fetch)", () => {
  it("returns validated tag", async () => {
    const f: FetchImpl = async () => ({
      ok: true, status: 200,
      body: Buffer.from(JSON.stringify({ tag_name: "v0.3.1" })), error: "",
    });
    const r = await checkLatestRelease(f);
    assert.equal(r.ok, true);
    assert.equal(r.tag, "v0.3.1");
  });
  it("rejects non-release tags and failures", async () => {
    const bad: FetchImpl = async () => ({
      ok: true, status: 200, body: Buffer.from(JSON.stringify({ tag_name: "nightly" })), error: "",
    });
    assert.equal((await checkLatestRelease(bad)).error, "latest_not_a_release");
    const down: FetchImpl = async () => ({ ok: false, status: 0, body: Buffer.alloc(0), error: "timeout" });
    assert.equal((await checkLatestRelease(down)).error, "timeout");
  });
});

describe("spawn spec builders", () => {
  function makeBin(): string {
    const bin = join(root, "bin");
    mkdirSync(bin, { recursive: true });
    writeFileSync(join(bin, "doctor.ps1"), "x");
    writeFileSync(join(bin, "updater.ps1"), "x");
    return root;
  }
  it("doctor argv: fixed form, groups validated", () => {
    makeBin();
    const s = buildDoctorArgv(root, true, ["tasks", "orphans"], "win32");
    assert.equal(s.ok, true);
    assert.equal(s.command, "powershell.exe");
    assert.deepEqual(s.args.slice(0, 5), ["-NoProfile", "-NonInteractive", "-File", join(root, "bin", "doctor.ps1"), "-Json"]);
    assert.ok(s.args.includes("-Repair") && s.args.includes("-Only") && s.args.includes("tasks"));
    const bad = buildDoctorArgv(root, true, ["rm -rf"], "win32");
    assert.equal(bad.error, "bad_repair_group");
    const plat = buildDoctorArgv(root, false, null, "darwin");
    assert.equal(plat.error, "unsupported_platform");
    const miss = buildDoctorArgv(join(root, "nope"), false, null, "win32");
    assert.equal(miss.error, "doctor_missing");
  });
  it("updater argv: actions and versions validated", () => {
    makeBin();
    const u = buildUpdaterArgv(root, "update", "v0.3.0", { zipPath: "C:\\t\\r.zip" }, "win32");
    assert.equal(u.ok, true);
    assert.ok(u.args.includes("-Version") && u.args.includes("v0.3.0") && u.args.includes("-ZipPath"));
    assert.equal(buildUpdaterArgv(root, "update", "bogus", {}, "win32").error, "bad_version");
    assert.equal(buildUpdaterArgv(root, "update", "v0.3.0", {}, "win32").error, "no_payload");
    assert.equal(buildUpdaterArgv(root, "update", "v0.3.0", { stagingDir: "a", zipPath: "b" }, "win32").error, "staging_or_zip");
    assert.equal(buildUpdaterArgv(root, "rollback", "", {}, "win32").ok, true);
    assert.equal(buildUpdaterArgv(root, "reboot", "", {}, "win32").error, "bad_action");
    assert.equal(buildUpdaterArgv(root, "recover", "", {}, "darwin").error, "unsupported_platform");
  });
  it("action/repair group guards", () => {
    assert.equal(isUpdateAction("apply"), true);
    assert.equal(isUpdateAction("rm"), false);
    assert.equal(isRepairGroup("tasks"), true);
    assert.equal(isRepairGroup("sudo"), false);
  });
});

describe("v3Available", () => {
  it("needs bin scripts + data dir", () => {
    assert.equal(v3Available(root), false);
    mkdirSync(join(root, "bin"), { recursive: true });
    writeFileSync(join(root, "bin", "updater.ps1"), "x");
    writeFileSync(join(root, "bin", "doctor.ps1"), "x");
    assert.equal(v3Available(root), true);
  });
});
