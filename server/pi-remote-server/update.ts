/**
 * v0.3.0 pointer-based releases: pure helpers for the server_doctor and
 * server_update capabilities (daemon routes, Mac tools, ServerBot tools).
 *
 * Layout (Windows node):
 *   <root>\bin\            stable launchers + updater/doctor entry points
 *   <root>\releases\<ver>\ immutable code (one dir per version)
 *   <root>\data\           active-release.json, update-state.json,
 *                           update-history.jsonl, doctor-report.json,
 *                           runtime-env.json (machine facts)
 * where <root> = dirname(agentDir).
 *
 * Security: versions come ONLY from the allowlist regex; download URLs are
 * built from a fixed GitHub repo + validated version (never remote input);
 * process spawns use fixed argv (powershell -File on a bin\ script with an
 * enum action + regex version). No shell, no exec, no user-built commands.
 */
import { dirname, join } from "node:path";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { get } from "node:https";
import { sha256Hex } from "../../shared/protocol.ts";
import { readJsonFile } from "../../shared/store.ts";

export const RELEASE_VERSION_RX = /^v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/;
export const ACTIVE_POINTER_SCHEMA = 1;
export const DOCTOR_REPORT_SCHEMA = 1;
export const UPDATE_STATE_SCHEMA = 1;

export const GITHUB_OWNER = "patatapoderosa";
export const GITHUB_REPO = "mi-pi-server";
export const MAX_DOWNLOAD_BYTES = 50 * 1024 * 1024;
export const DOWNLOAD_TIMEOUT_MS = 120000;
export const LATEST_TIMEOUT_MS = 8000;

export const UPDATE_ACTIONS = [
  "check",
  "plan",
  "apply",
  "status",
  "rollback",
  "recover",
] as const;
export type UpdateAction = (typeof UPDATE_ACTIONS)[number];

export const REPAIR_GROUPS = [
  "tasks",
  "orphans",
  "listener",
  "transaction",
  "taskdefs",
  "runtime_env",
] as const;
export type RepairGroup = (typeof REPAIR_GROUPS)[number];

/** Strict version gate shared with the PS engine (Test-ReleaseVersionFormat). */
export function isReleaseVersion(v: unknown): v is string {
  return typeof v === "string" && RELEASE_VERSION_RX.test(v);
}

export function isUpdateAction(v: unknown): v is UpdateAction {
  return (
    typeof v === "string" &&
    (UPDATE_ACTIONS as readonly string[]).includes(v)
  );
}

export function isRepairGroup(v: unknown): v is RepairGroup {
  return (
    typeof v === "string" && (REPAIR_GROUPS as readonly string[]).includes(v)
  );
}

/** PiServer root = parent of the agent (data) dir. */
export function piServerRoot(agentDir: string): string {
  return dirname(agentDir);
}

export interface ActivePointer {
  ok: boolean;
  version: string;
  error: string;
}

/** Read + validate data\active-release.json. Never throws. */
export function readActivePointer(root: string): ActivePointer {
  try {
    const raw = readJsonFile<Record<string, unknown>>(
      join(root, "data", "active-release.json"),
      {},
    );
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      return { ok: false, version: "", error: "pointer_not_object" };
    }
    if (raw["schemaVersion"] !== ACTIVE_POINTER_SCHEMA) {
      return { ok: false, version: "", error: "pointer_bad_schema" };
    }
    const ver = raw["version"];
    if (!isReleaseVersion(ver)) {
      return { ok: false, version: "", error: "pointer_bad_version" };
    }
    return { ok: true, version: ver, error: "" };
  } catch {
    return { ok: false, version: "", error: "pointer_unreadable" };
  }
}

function isDirectChild(releasesDir: string, candidate: string): boolean {
  try {
    const base = releasesDir.endsWith("/")
      ? releasesDir
      : releasesDir + "/";
    if (!candidate.startsWith(base)) return false;
    const rest = candidate.slice(base.length);
    if (rest === "" || rest.includes("/") || rest.includes("\\")) return false;
    return true;
  } catch {
    return false;
  }
}

export interface ReleaseResolve {
  ok: boolean;
  dir: string;
  error: string;
}

/**
 * Resolve a pointer version to releases\<ver> with canonical child check.
 * Never throws. Mirrors Resolve-ReleaseDir (PS).
 */
