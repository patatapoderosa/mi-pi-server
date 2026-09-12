/**
 * pi-remote-server: tiny authenticated HTTP API for Mac -> server control
 * over the tailnet. No Telegram involved.
 *
 *   GET  /v1/health                  unauthenticated liveness for supervisors
 *   GET  /v1/ping                    auth: { pong: true }
 *   GET  /v1/status                  auth: full node status (no secrets)
 *   GET  /v1/modules                 auth: [{ name, description, config, enabled }]
 *   GET  /v1/modules/:name/status    auth: one module
 *   GET  /v1/model                   auth: configured startup default (settings.json)
 *   GET  /v1/models                  auth: live catalog with per-provider auth
 *   POST /v1/model/validate          auth: dry-run selection check (read-only)
 *   PATCH /v1/modules/:name/config   auth: { patch } -> validated atomic write
 *   POST /v1/modules/:name/enable    auth: flip boolean "enabled" on
 *   POST /v1/modules/:name/disable   auth: flip boolean "enabled" off
 *   POST /v1/model                   auth: { provider?, model, thinkingLevel?, applyNow? } -> validated atomic write
 * Auth (every /v1/* route except /v1/health):
 *   X-Pi-Timestamp / X-Pi-Nonce / X-Pi-Signature, HMAC-SHA256 over
 *   METHOD + LF + PATH + LF + TS + LF + NONCE + LF + SHA256(raw body).
 * See shared/protocol.ts. Verification order: headers -> signature
 * (constant-time) -> freshness -> persisted anti-replay -> route/schema.
 *
 * What this file will NEVER do: run commands, open shells, resolve client
 * supplied paths/processes. Module file names come only from the registered
 * ModuleDefinition; service names only from remote-server.json allowlists.
 */
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import {
  freemem,
  hostname as osHostname,
  loadavg,
  totalmem,
  uptime as osUptime,
} from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import {
  BUILTIN_MODULES,
  applyModulePatchFile,
  enabledOf,
  isValidModuleName,
  readModuleConfigFile,
  type ModuleDefinition,
  type PatchValue,
} from "../../shared/modules.ts";
import {
  MAX_CLOCK_SKEW_SECONDS_DEFAULT,
  checkFreshness,
  createNonce,
  parseAuthHeaders,
  sha256Hex,
  verifySignature,
} from "../../shared/protocol.ts";
import {
  ReplayStore,
  atomicWriteJson,
  ensureDir,
  readJsonFile,
} from "../../shared/store.ts";

import { buildPiSpawn } from "../spawn-pi.mjs";
import {
  THINKING_LEVELS,
  isValidThinkingLevel,
  normalizeSelection,
  parseListModelsTable,
  readConfiguredDefault,
  resolvePiBin,
  writeConfiguredDefault,
  type PiModelInfo,
} from "../../shared/pi-model.ts";
const execFileAsync = promisify(execFile);
const LOG = "[pi-remote-server]";
const MAX_BODY_BYTES = 262144;

export interface RemoteServerConfig {
  port: number;
  /** Explicit bind override. When absent the daemon binds the tailnet IPv4. */
  bindHost?: string;
  maxSkewSeconds: number;
  allowedServices: string[];
}

export function defaultRemoteServerConfig(): RemoteServerConfig {
  return {
    port: 43128,
    maxSkewSeconds: 300,
    allowedServices: ["pi-server"],
  };
}

export function loadRemoteServerConfig(agentDir: string): RemoteServerConfig {
  const raw = readJsonFile<Record<string, unknown>>(
    join(agentDir, "remote-server.json"),
    {},
  );
  const port =
    typeof raw["port"] === "number" &&
    Number.isInteger(raw["port"]) &&
    (raw["port"] as number) >= 1 &&
    (raw["port"] as number) <= 65535
      ? (raw["port"] as number)
      : 43128;
  const bindHost =
    typeof raw["bindHost"] === "string" && raw["bindHost"].trim().length > 0
      ? raw["bindHost"].trim()
      : undefined;
  const skew =
    typeof raw["maxSkewSeconds"] === "number"
      ? Math.min(3600, Math.max(30, Math.floor(raw["maxSkewSeconds"] as number)))
      : 300;
  const allowed = Array.isArray(raw["allowedServices"])
    ? (raw["allowedServices"] as unknown[]).filter(
        (s): s is string => typeof s === "string",
      )
    : ["pi-server"];
  return { port, bindHost, maxSkewSeconds: skew, allowedServices: allowed };
}

