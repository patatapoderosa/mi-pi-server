/**
 * pi-remote-config — server-side Pi extension (old PC, 24/7 node).
 *
 * A) Local tools for the on-server agent: server_config / server_status / service_control.
 *    Config writes only touch WHITELISTED fields of REGISTERED modules.
 *    There is deliberately NO remote shell, NO arbitrary paths, NO exec tool.
 *
 * B) Remote control from the Mac: intercepts special Telegram messages posted
 *    by the ControlBot into the private control group, verifies them
 *    (sender id + HMAC-SHA256 + timestamp + persisted anti-replay + op/module
 *    whitelist + field schema), applies them, and replies in the same chat.
 *
 * Polling rule: this file NEVER calls getUpdates. The single polling loop is
 * owned by @llblab/pi-telegram. We hook into its PUBLIC registry
 * (docs/updates.md: `registerTelegramUpdateHandler`, zero-coupling globalThis
 * contract v1) and return "consume" for every message that carries our
 * prefix — valid or invalid — so remote payloads never reach the model.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { execFile } from "node:child_process";
import { createRequire } from "node:module";
import { existsSync, readFileSync } from "node:fs";
import { freemem, loadavg, totalmem, uptime as osUptime } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import {
  REMOTE_PREFIX,
  encodeResponse,
  isRemoteOp,
  verifySignedText,
  type RemoteOp,
} from "../../shared/protocol.ts";
import {
  BUILTIN_MODULES,
  isValidConfigFileName,
  isValidModuleName,
  validatePatch,
  type ModuleDefinition,
  type PatchValue,
} from "../../shared/modules.ts";
import {
  ReplayStore,
  atomicWriteJson,
  backupFile,
  ensureDir,
  readJsonFile,
  resolveAgentDir,
} from "../../shared/store.ts";

const execFileAsync = promisify(execFile);
const LOG = "[remote-config]";

/* ------------------------------------------------------------------ */
/* Paths & config                                                      */
/* ------------------------------------------------------------------ */

export interface RemoteAuth {
  allowedControlBotId: number;
  controlChatId?: number;
  maxSkewSeconds?: number;
  allowedServices?: string[];
}

interface Paths {
  agentDir: string;
  authFile: string;
  configDir: string;
  secretsDir: string;
  hmacFile: string;
  serverBotTokenFile: string;
  stateFile: string;
}

function paths(): Paths {
  const agentDir = resolveAgentDir();
  return {
    agentDir,
    authFile: join(agentDir, "remote-auth.json"),
    configDir: join(agentDir, "server-config"),
    secretsDir: join(agentDir, "secrets"),
    hmacFile: join(agentDir, "secrets", "remote-hmac"),
    serverBotTokenFile: join(agentDir, "secrets", "server-bot-token"),
    stateFile: join(agentDir, "remote-state.json"),
  };
}

function loadAuth(p: Paths): RemoteAuth | null {
  const raw = readJsonFile<Partial<RemoteAuth> | null>(p.authFile, null);
  if (
    !raw ||
    typeof raw.allowedControlBotId !== "number" ||
    !Number.isInteger(raw.allowedControlBotId)
  )
    return null;
  return {
    allowedControlBotId: raw.allowedControlBotId,
    controlChatId:
      typeof raw.controlChatId === "number" ? raw.controlChatId : undefined,
    maxSkewSeconds:
      typeof raw.maxSkewSeconds === "number"
        ? Math.min(3600, Math.max(30, raw.maxSkewSeconds))
        : 300,
    allowedServices: Array.isArray(raw.allowedServices)
      ? raw.allowedServices.filter(
          (s: unknown): s is string => typeof s === "string",
        )
      : ["pi-server"],
  };
}

function readSecretFile(file: string): string | null {
  try {
    if (!existsSync(file)) return null;
    const v = readFileSync(file, "utf8").trim();
    return v.length > 0 ? v : null;
  } catch {
    return null;
  }
}

function resolveEnvRef(value: string): string {
  const m =
    /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))$/.exec(
      value.trim(),
    );
  if (m) return process.env[m[1] ?? m[2] ?? ""] ?? "";
  return value;
}