export function resolveReleaseDir(
  root: string,
  version: string,
): ReleaseResolve {
  if (!isReleaseVersion(version)) {
    return { ok: false, dir: "", error: "bad_version" };
  }
  try {
    const releases = join(root, "releases");
    const dir = join(releases, version);
    if (!isDirectChild(releases, dir)) {
      return { ok: false, dir: "", error: "traversal_rejected" };
    }
    let st = null;
    try {
      st = statSync(dir);
    } catch {
      return { ok: false, dir: "", error: "release_missing" };
    }
    if (!st.isDirectory()) {
      return { ok: false, dir: "", error: "release_missing" };
    }
    if (!existsSync(join(dir, "server", "pi-daemon.mjs"))) {
      return { ok: false, dir: "", error: "release_minimal_manifest" };
    }
    return { ok: true, dir, error: "" };
  } catch {
    return { ok: false, dir: "", error: "resolve_failed" };
  }
}

/** Installed releases (version dirs with minimal manifest), sorted. Never throws. */
export function listInstalledReleases(root: string): string[] {
  try {
    const releases = join(root, "releases");
    const names = readdirSync(releases, { withFileTypes: true });
    const out: string[] = [];
    for (const e of names) {
      if (!e.isDirectory()) continue;
      if (!isReleaseVersion(e.name)) continue;
      if (!existsSync(join(releases, e.name, "server", "pi-daemon.mjs"))) {
        continue;
      }
      out.push(e.name);
    }
    return out.sort();
  } catch {
    return [];
  }
}

export type UpdatePhase =
  | "preflight"
  | "downloaded"
  | "candidate_validated"
  | "candidate_installed"
  | "runtime_stopped"
  | "pointer_switched"
  | "runtime_started"
  | "health_verifying"
  | "completed"
  | "failed"
  | "rollback_started"
  | "rollback_completed";

const TERMINAL_PHASES: readonly string[] = [
  "completed",
  "failed",
  "rollback_completed",
];

export interface UpdateState {
  found: boolean;
  corrupt: boolean;
  transactionId: string;
  fromVersion: string;
  toVersion: string;
  phase: string;
  previousVersion: string;
  error: string;
}

/** Read data\update-state.json. Never throws. */
export function readUpdateState(root: string): UpdateState {
  const blank: UpdateState = {
    found: false,
    corrupt: false,
    transactionId: "",
    fromVersion: "",
    toVersion: "",
    phase: "",
    previousVersion: "",
    error: "",
  };
  try {
    const p = join(root, "data", "update-state.json");
    if (!existsSync(p)) return blank;
    const raw = readJsonFile<Record<string, unknown>>(p, {});
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      return { ...blank, found: true, corrupt: true, error: "state_not_object" };
    }
    if (raw["schemaVersion"] !== UPDATE_STATE_SCHEMA) {
      return { ...blank, found: true, corrupt: true, error: "state_bad_schema" };
    }
    const tx = raw["transactionId"];
    const from = raw["fromVersion"];
    const to = raw["toVersion"];
    const phase = raw["phase"];
    const prev = raw["previousVersion"];
    if (
      typeof tx !== "string" ||
      tx.length === 0 ||
      !isReleaseVersion(from) ||
      !isReleaseVersion(to) ||
      typeof phase !== "string" ||
      !isKnownPhase(phase)
    ) {
      return { ...blank, found: true, corrupt: true, error: "state_bad_fields" };
    }
    if (prev !== undefined && prev !== "" && !isReleaseVersion(prev)) {
      return { ...blank, found: true, corrupt: true, error: "state_bad_previous" };
    }
    return {
      found: true,
      corrupt: false,
      transactionId: tx,
      fromVersion: from as string,
      toVersion: to as string,
      phase: phase as string,
      previousVersion: typeof prev === "string" ? prev : "",
      error: "",
    };
  } catch {
    return { ...blank, found: true, corrupt: true, error: "state_unreadable" };
  }
}

export function isTerminalPhase(phase: string): boolean {
  return TERMINAL_PHASES.includes(phase);
}

const KNOWN_PHASES: readonly string[] = [
  "preflight",
  "downloaded",
  "candidate_validated",
  "candidate_installed",
  "runtime_stopped",
  "pointer_switched",
  "runtime_started",
  "health_verifying",
  "completed",
  "failed",
  "rollback_started",
  "rollback_completed",
];