export interface RemoteServerOptions {
  agentDir: string;
  hmac: string;
  config: RemoteServerConfig;
  /** Resolved bind address (tailnet IPv4, override, or loopback fallback). */
  bindHost: string;
  version: string;
}

interface Ctx {
  opts: RemoteServerOptions;
  store: ReplayStore;
  secrets: { hmac: string };
}

function sendJson(res: ServerResponse, status: number, obj: unknown): void {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

function unauthorized(
  res: ServerResponse,
  error: string,
  message: string,
): void {
  sendJson(res, 401, { ok: false, error, message });
}

async function readBody(req: IncomingMessage): Promise<
  | { ok: true; raw: string }
  | { ok: false; error: "body_too_large" | "body_unreadable" }
> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let done = false;
    const finish = (
      r:
        | { ok: true; raw: string }
        | { ok: false; error: "body_too_large" | "body_unreadable" },
    ) => {
      if (done) return;
      done = true;
      resolve(r);
    };
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > MAX_BODY_BYTES) {
        finish({ ok: false, error: "body_too_large" });
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () =>
      finish({ ok: true, raw: Buffer.concat(chunks).toString("utf8") }),
    );
    req.on("error", () => finish({ ok: false, error: "body_unreadable" }));
  });
}

function parseJsonBody(
  raw: string,
): { ok: true; value: unknown } | { ok: false; error: string } {
  if (raw.trim().length === 0) return { ok: false, error: "empty_body" };
  try {
    return { ok: true, value: JSON.parse(raw) as unknown };
  } catch {
    return { ok: false, error: "malformed_json" };
  }
}

async function runCmd(
  cmd: string,
  args: string[],
  timeoutMs: number,
): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync(cmd, args, {
      timeout: timeoutMs,
      windowsHide: true,
    });
    return stdout.trim().slice(0, 200);
  } catch {
    return null;
  }
}

function piTelegramVersion(agentDir: string): string {
  try {
    const req = createRequire(
      join(agentDir, "extensions", "pi-remote-config", "index.ts"),
    );
    const pkg = req.resolve("@llblab/pi-telegram/package.json");
    const raw = JSON.parse(readFileSync(pkg, "utf8")) as { version?: string };
    return typeof raw.version === "string" ? raw.version : "unknown";
  } catch {
    return "unknown";
  }
}

function fmtUptime(sec: number): string {
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  return `${d}d ${h}h ${m}m`;
}

export interface ModuleView {
  name: string;
  description: string;
  config: Record<string, PatchValue>;
  /** Null when the module declares no boolean "enabled" field. */
  enabled: boolean | null;
}

export interface RemoteHttpStatus {
  online: true;
  at: string;
  hostname: string;
  appVersion: string;
  osUptime: string;
  processUptime: string;
  node: string;
  pi: string;
  piTelegram: string;
  memory: { totalMb: number; freeMb: number; usedPct: number };
  load: number[];
  modules: ModuleView[];
  lastRemoteRequest: unknown;
  lastError: unknown;
}

function moduleView(
  configDir: string,
  def: ModuleDefinition,
): ModuleView {
  const config = readModuleConfigFile(configDir, def);
  return {
    name: def.name,
    description: def.description,
    config,
    enabled: enabledOf(def, config),
  };
}

async function collectHttpStatus(ctx: Ctx): Promise<RemoteHttpStatus> {
  const agentDir = ctx.opts.agentDir;
  const configDir = join(agentDir, "server-config");
  const [piVersion] = await Promise.all([runCmd("pi", ["--version"], 10000)]);
  const totalMb = Math.round(totalmem() / 1048576);
  const freeMb = Math.round(freemem() / 1048576);
  const snap = ctx.store.snapshot();
  return {
    online: true,
    at: new Date().toISOString(),
    hostname: osHostname(),
    appVersion: ctx.opts.version,
    osUptime: fmtUptime(osUptime()),
    processUptime: fmtUptime(process.uptime()),
    node: process.version,
    pi: piVersion ?? "unknown",
    piTelegram: piTelegramVersion(agentDir),
    memory: {
      totalMb,
      freeMb,
      usedPct: Math.round(
        ((totalMb - freeMb) / Math.max(1, totalMb)) * 100,
      ),
    },
    load: loadavg().map((n) => Math.round(n * 100) / 100),
    modules: BUILTIN_MODULES.map((def) => moduleView(configDir, def)),
    lastRemoteRequest: snap.lastRemoteUpdate ?? null,
    lastError: snap.lastError ?? null,
  };
}