/** ServerBot token: secrets file first, then telegram.json profile (with $ENV support). */
export function loadServerBotToken(p: Paths): string | null {
  const fromFile = readSecretFile(p.serverBotTokenFile);
  if (fromFile) return fromFile;
  try {
    const tg = readJsonFile<{
      profiles?: Record<string, { botToken?: string }>;
    }>(join(p.agentDir, "telegram.json"), {});
    const tok = tg.profiles?.["default"]?.botToken;
    if (typeof tok === "string" && tok.length > 0) {
      const resolved = resolveEnvRef(tok);
      return resolved.length > 0 ? resolved : null;
    }
  } catch {
    // fall through
  }
  return null;
}

/* ------------------------------------------------------------------ */
/* Module registry                                                     */
/* ------------------------------------------------------------------ */

export interface ModuleRuntime {
  def: ModuleDefinition;
  /** Called after a config file was applied. Throwing is caught and reported. */
  onConfigApplied?: (
    config: Record<string, PatchValue>,
  ) => void | Promise<void>;
  /** Extra status rows merged into server_status output. */
  getStatus?: () =>
    | Record<string, PatchValue | string>
    | Promise<Record<string, PatchValue | string>>;
}

const registry = new Map<string, ModuleRuntime>();

/**
 * Future-proof registration API for new modules (in-process companions):
 *   registerRemoteModule({ def: {...}, onConfigApplied, getStatus })
 * The definition alone determines what can be changed remotely.
 */
export function registerRemoteModule(runtime: ModuleRuntime): void {
  const def = runtime.def;
  if (!isValidModuleName(def.name))
    throw new Error(`[remote-config] invalid module name: ${String(def.name)}`);
  if (!isValidConfigFileName(def.configFile))
    throw new Error(
      `[remote-config] invalid config file: ${String(def.configFile)}`,
    );
  if (
    typeof def.schema !== "object" ||
    def.schema === null ||
    Object.keys(def.schema).length === 0
  ) {
    throw new Error(
      `[remote-config] module ${def.name} must declare a non-empty schema`,
    );
  }
  registry.set(def.name, runtime);
}

function configPathFor(p: Paths, def: ModuleDefinition): string {
  // Fixed file name inside configDir — never derived from remote input.
  return join(p.configDir, def.configFile);
}

function readModuleConfig(
  p: Paths,
  def: ModuleDefinition,
): Record<string, PatchValue> {
  const current = readJsonFile<Record<string, unknown>>(
    configPathFor(p, def),
    {},
  );
  const merged: Record<string, PatchValue> = { ...def.defaults };
  for (const [k, v] of Object.entries(current)) {
    if (
      k in def.schema &&
      (typeof v === "string" || typeof v === "number" || typeof v === "boolean")
    )
      merged[k] = v;
  }
  return merged;
}

/** Validate + backup + atomically write a module config. Returns backup path (if any). */
export function applyModulePatch(
  p: Paths,
  name: string,
  patch: unknown,
): { config: Record<string, PatchValue>; backup: string | null } {
  const runtime = registry.get(name);
  if (!runtime) throw new Error(`unknown_module:${name}`);
  const current = readJsonFile<Record<string, unknown>>(
    configPathFor(p, runtime.def),
    {},
  );
  const result = validatePatch(runtime.def, current, patch);
  if (!result.ok) throw new Error(`invalid_patch:${result.errors.join(",")}`);
  const file = configPathFor(p, runtime.def);
  ensureDir(p.configDir, 0o700);
  const backup = existsSync(file) ? backupFile(file) : null;
  atomicWriteJson(file, result.merged, 0o600);
  return { config: result.merged ?? {}, backup };
}

/* ------------------------------------------------------------------ */
/* Telegram send (HTTPS POST only — no polling here)                   */
/* ------------------------------------------------------------------ */

async function sendTelegram(
  token: string,
  chatId: number,
  text: string,
  replyTo?: number,
): Promise<boolean> {
  const url = `https://api.telegram.org/bot${token}/sendMessage`;
  const body: Record<string, unknown> = {
    chat_id: chatId,
    text: text.slice(0, 4000),
    disable_notification: true,
  };
  if (replyTo !== undefined) body["reply_parameters"] = { message_id: replyTo };
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(15000),
      });
      if (res.ok) return true;
      if (res.status >= 400 && res.status < 500) return false; // retrying won't help
    } catch {
      // network down — fall through to backoff
    }
    await new Promise((r) => setTimeout(r, 1000 * 2 ** attempt));
  }
  return false;
}