export function isKnownPhase(phase: string): boolean {
  return KNOWN_PHASES.includes(phase);
}

export interface HistoryEntry {
  timestamp: string;
  transactionId: string;
  fromVersion: string;
  toVersion: string;
  result: string;
  rollback: boolean;
}

/** Tail of data\update-history.jsonl (no secrets by construction). Never throws. */
export function readHistoryTail(root: string, n: number): HistoryEntry[] {
  try {
    const p = join(root, "data", "update-history.jsonl");
    if (!existsSync(p)) return [];
    const text = readFileSync(p, "utf8");
    const lines = text
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l.length > 0);
    const tail = lines.slice(Math.max(0, lines.length - Math.max(1, n)));
    const out: HistoryEntry[] = [];
    for (const line of tail) {
      try {
        const o = JSON.parse(line) as Record<string, unknown>;
        out.push({
          timestamp: typeof o["timestamp"] === "string" ? o["timestamp"] : "",
          transactionId:
            typeof o["transactionId"] === "string" ? o["transactionId"] : "",
          fromVersion:
            typeof o["fromVersion"] === "string" ? o["fromVersion"] : "",
          toVersion: typeof o["toVersion"] === "string" ? o["toVersion"] : "",
          result: typeof o["result"] === "string" ? o["result"] : "",
          rollback: o["rollback"] === true,
        });
      } catch {
        // skip corrupt lines, keep the rest
      }
    }
    return out;
  } catch {
    return [];
  }
}

export interface DoctorCheck {
  name: string;
  ok: boolean;
  severity: string;
  detail: string;
  recoverable: boolean;
}

export interface DoctorReport {
  ok: boolean;
  status: string;
  timestamp: string;
  checks: DoctorCheck[];
  error: string;
}

/** Validate a cached doctor report shape (never trust content blindly). Never throws. */
export function validateDoctorReport(v: unknown): v is {
  schemaVersion: number;
  status: string;
  checks: unknown[];
} {
  if (typeof v !== "object" || v === null || Array.isArray(v)) return false;
  const o = v as Record<string, unknown>;
  if (o["schemaVersion"] !== DOCTOR_REPORT_SCHEMA) return false;
  if (
    o["status"] !== "healthy" &&
    o["status"] !== "degraded" &&
    o["status"] !== "unhealthy"
  ) {
    return false;
  }
  if (!Array.isArray(o["checks"])) return false;
  return true;
}

/** Read cached data\doctor-report.json. Never throws. */
export function readDoctorReport(root: string): DoctorReport {
  try {
    const p = join(root, "data", "doctor-report.json");
    if (!existsSync(p)) {
      return { ok: false, status: "", timestamp: "", checks: [], error: "report_missing" };
    }
    const raw = readJsonFile<unknown>(p, null);
    if (!validateDoctorReport(raw)) {
      return { ok: false, status: "", timestamp: "", checks: [], error: "report_invalid" };
    }
    const checks: DoctorCheck[] = [];
    for (const c of raw.checks) {
      if (typeof c !== "object" || c === null) continue;
      const co = c as Record<string, unknown>;
      checks.push({
        name: typeof co["name"] === "string" ? co["name"] : "unknown",
        ok: co["ok"] === true,
        severity: typeof co["severity"] === "string" ? co["severity"] : "info",
        detail: typeof co["detail"] === "string" ? co["detail"] : "",
        recoverable: co["recoverable"] === true,
      });
    }
    const r = raw as { status: string; timestamp?: unknown };
    return {
      ok: true,
      status: r.status,
      timestamp: typeof r.timestamp === "string" ? r.timestamp : "",
      checks,
      error: "",
    };
  } catch {
    return { ok: false, status: "", timestamp: "", checks: [], error: "report_unreadable" };
  }
}

/** Fixed GitHub release artifact URLs for a validated version. Never throws. */
export function releaseArtifactUrls(version: string): {
  ok: boolean;
  zip: string;
  sums: string;
  error: string;
} {
  if (!isReleaseVersion(version)) {
    return { ok: false, zip: "", sums: "", error: "bad_version" };
  }
  const base = `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${version}`;
  return {
    ok: true,
    zip: `${base}/mi-pi-server-windows.zip`,
    sums: `${base}/SHA256SUMS.txt`,
    error: "",
  };
}