function coreGates(configDir: string): { ok: true } | { ok: false; error: string; message: string } {
  const core = BUILTIN_MODULES.find((d) => d.name === "core");
  const cfg = core
    ? readModuleConfigFile(configDir, core)
    : { remoteControlEnabled: true, maintenanceMode: false };
  if (cfg["remoteControlEnabled"] === false) {
    return {
      ok: false,
      error: "remote_disabled",
      message: "Remote control is disabled (core.remoteControlEnabled=false).",
    };
  }
  if (cfg["maintenanceMode"] === true) {
    return {
      ok: false,
      error: "maintenance",
      message: "Server is in maintenance mode.",
    };
  }
  return { ok: true };
}

interface Authed {
  ts: number;
  nonce: string;
}

/**
 * Full auth pipeline for one request. On success the nonce is already
 * persisted (replay-safe) and the attempt recorded. Never throws.
 */
async function authenticate(
  ctx: Ctx,
  method: string,
  path: string,
  rawBody: string,
  getHeader: (name: string) => string | string[] | undefined,
  opLabel: string,
): Promise<{ ok: true; auth: Authed } | { ok: false; error: string; message: string }> {
  const now = Math.floor(Date.now() / 1000);
  const fail = (error: string, message: string) => {
    try {
      ctx.store.recordUpdate({ at: now, op: opLabel, ok: false, error });
    } catch {
      // recording must never break auth
    }
    return { ok: false as const, error, message };
  };
  const parsed = parseAuthHeaders(getHeader);
  if (!parsed.ok) {
    const messages: Record<string, string> = {
      missing_auth: "Missing X-Pi-Timestamp / X-Pi-Nonce / X-Pi-Signature headers.",
      bad_ts: "X-Pi-Timestamp must be unix seconds.",
      bad_nonce: "X-Pi-Nonce malformed.",
      bad_signature_shape: "X-Pi-Signature must be 64 hex chars.",
    };
    return fail(parsed.error, messages[parsed.error] ?? "Unauthorized.");
  }
  const { ts, nonce, signature } = parsed.auth;
  const bodyHash = sha256Hex(rawBody);
  const okSig = verifySignature(signature, ctx.secrets.hmac, {
    method,
    path,
    ts,
    nonce,
    bodyHash,
  });
  if (!okSig) return fail("bad_signature", "Signature mismatch.");
  const fresh = checkFreshness(ts, now, ctx.opts.config.maxSkewSeconds);
  if (fresh !== "ok") {
    return fail(
      fresh,
      fresh === "ts_future" ? "Timestamp too far in the future." : "Timestamp expired.",
    );
  }
  if (ctx.store.has(nonce, now)) {
    return fail("replay", "Duplicate nonce (replay). Ignored.");
  }
  try {
    ctx.store.add(nonce, ts, now);
  } catch {
    return fail("replay_store", "Could not persist nonce; refusing.");
  }
  return { ok: true, auth: { ts, nonce } };
}

function findModule(name: string): ModuleDefinition | undefined {
  if (!isValidModuleName(name)) return undefined;
  return BUILTIN_MODULES.find((d) => d.name === name);
}

function decodeSegment(seg: string): string | null {
  try {
    return decodeURIComponent(seg);
  } catch {
    return null;
  }
}

// ---- Remote Model Management (server_model) ----
// Pi 0.85.1 startup defaults live in <agentDir>/settings.json
// (defaultProvider/defaultModel/defaultThinkingLevel) and apply at next Pi
// start; the running rpc session keeps its boot-time model. All subprocess
// calls use fixed/allowlisted args only (never remote input), with
// PI_CODING_AGENT_DIR scoped to the server agent dir.
const LIST_MODELS_TIMEOUT_MS = 30000;
const AUTH_CHECK_TIMEOUT_MS = 10000;
const MAX_PROVIDERS_PROBED = 10;
const MAX_MODELS_RETURNED = 100;