/* ------------------------------------------------------------------ */
/* Status                                                              */
/* ------------------------------------------------------------------ */

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
    return stdout.trim().slice(0, 2000);
  } catch {
    return null;
  }
}

async function pm2List(): Promise<Array<Record<string, unknown>>> {
  const out = await runCmd("pm2", ["jlist"], 10000);
  if (!out) return [];
  try {
    const arr = JSON.parse(out) as Array<Record<string, unknown>>;
    return Array.isArray(arr) ? arr : [];
  } catch {
    return [];
  }
}

function piTelegramVersion(): string {
  try {
    const req = createRequire(
      join(resolveAgentDir(), "extensions", "pi-remote-config", "index.ts"),
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

export interface ServerStatus {
  online: true;
  at: string;
  osUptime: string;
  piUptime: string;
  node: string;
  pi: string;
  piTelegram: string;
  memory: { totalMb: number; freeMb: number; usedPct: number };
  load: number[];
  pm2: Array<{
    name: string;
    status: string;
    cpu: unknown;
    memory: unknown;
    uptime: string;
  }>;
  modules: Array<{
    name: string;
    config: Record<string, PatchValue>;
    extra?: Record<string, unknown>;
  }>;
  lastRemoteUpdate: unknown;
  lastError: unknown;
}

export async function collectStatus(
  p: Paths,
  store: ReplayStore,
): Promise<ServerStatus> {
  const [piVersion, pm2] = await Promise.all([
    runCmd("pi", ["--version"], 10000),
    pm2List(),
  ]);
  const totalMb = Math.round(totalmem() / 1048576);
  const freeMb = Math.round(freemem() / 1048576);
  const modules: ServerStatus["modules"] = [];
  for (const [name, runtime] of registry) {
    let extra: Record<string, unknown> | undefined;
    try {
      if (runtime.getStatus)
        extra = (await runtime.getStatus()) as Record<string, unknown>;
    } catch (err) {
      extra = { statusError: err instanceof Error ? err.message : "unknown" };
    }
    modules.push({
      name,
      config: readModuleConfig(p, runtime.def),
      ...(extra ? { extra } : {}),
    });
  }
  const snap = store.snapshot();
  return {
    online: true,
    at: new Date().toISOString(),
    osUptime: fmtUptime(osUptime()),
    piUptime: fmtUptime(process.uptime()),
    node: process.version,
    pi: piVersion ?? "unknown",
    piTelegram: piTelegramVersion(),
    memory: {
      totalMb,
      freeMb,
      usedPct: Math.round(((totalMb - freeMb) / Math.max(1, totalMb)) * 100),
    },
    load: loadavg().map((n) => Math.round(n * 100) / 100),
    pm2: pm2.map((svc) => {
      const pm2Env = svc["pm2_env"] as Record<string, unknown> | undefined;
      const created =
        typeof pm2Env?.["created_at"] === "number"
          ? (pm2Env["created_at"] as number)
          : Date.now();
      const status =
        typeof pm2Env?.["status"] === "string"
          ? (pm2Env["status"] as string)
          : "unknown";
      const monit = svc["monit"] as Record<string, unknown> | undefined;
      return {
        name: String(svc["name"] ?? "?"),
        status,
        cpu: monit?.["cpu"] ?? null,
        memory: monit?.["memory"] ?? null,
        uptime: fmtUptime(Math.max(0, (Date.now() - created) / 1000)),
      };
    }),
    modules,
    lastRemoteUpdate: snap.lastRemoteUpdate ?? null,
    lastError: snap.lastError ?? null,
  };
}

function statusText(s: ServerStatus): string {
  const lines = [
    "🟢 server online",
    `os uptime: ${s.osUptime} | pi uptime: ${s.piUptime}`,
    `node ${s.node} | pi ${s.pi} | pi-telegram ${s.piTelegram}`,
    `mem: ${s.memory.usedPct}% used (${s.memory.freeMb}/${s.memory.totalMb} MB free) | load: ${s.load.join(" ")}`,
    `pm2: ${s.pm2.length > 0 ? s.pm2.map((x) => `${x.name}=${x.status}`).join(", ") : "unavailable"}`,
    `modules: ${s.modules.map((m) => `${m.name} ${JSON.stringify(m.config)}`).join(" | ")}`,
  ];
  return lines.join("\n");
}

/* ------------------------------------------------------------------ */
/* Remote update handling (single-polling safe)                        */
/* ------------------------------------------------------------------ */

type TelegramUpdateHandler = (
  update: unknown,
  execution?: { signal: AbortSignal },
) => "consume" | "pass" | void | Promise<"consume" | "pass" | void>;

const REGISTRY_KEY = "__piTelegramUpdateHandlerRegistry__";

/** Zero-coupling attach to pi-telegram's public update registry (any load order). */
function attachUpdateHandler(handler: TelegramUpdateHandler): void {
  const g = globalThis as Record<string, unknown>;
  const existing = g[REGISTRY_KEY] as
    | { version?: unknown; add?: unknown }
    | undefined;
  if (
    existing &&
    existing.version === 1 &&
    typeof existing.add === "function"
  ) {
    (existing.add as (h: TelegramUpdateHandler) => void)(handler);
    return;
  }
  // pi-telegram not loaded (yet): create the full v1 contract so its runtime
  // adopts our registry instead of replacing it (see pi-telegram docs/updates.md).
  const handlers = new Set<TelegramUpdateHandler>();
  const registryObj = {
    version: 1 as const,
    add(h: TelegramUpdateHandler) {
      handlers.add(h);
      return () => {
        handlers.delete(h);
      };
    },
    async dispatch(update: unknown, execution?: { signal: AbortSignal }) {
      for (const h of handlers) {
        try {
          const r = await h(update, execution);
          if (r === "consume") return "consume" as const;
        } catch {
          // never break polling because of a handler error
        }
      }
      return "pass" as const;
    },
  };
  g[REGISTRY_KEY] = registryObj;
  registryObj.add(handler);
}

interface InboundMeta {
  text: string;
  fromId: number;
  chatId: number;
  messageId: number;
}

function extractInbound(update: unknown): InboundMeta | null {
  if (typeof update !== "object" || update === null) return null;
  const msg = (update as Record<string, unknown>)["message"];
  if (typeof msg !== "object" || msg === null) return null;
  const m = msg as Record<string, unknown>;
  if (typeof m["text"] !== "string") return null;
  const from = m["from"] as Record<string, unknown> | undefined;
  const chat = m["chat"] as Record<string, unknown> | undefined;
  if (
    typeof from?.["id"] !== "number" ||
    typeof chat?.["id"] !== "number" ||
    typeof m["message_id"] !== "number"
  )
    return null;
  return {
    text: m["text"] as string,
    fromId: from["id"] as number,
    chatId: chat["id"] as number,
    messageId: m["message_id"] as number,
  };
}

// Reload guard: jiti /reload re-runs this module; the old handler stays in the
// globalThis set, so stale generations must no-op instead of double-handling.
function currentGeneration(): number {
  const g = globalThis as unknown as Record<string, number | undefined>;
  g["__piRemoteConfigGen"] = (g["__piRemoteConfigGen"] ?? 0) + 1;
  return g["__piRemoteConfigGen"] as number;
}
function isCurrentGeneration(gen: number): boolean {
  return (
    (globalThis as unknown as Record<string, number | undefined>)[
      "__piRemoteConfigGen"
    ] === gen
  );
}

interface OpContext {
  p: Paths;
  auth: RemoteAuth;
  hmac: string;
  token: string | null;
  store: ReplayStore;
  inbound: InboundMeta;
}

async function respond(
  ctx: OpContext,
  payload: {
    requestId?: string;
    ok: boolean;
    body?: unknown;
    error?: string;
    message?: string;
  },
): Promise<void> {
  if (!ctx.token) {
    ctx.store.recordError("respond", "no_server_bot_token");
    return;
  }
  const wire = encodeResponse(
    {
      requestId: payload.requestId,
      ok: payload.ok,
      body: payload.body,
      error: payload.error,
      message: payload.message,
    },
    ctx.hmac,
  );
  const sent = await sendTelegram(
    ctx.token,
    ctx.inbound.chatId,
    wire,
    ctx.inbound.messageId,
  );
  if (!sent) ctx.store.recordError("respond", "sendMessage_failed");
}

async function handleVerifiedOp(
  ctx: OpContext,
  env: Record<string, unknown>,
): Promise<void> {
  const op = env["op"] as RemoteOp;
  const requestId =
    typeof env["requestId"] === "string"
      ? (env["requestId"] as string)
      : undefined;
  const now = Math.floor(Date.now() / 1000);

  if (op === "ping") {
    ctx.store.recordUpdate({ at: now, op, ok: true });
    await respond(ctx, {
      requestId,
      ok: true,
      body: { pong: true },
      message: "pong",
    });
    return;
  }
  if (op === "get_status") {
    try {
      const status = await collectStatus(ctx.p, ctx.store);
      ctx.store.recordUpdate({ at: now, op, ok: true });
      await respond(ctx, {
        requestId,
        ok: true,
        body: status,
        message: statusText(status),
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : "status_failed";
      ctx.store.recordUpdate({ at: now, op, ok: false, error: message });
      await respond(ctx, {
        requestId,
        ok: false,
        error: "status_failed",
        message,
      });
    }
    return;
  }

  // Mutating ops honor the core master switches.
  const core = registry.get("core");
  const coreCfg = core
    ? readModuleConfig(ctx.p, core.def)
    : { remoteControlEnabled: true, maintenanceMode: false };
  if (coreCfg["remoteControlEnabled"] === false) {
    ctx.store.recordUpdate({
      at: now,
      op,
      ok: false,
      error: "remote_disabled",
    });
    await respond(ctx, {
      requestId,
      ok: false,
      error: "remote_disabled",
      message: "Remote control is disabled (core.remoteControlEnabled=false).",
    });
    return;
  }
  if (coreCfg["maintenanceMode"] === true) {
    ctx.store.recordUpdate({ at: now, op, ok: false, error: "maintenance" });
    await respond(ctx, {
      requestId,
      ok: false,
      error: "maintenance",
      message: "Server is in maintenance mode.",
    });
    return;
  }

  if (op === "set_config") {
    const module = env["module"];
    if (!isValidModuleName(module) || !registry.has(module)) {
      ctx.store.recordUpdate({
        at: now,
        op,
        module: typeof module === "string" ? module : "?",
        ok: false,
        error: "unknown_module",
      });
      await respond(ctx, {
        requestId,
        ok: false,
        error: "unknown_module",
        message: `Unknown module. Registered: ${[...registry.keys()].join(", ")}`,
      });
      return;
    }
    try {
      const { config } = applyModulePatch(ctx.p, module, env["patch"]);
      const runtime = registry.get(module);
      try {
        await runtime?.onConfigApplied?.(config);
      } catch (err) {
        ctx.store.recordError(
          "onConfigApplied",
          err instanceof Error ? err.message : "hook_failed",
        );
      }
      ctx.store.recordUpdate({ at: now, op, module, ok: true });
      await respond(ctx, {
        requestId,
        ok: true,
        body: { module, config },
        message: `✅ ${module} updated: ${JSON.stringify(config)}`,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : "apply_failed";
      ctx.store.recordUpdate({
        at: now,
        op,
        module,
        ok: false,
        error: message,
      });
      await respond(ctx, {
        requestId,
        ok: false,
        error: "invalid_patch",
        message: `Refused: ${message}`,
      });
    }
    return;
  }

  if (op === "service") {
    const service = env["service"];
    const action = env["action"];
    if (
      typeof service !== "string" ||
      !(ctx.auth.allowedServices ?? []).includes(service)
    ) {
      ctx.store.recordUpdate({
        at: now,
        op,
        ok: false,
        error: "service_not_allowed",
      });
      await respond(ctx, {
        requestId,
        ok: false,
        error: "service_not_allowed",
        message: `Service not allowed. Allowed: ${(ctx.auth.allowedServices ?? []).join(", ")}`,
      });
      return;
    }
    if (action === "status") {
      const list = await pm2List();
      const found = list.find((s) => String(s["name"]) === service);
      const pm2Env = found?.["pm2_env"] as Record<string, unknown> | undefined;
      const status =
        typeof pm2Env?.["status"] === "string" ? pm2Env["status"] : "unknown";
      ctx.store.recordUpdate({ at: now, op, ok: true });
      await respond(ctx, {
        requestId,
        ok: true,
        body: { service, status },
        message: `${service}: ${status}`,
      });
      return;
    }
    if (action === "restart") {
      const out = await runCmd("pm2", ["restart", service], 30000);
      const ok = out !== null;
      ctx.store.recordUpdate({
        at: now,
        op,
        ok,
        error: ok ? undefined : "restart_failed",
      });
      await respond(ctx, {
        requestId,
        ok,
        body: { service, restarted: ok },
        error: ok ? undefined : "restart_failed",
        message: ok
          ? `🔄 ${service} restart requested`
          : `Restart of ${service} failed`,
      });
      return;
    }
    ctx.store.recordUpdate({ at: now, op, ok: false, error: "bad_action" });
    await respond(ctx, {
      requestId,
      ok: false,
      error: "bad_action",
      message: "Action must be status|restart.",
    });
    return;
  }

  ctx.store.recordUpdate({
    at: now,
    op: String(env["op"]),
    ok: false,
    error: "bad_op",
  });
  await respond(ctx, {
    requestId,
    ok: false,
    error: "bad_op",
    message: "Unknown operation.",
  });
}

function makeRemoteHandler(gen: number): TelegramUpdateHandler {
  return async (update) => {
    if (!isCurrentGeneration(gen)) return "pass";
    const inbound = extractInbound(update);
    if (!inbound) return "pass";
    if (!inbound.text.startsWith(REMOTE_PREFIX + " ")) return "pass";

    // From here on: ALWAYS consume. An invalid prefixed message must never
    // become a normal LLM prompt.
    try {
      const p = paths();
      const auth = loadAuth(p);
      const hmac = readSecretFile(p.hmacFile);
      if (!auth || !hmac) {
        // Configured later via setup; swallow quietly (no token to reply with).
        return "consume";
      }
      const store = new ReplayStore(
        p.stateFile,
        (auth.maxSkewSeconds ?? 300) * 2,
      );
      const token = loadServerBotToken(p);
      const ctx: OpContext = { p, auth, hmac, token, store, inbound };

      if (inbound.fromId !== auth.allowedControlBotId) {
        store.recordUpdate({
          at: Math.floor(Date.now() / 1000),
          op: "rejected",
          ok: false,
          error: "bad_sender",
        });
        return "consume"; // silent: do not confirm anything to strangers
      }
      if (
        auth.controlChatId !== undefined &&
        inbound.chatId !== auth.controlChatId
      ) {
        store.recordUpdate({
          at: Math.floor(Date.now() / 1000),
          op: "rejected",
          ok: false,
          error: "bad_chat",
        });
        return "consume";
      }

      const verified = verifySignedText(inbound.text, REMOTE_PREFIX, {
        secret: hmac,
        maxSkewSeconds: auth.maxSkewSeconds ?? 300,
      });
      if (!verified.ok) {
        store.recordUpdate({
          at: Math.floor(Date.now() / 1000),
          op: "rejected",
          ok: false,
          error: verified.error,
        });
        await respond(ctx, {
          ok: false,
          error: verified.error,
          message: `Remote message rejected: ${verified.error}`,
        });
        return "consume";
      }
      const env = verified.payload;
      const now = Math.floor(Date.now() / 1000);
      const nonce = env["nonce"] as string;
      if (store.has(nonce, now)) {
        store.recordUpdate({
          at: now,
          op: "rejected",
          ok: false,
          error: "replay",
        });
        await respond(ctx, {
          requestId:
            typeof env["requestId"] === "string" ? env["requestId"] : undefined,
          ok: false,
          error: "replay",
          message: "Duplicate message (replay). Ignored.",
        });
        return "consume";
      }
      store.add(nonce, env["ts"] as number, now);

      if (!isRemoteOp(env["op"])) {
        store.recordUpdate({
          at: now,
          op: "rejected",
          ok: false,
          error: "bad_op",
        });
        await respond(ctx, {
          requestId:
            typeof env["requestId"] === "string" ? env["requestId"] : undefined,
          ok: false,
          error: "bad_op",
          message: "Unknown operation.",
        });
        return "consume";
      }
      await handleVerifiedOp(ctx, env);
    } catch (err) {
      try {
        const p = paths();
        new ReplayStore(p.stateFile, 600).recordError(
          "remote_handler",
          err instanceof Error ? err.message : "unknown",
        );
      } catch {
        // last resort: never throw out of a Telegram handler
      }
    }
    return "consume";
  };
}

/* ------------------------------------------------------------------ */
/* Extension entry                                                     */
/* ------------------------------------------------------------------ */

// Uniform tool result: keeps details structurally open so every branch typechecks.
interface TextResult {
  content: Array<{ type: "text"; text: string }>;
  details: Record<string, unknown>;
}
const PatchSchema = Type.Record(
  Type.String(),
  Type.Union([Type.String(), Type.Number(), Type.Boolean()]),
);

export default function remoteConfigExtension(pi: ExtensionAPI): void {
  const gen = currentGeneration();
  for (const def of BUILTIN_MODULES) {
    if (!registry.has(def.name)) registerRemoteModule({ def });
  }
  attachUpdateHandler(makeRemoteHandler(gen));

  pi.on("session_start", async (_event, ctx) => {
    try {
      const p = paths();
      ensureDir(p.configDir, 0o700);
      for (const runtime of registry.values()) {
        const file = configPathFor(p, runtime.def);
        if (!existsSync(file))
          atomicWriteJson(file, runtime.def.defaults, 0o600);
      }
      ctx.ui.notify(
        `${LOG} ${registry.size} module(s): ${[...registry.keys()].join(", ")}`,
        "info",
      );
    } catch (err) {
      ctx.ui.notify(
        `${LOG} init failed: ${err instanceof Error ? err.message : "unknown"}`,
        "error",
      );
    }
  });

  pi.registerTool({
    name: "server_config",
    label: "Server Config",
    description:
      "Inspect or change whitelisted settings of registered server modules (e.g. core, example-monitor). " +
      "Actions: list (show modules + current values), get (one module), set (apply a patch of KNOWN fields only; unknown fields, wrong types and out-of-range values are rejected).",
    promptSnippet:
      "server_config lists/gets/sets whitelisted module settings on this server node",
    promptGuidelines: [
      "Use server_config when the user asks to change a server/module setting, enable/disable a module, or inspect current values.",
      "Never invent file paths or shell commands: only module + patch fields declared by the registry are allowed.",
    ],
    parameters: Type.Object({
      action: Type.Union(
        [Type.Literal("list"), Type.Literal("get"), Type.Literal("set")],
        { description: "list modules, get one module config, or set fields" },
      ),
      module: Type.Optional(
        Type.String({
          description: "Module name, e.g. core or example-monitor",
        }),
      ),
      patch: Type.Optional(PatchSchema),
    }),
    async execute(_toolCallId, params): Promise<TextResult> {
      const p = paths();
      const action = params.action as "list" | "get" | "set";
      if (action === "list") {
        const mods = [...registry.values()].map((r) => ({
          name: r.def.name,
          description: r.def.description,
          config: readModuleConfig(p, r.def),
          fields: r.def.schema,
        }));
        return {
          content: [
            {
              type: "text",
              text: mods
                .map(
                  (m) =>
                    `${m.name}: ${JSON.stringify(m.config)} — ${m.description}`,
                )
                .join("\n"),
            },
          ],
          details: { modules: mods },
        };
      }
      const name = params.module as string | undefined;
      if (!name || !registry.has(name)) {
        return {
          content: [
            {
              type: "text",
              text: `Unknown module. Registered: ${[...registry.keys()].join(", ")}`,
            },
          ],
          details: { error: "unknown_module" },
        };
      }
      if (action === "get") {
        const runtime = registry.get(name);
        const config = runtime ? readModuleConfig(p, runtime.def) : {};
        return {
          content: [
            { type: "text", text: `${name}: ${JSON.stringify(config)}` },
          ],
          details: { module: name, config },
        };
      }
      try {
        const { config, backup } = applyModulePatch(p, name, params.patch);
        try {
          await registry.get(name)?.onConfigApplied?.(config);
        } catch (err) {
          return {
            content: [
              {
                type: "text",
                text: `${name} saved but reload hook failed: ${err instanceof Error ? err.message : "unknown"}`,
              },
            ],
            details: { module: name, config, hookError: true },
          };
        }
        return {
          content: [
            {
              type: "text",
              text: `✅ ${name} updated: ${JSON.stringify(config)}${backup ? ` (backup: ${backup})` : ""}`,
            },
          ],
          details: { module: name, config, backup },
        };
      } catch (err) {
        const message = err instanceof Error ? err.message : "apply_failed";
        return {
          content: [{ type: "text", text: `Refused: ${message}` }],
          details: { error: message },
        };
      }
    },
  });

  pi.registerTool({
    name: "server_status",
    label: "Server Status",
    description:
      "Report this server node's health: online state, OS/Pi uptime, Node/Pi/pi-telegram versions, PM2 processes, memory, registered modules with their essential config, last remote update and last known error. Use it when the user asks how the server is doing.",
    promptSnippet:
      "server_status reports this node health: uptime, versions, PM2, memory, modules, last remote update",
    promptGuidelines: [
      "Use server_status for any 'how is the server / stato server / are services running' question before answering from memory.",
    ],
    parameters: Type.Object({}),
    async execute(): Promise<TextResult> {
      const p = paths();
      const store = new ReplayStore(p.stateFile, 600);
      try {
        const status = await collectStatus(p, store);
        return {
          content: [{ type: "text", text: statusText(status) }],
          details: { status },
        };
      } catch (err) {
        return {
          content: [
            {
              type: "text",
              text: `Status collection failed: ${err instanceof Error ? err.message : "unknown"}`,
            },
          ],
          details: { error: true },
        };
      }
    },
  });

  pi.registerTool({
    name: "service_control",
    label: "Service Control",
    description:
      "Query or restart an explicitly allowed local service via PM2 (e.g. pi-server). Actions: status, restart. Only service names listed in remote-auth.json allowedServices are accepted; anything else is refused. This is NOT a shell: no commands, paths or scripts can be passed.",
    promptSnippet:
      "service_control checks/restarts explicitly allowed PM2 services only",
    promptGuidelines: [
      "Use service_control when the user asks to restart or check a server service. Never use bash for restarts when this tool applies.",
    ],
    parameters: Type.Object({
      service: Type.String({ description: "Service name, e.g. pi-server" }),
      action: Type.Union([Type.Literal("status"), Type.Literal("restart")], {
        description: "status or restart",
      }),
    }),
    async execute(_toolCallId, params): Promise<TextResult> {
      const p = paths();
      const auth = loadAuth(p);
      const allowed = auth?.allowedServices ?? ["pi-server"];
      const service = params.service as string;
      const action = params.action as "status" | "restart";
      if (!allowed.includes(service)) {
        return {
          content: [
            {
              type: "text",
              text: `Refused: service not allowed. Allowed: ${allowed.join(", ")}`,
            },
          ],
          details: { error: "service_not_allowed" },
        };
      }
      if (action === "status") {
        const list = await pm2List();
        const found = list.find((s) => String(s["name"]) === service);
        const pm2Env = found?.["pm2_env"] as
          | Record<string, unknown>
          | undefined;
        const status =
          typeof pm2Env?.["status"] === "string"
            ? pm2Env["status"]
            : "unknown/not-running";
        return {
          content: [{ type: "text", text: `${service}: ${status}` }],
          details: { service, status },
        };
      }
      const out = await runCmd("pm2", ["restart", service], 30000);
      if (out === null)
        return {
          content: [
            { type: "text", text: `Restart of ${service} failed (pm2 error).` },
          ],
          details: { error: "restart_failed" },
        };
      return {
        content: [{ type: "text", text: `🔄 ${service} restart requested.` }],
        details: { service, restarted: true },
      };
    },
  });
}