export type FetchImpl = (
  url: string,
  opts: { timeoutMs: number; maxBytes: number },
) => Promise<{ ok: boolean; status: number; body: Buffer; error: string }>;

function defaultFetch(
  url: string,
  opts: { timeoutMs: number; maxBytes: number },
): Promise<{ ok: boolean; status: number; body: Buffer; error: string }> {
  return new Promise((resolve) => {
    let done = false;
    const finish = (r: {
      ok: boolean;
      status: number;
      body: Buffer;
      error: string;
    }) => {
      if (!done) {
        done = true;
        resolve(r);
      }
    };
    try {
      const req = get(
        url,
        { timeout: opts.timeoutMs },
        (res) => {
          const status = res.statusCode ?? 0;
          if (status < 200 || status >= 300) {
            res.resume();
            finish({ ok: false, status, body: Buffer.alloc(0), error: `http_${status}` });
            return;
          }
          const chunks: Buffer[] = [];
          let size = 0;
          res.on("data", (c: Buffer) => {
            size += c.length;
            if (size > opts.maxBytes) {
              try {
                req.destroy();
              } catch {
                // ignore
              }
              finish({ ok: false, status, body: Buffer.alloc(0), error: "too_large" });
              return;
            }
            chunks.push(c);
          });
          res.on("end", () => {
            finish({ ok: true, status, body: Buffer.concat(chunks), error: "" });
          });
          res.on("error", (e: Error) => {
            finish({ ok: false, status, body: Buffer.alloc(0), error: e.message });
          });
        },
      );
      req.on("timeout", () => {
        try {
          req.destroy();
        } catch {
          // ignore
        }
        finish({ ok: false, status: 0, body: Buffer.alloc(0), error: "timeout" });
      });
      req.on("error", (e: Error) => {
        finish({ ok: false, status: 0, body: Buffer.alloc(0), error: e.message });
      });
    } catch (e) {
      finish({
        ok: false,
        status: 0,
        body: Buffer.alloc(0),
        error: e instanceof Error ? e.message : "fetch_failed",
      });
    }
  });
}

/**
 * Download a release ZIP + verify against its SHA256SUMS (same trust model
 * as the installer: both artifacts from the fixed GitHub release).
 * Never throws. No network in unit tests: inject fetchImpl.
 */
export async function downloadRelease(
  version: string,
  destZip: string,
  fetchImpl: FetchImpl = defaultFetch,
): Promise<{ ok: boolean; bytes: number; error: string }> {
  const urls = releaseArtifactUrls(version);
  if (!urls.ok) return { ok: false, bytes: 0, error: urls.error };
  try {
    const { writeFileSync } = await import("node:fs");
    const zipRes = await fetchImpl(urls.zip, {
      timeoutMs: DOWNLOAD_TIMEOUT_MS,
      maxBytes: MAX_DOWNLOAD_BYTES,
    });
    if (!zipRes.ok) {
      return { ok: false, bytes: 0, error: `zip_${zipRes.error}` };
    }
    const sumsRes = await fetchImpl(urls.sums, {
      timeoutMs: DOWNLOAD_TIMEOUT_MS,
      maxBytes: 65536,
    });
    if (!sumsRes.ok) {
      return { ok: false, bytes: 0, error: `sums_${sumsRes.error}` };
    }
    const sumsText = sumsRes.body.toString("utf8");
    const m = sumsText.match(/^([0-9a-fA-F]{64})\s+mi-pi-server-windows\.zip/m);
    if (!m) return { ok: false, bytes: 0, error: "sums_unparseable" };
    const actual = sha256Hex(zipRes.body);
    if (actual.toLowerCase() !== m[1].toLowerCase()) {
      return { ok: false, bytes: 0, error: "checksum_mismatch" };
    }
    writeFileSync(destZip, zipRes.body);
    return { ok: true, bytes: zipRes.body.length, error: "" };
  } catch (e) {
    return {
      ok: false,
      bytes: 0,
      error: e instanceof Error ? e.message : "download_failed",
    };
  }
}