function daemonAppRoot(): string | null {
  try {
    return join(dirname(import.meta.dirname), "..", "..");
  } catch {
    return null;
  }
}

interface PiRunResult {
  ok: boolean;
  stdout: string;
  exitCode: number | null;
  timedOut: boolean;
  spawnFailed: boolean;
}

async function runPi(
  agentDir: string,
  extraArgs: string[],
  timeoutMs: number,
): Promise<PiRunResult> {
  const bin = resolvePiBin(daemonAppRoot()) ?? "pi";
  const spec = buildPiSpawn(bin, process.platform, extraArgs);
  try {
    const { stdout } = await execFileAsync(spec.command, spec.args, {
      timeout: timeoutMs,
      windowsHide: true,
      windowsVerbatimArguments: !!spec.windowsVerbatimArguments,
      env: { ...process.env, PI_CODING_AGENT_DIR: agentDir },
      maxBuffer: 1024 * 1024,
    });
    return {
      ok: true,
      stdout: String(stdout ?? ""),
      exitCode: 0,
      timedOut: false,
      spawnFailed: false,
    };
  } catch (err) {
    const e = err as {
      code?: unknown;
      killed?: boolean;
      stdout?: unknown;
    };
    const out = typeof e.stdout === "string" ? e.stdout : "";
    if (e?.killed)
      return { ok: false, stdout: out, exitCode: null, timedOut: true, spawnFailed: false };
    if (e?.code === "ENOENT")
      return { ok: false, stdout: out, exitCode: null, timedOut: false, spawnFailed: true };
    const code = typeof e?.code === "number" ? (e.code as number) : null;
    return { ok: false, stdout: out, exitCode: code, timedOut: false, spawnFailed: false };
  }
}

/** Last JSON line of CLI output (commands may print warnings above it). */
function lastJsonLine(stdout: string): unknown | null {
  const lines = stdout
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      return JSON.parse(lines[i]);
    } catch {
      // keep scanning upward
    }
  }
  return null;
}

async function fetchModelCatalog(
  agentDir: string,
): Promise<
  | { ok: true; models: PiModelInfo[] }
  | { ok: false; error: string; message: string }
> {
  const r = await runPi(agentDir, ["--list-models"], LIST_MODELS_TIMEOUT_MS);
  if (r.spawnFailed)
    return { ok: false, error: "pi_unavailable", message: "pi binary could not be started." };
  if (r.timedOut)
    return { ok: false, error: "pi_timeout", message: "pi --list-models timed out." };
  if (!r.ok)
    return { ok: false, error: "pi_list_failed", message: "pi --list-models exited unsuccessfully." };
  const parsed = parseListModelsTable(r.stdout);
  if (!parsed.ok)
    return { ok: false, error: "pi_output_unparseable", message: "Could not parse pi --list-models output." };
  return { ok: true, models: parsed.models };
}

async function checkProviderReady(
  agentDir: string,
  provider: string,
): Promise<{ ready: boolean; authType: string | null }> {
  // Allowlist shape: provider comes from Pi's own catalog; regex is defense in depth.
  if (!/^[A-Za-z0-9_.-]+$/.test(provider)) return { ready: false, authType: null };
  const r = await runPi(
    agentDir,
    ["auth", "check", "--provider", provider, "--json", "--no-refresh"],
    AUTH_CHECK_TIMEOUT_MS,
  );
  if (!r.ok || r.exitCode !== 0) return { ready: false, authType: null };
  const j = lastJsonLine(r.stdout) as {
    status?: unknown;
    authType?: unknown;
  } | null;
  if (!j || j.status !== "ready") return { ready: false, authType: null };
  return {
    ready: true,
    authType: typeof j.authType === "string" ? j.authType : null,
  };
}

interface SetBody {
  provider?: string;
  model?: string;
  thinkingLevel?: string;
  applyNow?: boolean;
}

function parseSetBody(v: unknown):
  | { ok: true; value: SetBody }
  | { ok: false; error: string } {
  if (typeof v !== "object" || v === null || Array.isArray(v)) {
    return { ok: false, error: "body_must_be_object" };
  }
  const rec = v as Record<string, unknown>;
  const allowed = ["provider", "model", "thinkingLevel", "applyNow"];
  for (const k of Object.keys(rec)) {
    if (!allowed.includes(k)) return { ok: false, error: `unknown_field:${k}` };
  }
  const out: SetBody = {};
  if (rec["provider"] !== undefined) {
    if (typeof rec["provider"] !== "string" || (rec["provider"] as string).trim() === "") {
      return { ok: false, error: "provider_must_be_string" };
    }
    out.provider = (rec["provider"] as string).trim();
  }
  if (rec["model"] === undefined) {
    return { ok: false, error: "model_required" };
  } else {
    if (typeof rec["model"] !== "string" || (rec["model"] as string).trim() === "") {
      return { ok: false, error: "model_must_be_string" };
    }
    out.model = (rec["model"] as string).trim();
  }
  if (rec["thinkingLevel"] !== undefined && rec["thinkingLevel"] !== null) {
    if (!isValidThinkingLevel(rec["thinkingLevel"])) {
      return {
        ok: false,
        error: `invalid_thinking_level (allowed: ${THINKING_LEVELS.join(", ")})`,
      };
    }
    out.thinkingLevel = rec["thinkingLevel"] as string;
  }
  if (rec["applyNow"] !== undefined) {
    if (typeof rec["applyNow"] !== "boolean") {
      return { ok: false, error: "applynow_must_be_boolean" };
    }
    out.applyNow = rec["applyNow"] as boolean;
  }
  return { ok: true, value: out };
}

async function resolveSelectionLive(
  agentDir: string,
  input: { provider?: string; model?: string },
): Promise<
  | { ok: true; provider: string; model: string; authed: string[] }
  | { ok: false; error: string; message: string }