/** Query the fixed GitHub latest-release endpoint (graceful offline). Never throws. */
export async function checkLatestRelease(
  fetchImpl: FetchImpl = defaultFetch,
): Promise<{ ok: boolean; tag: string; error: string }> {
  try {
    const url = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest`;
    const res = await fetchImpl(url, {
      timeoutMs: LATEST_TIMEOUT_MS,
      maxBytes: 65536,
    });
    if (!res.ok) return { ok: false, tag: "", error: res.error };
    const o = JSON.parse(res.body.toString("utf8")) as Record<string, unknown>;
    const tag = o["tag_name"];
    if (!isReleaseVersion(tag)) {
      return { ok: false, tag: "", error: "latest_not_a_release" };
    }
    return { ok: true, tag, error: "" };
  } catch (e) {
    return {
      ok: false,
      tag: "",
      error: e instanceof Error ? e.message : "latest_failed",
    };
  }
}

export interface SpawnSpec {
  ok: boolean;
  command: string;
  args: string[];
  error: string;
}

/**
 * Fixed argv for bin\doctor.ps1 (Windows only). `only` is validated against
 * the repair-group allowlist; each group becomes a separate argv element
 * (never a joined shell string). Never throws.
 */
export function buildDoctorArgv(
  root: string,
  repair: boolean,
  only: unknown,
  platform: string = process.platform,
): SpawnSpec {
  const groups: string[] = [];
  if (repair) {
    if (only !== undefined && only !== null) {
      if (!Array.isArray(only)) {
        return { ok: false, command: "", args: [], error: "bad_repair_group" };
      }
      for (const g of only) {
        if (!isRepairGroup(g)) {
          return { ok: false, command: "", args: [], error: "bad_repair_group" };
        }
        groups.push(g);
      }
    }
  } else if (only !== undefined && only !== null) {
    return { ok: false, command: "", args: [], error: "bad_repair_group" };
  }
  if (platform !== "win32") {
    return { ok: false, command: "", args: [], error: "unsupported_platform" };
  }
  const script = join(root, "bin", "doctor.ps1");
  if (!existsSync(script)) {
    return { ok: false, command: "", args: [], error: "doctor_missing" };
  }
  const args = [
    "-NoProfile",
    "-NonInteractive",
    "-File",
    script,
    "-Json",
  ];
  if (repair) {
    args.push("-Repair");
    if (groups.length > 0) {
      args.push("-Only");
      for (const g of groups) args.push(g);
    }
  }
  return { ok: true, command: "powershell.exe", args, error: "" };
}

/**
 * Fixed argv for bin\updater.ps1 actions (Windows only). Version is regex
 * validated; stagingDir/zipPath must be absolute paths under temp/root
 * (caller enforced). Never throws.
 */
export function buildUpdaterArgv(
  root: string,
  action: string,
  version: string,
  extra: { stagingDir?: string; zipPath?: string },
  platform: string = process.platform,
): SpawnSpec {
  if (action !== "update" && action !== "rollback" && action !== "recover") {
    return { ok: false, command: "", args: [], error: "bad_action" };
  }
  if (action === "update") {
    if (!isReleaseVersion(version)) {
      return { ok: false, command: "", args: [], error: "bad_version" };
    }
    const staging = extra.stagingDir ?? "";
    const zip = extra.zipPath ?? "";
    if (staging !== "" && zip !== "") {
      return { ok: false, command: "", args: [], error: "staging_or_zip" };
    }
    if (staging === "" && zip === "") {
      return { ok: false, command: "", args: [], error: "no_payload" };
    }
  }
  if (platform !== "win32") {
    return { ok: false, command: "", args: [], error: "unsupported_platform" };
  }
  const script = join(root, "bin", "updater.ps1");
  if (!existsSync(script)) {
    return { ok: false, command: "", args: [], error: "updater_missing" };
  }
  const args = [
    "-NoProfile",
    "-NonInteractive",
    "-File",
    script,
    "-Action",
    action,
  ];
  if (action === "update") {
    args.push("-Version", version);
    const staging = extra.stagingDir ?? "";
    const zip = extra.zipPath ?? "";
    if (staging === "") args.push("-ZipPath", zip); else args.push("-StagingDir", staging);
  }
  return { ok: true, command: "powershell.exe", args, error: "" };
}

/** v3 availability probe: pointer flow exists when bin\ + data\ exist. Never throws. */
export function v3Available(root: string): boolean {
  try {
    return (
      existsSync(join(root, "bin", "updater.ps1")) &&
      existsSync(join(root, "bin", "doctor.ps1")) &&
      existsSync(join(root, "data"))
    );
  } catch {
    return false;
  }
}