> {
  const cat = await fetchModelCatalog(agentDir);
  if (!cat.ok) return cat;
  if (cat.models.length === 0) {
    return {
      ok: false,
      error: "no_models_available",
      message: "Pi reports no available models (no logins on the server?).",
    };
  }
  const providers = [...new Set(cat.models.map((m) => m.provider))].slice(
    0,
    MAX_PROVIDERS_PROBED,
  );
  const checks = await Promise.all(
    providers.map(async (p) => [p, await checkProviderReady(agentDir, p)] as const),
  );
  const authed = checks.filter(([, a]) => a.ready).map(([p]) => p);
  const norm = normalizeSelection(input, cat.models, authed);
  if (!norm.ok) return { ok: false, error: norm.error.split(":")[0], message: norm.error };
  if (!authed.includes(norm.provider)) {
    return {
      ok: false,
      error: "provider_not_authenticated",
      message: `Provider "${norm.provider}" has no ready auth. Log in on the server first.`,
    };
  }
  return { ok: true, provider: norm.provider, model: norm.model, authed };
}
async function handle(
  ctx: Ctx,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  let pathname = "/";
  try {
    const url = new URL(req.url ?? "/", "http://internal");
    if (url.search !== "") {
      sendJson(res, 400, {
        ok: false,
        error: "query_not_allowed",
        message: "Query strings are not part of the signed path.",
      });
      return;
    }
    pathname = url.pathname.replace(/\/+$/, "") || "/";
  } catch {
    sendJson(res, 400, { ok: false, error: "bad_path" });
    return;
  }
  const method = (req.method ?? "").toUpperCase();

  if (method === "GET" && pathname === "/v1/health") {
    sendJson(res, 200, {
      ok: true,
      service: "pi-remote-server",
      version: ctx.opts.version,
    });
    return;
  }

  if (!pathname.startsWith("/v1/")) {
    sendJson(res, 404, { ok: false, error: "not_found" });
    return;
  }

  const body = await readBody(req);
  if (!body.ok) {
    sendJson(res, body.error === "body_too_large" ? 413 : 400, {
      ok: false,
      error: body.error,
    });
    return;
  }

  const opLabel = `${method} ${pathname}`;
  const authed = await authenticate(
    ctx,
    method,
    pathname,
    body.raw,
    (n) => req.headers[n],
    opLabel,
  );
  if (!authed.ok) {
    unauthorized(res, authed.error, authed.message);
    return;
  }
  const now = Math.floor(Date.now() / 1000);
  const record = (ok: boolean, error?: string) => {
    try {
      ctx.store.recordUpdate({ at: now, op: opLabel, ok, error });
    } catch {
      // recording must never break responses
    }
  };

  const configDir = join(ctx.opts.agentDir, "server-config");

  if (method === "GET" && pathname === "/v1/ping") {
    record(true);
    sendJson(res, 200, { ok: true, body: { pong: true } });
    return;
  }

  if (method === "GET" && pathname === "/v1/status") {
    try {
      const status = await collectHttpStatus(ctx);
      record(true);
      sendJson(res, 200, { ok: true, body: status });
    } catch (err) {
      const message = err instanceof Error ? err.message : "status_failed";
      record(false, message);
      sendJson(res, 500, { ok: false, error: "status_failed", message });
    }
    return;
  }

  if (method === "GET" && pathname === "/v1/modules") {
    record(true);
    sendJson(res, 200, {
      ok: true,
      body: {
        modules: BUILTIN_MODULES.map((def) => moduleView(configDir, def)),
      },
    });
    return;
  }

  if (method === "GET" && pathname === "/v1/model") {
    try {
      const cfg = readConfiguredDefault(ctx.opts.agentDir);
      record(true);
      sendJson(res, 200, {
        ok: true,
        body: {
          provider: cfg.provider,
          model: cfg.model,
          thinkingLevel: cfg.thinkingLevel,
          settingsPath: cfg.settingsPath,
          source: cfg.source,
          requiresRestart: cfg.provider !== null,
          liveModel: null,
          currentDaemonState: {
            alive: true,
            uptimeSec: Math.floor(process.uptime()),
          },
          note: "Startup default from settings.json; applies at next Pi start. The live rpc session keeps its boot-time model.",
        },
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : "read_failed";
      record(false, message);
      sendJson(res, 500, {
        ok: false,
        error: message === "settings_corrupt" ? "settings_corrupt" : "settings_unreadable",
        message,
      });
    }
    return;
  }

  if (method === "GET" && pathname === "/v1/models") {
    const cat = await fetchModelCatalog(ctx.opts.agentDir);
    if (!cat.ok) {
      record(false, cat.error);
      sendJson(res, 502, { ok: false, error: cat.error, message: cat.message });
      return;
    }
    const providers = [...new Set(cat.models.map((m) => m.provider))].slice(
      0,
      MAX_PROVIDERS_PROBED,
    );
    const checks = await Promise.all(
      providers.map(async (p) => [p, await checkProviderReady(ctx.opts.agentDir, p)] as const),
    );
    const authMap = new Map(checks.map(([p, a]) => [p, a]));
    const rows = cat.models.slice(0, MAX_MODELS_RETURNED).map((m) => {
      const a = authMap.get(m.provider);
      return {
        provider: m.provider,
        id: m.id,
        name: m.name,
        thinking: m.thinking,
        images: m.images,
        context: m.context,
        maxOut: m.maxOut,
        available: true,
        authenticated: a?.ready ?? false,
        authType: a?.authType ?? null,
      };
    });
    record(true);
    sendJson(res, 200, {
      ok: true,
      body: {
        models: rows,
        truncated: cat.models.length > MAX_MODELS_RETURNED,
        providersProbed: providers.length,
      },
    });
    return;
  }

  if (method === "POST" && pathname === "/v1/model/validate") {
    const parsed = parseJsonBody(body.raw);
    if (!parsed.ok || typeof parsed.value !== "object" || parsed.value === null) {
      record(false, parsed.ok ? "body_must_be_object" : parsed.error);
      sendJson(res, 400, {
        ok: false,
        error: parsed.ok ? "body_must_be_object" : parsed.error,
        message: "Body must be a JSON object: { provider?, model, thinkingLevel?, applyNow? }.",
      });
      return;
    }
    const shaped = parseSetBody(parsed.value);
    if (!shaped.ok) {
      record(false, shaped.error);
      sendJson(res, 400, { ok: false, error: shaped.error, message: shaped.error });
      return;
    }
    const r = await resolveSelectionLive(ctx.opts.agentDir, shaped.value);
    if (!r.ok) {
      record(false, r.error);
      const status = r.error.startsWith("pi_") ? 502 : 400;
      sendJson(res, status, { ok: false, error: r.error, message: r.message });
      return;
    }
    record(true);
    sendJson(res, 200, {
      ok: true,
      body: {
        valid: true,
        provider: r.provider,
        model: r.model,
        thinkingLevel: shaped.value.thinkingLevel ?? null,
        authenticated: true,
        message: "Selection is available and authenticated (dry run, nothing written).",
      },
    });
    return;
  }

  if (method === "POST" && pathname === "/v1/model") {
    const gate = coreGates(configDir);
    if (!gate.ok) {
      record(false, gate.error);
      sendJson(res, 403, { ok: false, error: gate.error, message: gate.message });
      return;
    }
    const parsed = parseJsonBody(body.raw);
    if (!parsed.ok || typeof parsed.value !== "object" || parsed.value === null) {
      record(false, parsed.ok ? "body_must_be_object" : parsed.error);
      sendJson(res, 400, {
        ok: false,
        error: parsed.ok ? "body_must_be_object" : parsed.error,
        message: "Body must be a JSON object: { provider?, model, thinkingLevel?, applyNow? }.",
      });
      return;
    }
    const shaped = parseSetBody(parsed.value);
    if (!shaped.ok) {
      record(false, shaped.error);
      sendJson(res, 400, { ok: false, error: shaped.error, message: shaped.error });
      return;
    }
    const r = await resolveSelectionLive(ctx.opts.agentDir, shaped.value);
    if (!r.ok) {
      record(false, r.error);
      const status = r.error.startsWith("pi_") ? 502 : 400;
      sendJson(res, status, { ok: false, error: r.error, message: r.message });
      return;
    }
    try {
      const { backup, settingsPath } = writeConfiguredDefault(ctx.opts.agentDir, {
        provider: r.provider,
        model: r.model,
        thinkingLevel: shaped.value.thinkingLevel ?? null,
      });
      const after = readConfiguredDefault(ctx.opts.agentDir);
      const applyNow = shaped.value.applyNow === true;
      record(true);
      sendJson(res, 200, {
        ok: true,
        body: {
          provider: r.provider,
          model: r.model,
          thinkingLevel: after.thinkingLevel,
          backup,
          settingsPath,
          requiresRestart: true,
          applied: false,
          message: applyNow
            ? "Saved. No remote restart channel exists: restart the PiHomeServer task to apply now, otherwise applies at next Pi start."
            : "Saved. Applies at next Pi start (restart PiHomeServer to apply now).",
        },
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : "write_failed";
      record(false, message);
      sendJson(res, 500, {
        ok: false,
        error: message === "settings_corrupt" ? "settings_corrupt" : "settings_write_failed",
        message,
      });
    }
    return;
  }

  const modPrefix = "/v1/modules/";
  if (pathname.startsWith(modPrefix)) {
    const rest = pathname.slice(modPrefix.length).split("/");
    const rawName = rest[0] ?? "";
    const name = decodeSegment(rawName);
    const def = name === null ? undefined : findModule(name);
    if (!def) {
      record(false, "unknown_module");
      sendJson(res, 404, {
        ok: false,
        error: "unknown_module",
        message: `Unknown module. Registered: ${BUILTIN_MODULES.map((d) => d.name).join(", ")}`,
      });
      return;
    }
    const tail = rest.slice(1).join("/");

    if (method === "GET" && tail === "status") {
      record(true);
      sendJson(res, 200, { ok: true, body: moduleView(configDir, def) });
      return;
    }

    // ---- mutating routes honor the core master switches ----
    const gate = coreGates(configDir);
    if (!gate.ok) {
      record(false, gate.error);
      sendJson(res, 403, { ok: false, error: gate.error, message: gate.message });
      return;
    }

    if (method === "PATCH" && tail === "config") {
      const parsed = parseJsonBody(body.raw);
      if (!parsed.ok || typeof parsed.value !== "object" || parsed.value === null) {
        record(false, parsed.ok ? "patch_must_be_object" : parsed.error);
        sendJson(res, 400, {
          ok: false,
          error: parsed.ok ? "patch_must_be_object" : parsed.error,
          message: "Body must be a JSON object: { \"patch\": { ... } }.",
        });
        return;
      }
      const patch = (parsed.value as Record<string, unknown>)["patch"];
      try {
        const { config } = applyModulePatchFile(configDir, def, patch);
        try {
          ensureDir(configDir, 0o700);
        } catch {
          // ignore
        }
        record(true);
        sendJson(res, 200, { ok: true, body: { module: def.name, config } });
      } catch (err) {
        const message = err instanceof Error ? err.message : "apply_failed";
        record(false, message);
        sendJson(res, 400, {
          ok: false,
          error: "invalid_patch",
          message: `Refused: ${message}`,
          details: message,
        });
      }
      return;
    }

    if (
      method === "POST" &&
      (tail === "enable" || tail === "disable")
    ) {
      const want = tail === "enable";
      try {
        const { config } = applyModulePatchFile(configDir, def, {
          enabled: want,
        });
        record(true);
        sendJson(res, 200, { ok: true, body: { module: def.name, config } });
      } catch (err) {
        const message = err instanceof Error ? err.message : "apply_failed";
        record(false, message);
        const noField = message.includes("unknown_field:enabled");
        sendJson(res, 400, {
          ok: false,
          error: noField ? "no_enabled_field" : "invalid_patch",
          message: noField
            ? `Module "${def.name}" has no boolean "enabled" field.`
            : `Refused: ${message}`,
        });
      }
      return;
    }
  }

  record(false, "not_found");
  sendJson(res, 404, { ok: false, error: "not_found" });
}

/**
 * App version for status output. Probes VERSION then package.json under the
 * given app root; returns "dev" when neither exists (e.g. Linux repo runs).
 * Pure function of the filesystem: safe to import from any process.
 */
export function readAppVersion(appRoot: string | null): string {
  try {
    if (appRoot) {
      const vf = join(appRoot, "VERSION");
      if (existsSync(vf)) {
        const v = readFileSync(vf, "utf8").trim();
        if (v.length > 0) return v.slice(0, 32);
      }
      const pkg = join(appRoot, "package.json");
      if (existsSync(pkg)) {
        const raw = JSON.parse(readFileSync(pkg, "utf8")) as { version?: string };
        if (typeof raw.version === "string" && raw.version.length > 0) {
          return raw.version.slice(0, 32);
        }
      }
    }
  } catch {
    // fall through
  }
  return "dev";
}

export interface RemoteServerHandles {
  server: Server;
}

/** Build (but do not listen on) the remote HTTP server. Tests bind it to 127.0.0.1:0. */
export function createRemoteServer(opts: RemoteServerOptions): RemoteServerHandles {
  const agentDir = opts.agentDir;
  ensureDir(agentDir, 0o700);
  const store = new ReplayStore(
    join(agentDir, "remote-state.json"),
    opts.config.maxSkewSeconds * 2,
  );
  try {
    store.recordUpdate({
      at: Math.floor(Date.now() / 1000),
      op: "boot",
      ok: true,
    });
  } catch {
    // ignore
  }
  const ctx: Ctx = { opts, store, secrets: { hmac: opts.hmac } };
  const server = createServer((req, res) => {
    handle(ctx, req, res).catch((err) => {
      try {
        ctx.store.recordError(
          "http_handler",
          err instanceof Error ? err.message : "unknown",
        );
      } catch {
        // ignore
      }
      try {
        sendJson(res, 500, { ok: false, error: "internal" });
      } catch {
        try {
          res.destroy();
        } catch {
          // ignore
        }
      }
    });
  });
  server.timeout = 30_000;
  server.on("clientError", (_err, socket) => {
    try {
      socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
    } catch {
      // ignore
    }
  });
  return { server };
}

/** Read the HMAC secret. Missing/empty secret is fatal: no secret, no server. */
export function loadRemoteHmac(agentDir: string): string | null {
  try {
    const file = join(agentDir, "secrets", "remote-hmac");
    if (!existsSync(file)) return null;
    const v = readFileSync(file, "utf8").trim();
    return v.length >= 16 ? v : null;
  } catch {
    return null;
  }
}
