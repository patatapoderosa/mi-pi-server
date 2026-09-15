/**
 * pi-remote-config — server-side Pi extension (old PC, 24/7 node).
 *
 * Local tools for the on-server agent (used from the phone via ServerBot):
 * server_config / server_status / service_control.
 * Config writes only touch WHITELISTED fields of REGISTERED modules.
 * There is deliberately NO remote shell, NO arbitrary paths, NO exec tool.
 *
 * Remote control from the Mac does NOT go through Telegram anymore: it is
 * served by the standalone pi-remote-server HTTP daemon (server/
 * pi-remote-server/) over the tailnet. This extension shares the module
 * registry model (shared/modules.ts), the config files, and the replay-state
 * file with that daemon — so the phone and the Mac always see the same
 * truth — but this file never opens sockets and never polls Telegram.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { execFile, spawn } from "node:child_process";
import { createRequire } from "node:module";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { freemem, loadavg, totalmem, uptime as osUptime } from "node:os";
import { hostname as osHostname } from "node:os";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { promisify } from "node:util";
import {
  BUILTIN_MODULES,
  applyModulePatchFile,
  configPathFor,
  enabledOf,
  isValidModuleName,
  readModuleConfigFile,
  type ModuleRuntime,
  type PatchValue,
} from "../../shared/modules.ts";
import {
  ReplayStore,
  atomicWriteJson,
  ensureDir,
  readJsonFile,
  resolveAgentDir,
} from "../../shared/store.ts";
import { readAppVersion } from "../pi-remote-server/server.ts";
import {
  buildDoctorArgv,
  buildUpdaterArgv,
  checkLatestRelease,
  downloadRelease,
  isReleaseVersion,
  isRepairGroup,
  isTerminalPhase,
  isUpdateAction,
  listInstalledReleases,
  piServerRoot,
  readActivePointer,
  readDoctorReport,
  readHistoryTail,
  readUpdateState,
  resolveReleaseDir,
  v3Available,
} from "../pi-remote-server/update.ts";
import { buildPiSpawn } from "../spawn-pi.mjs";
import {
  isValidThinkingLevel,
  normalizeSelection,
  parseListModelsTable,
  readConfiguredDefault,
  writeConfiguredDefault,
  type PiModelInfo,
} from "../../shared/pi-model.ts";

const execFileAsync = promisify(execFile);
const LOG = "[remote-config]";

/* ------------------------------------------------------------------ */
/* Paths & config                                                      */
/* ------------------------------------------------------------------ */

interface Paths {
  agentDir: string;
  configDir: string;
  stateFile: string;
}

function paths(): Paths {
  const agentDir = resolveAgentDir();
  return {
    agentDir,
    configDir: join(agentDir, "server-config"),
    stateFile: join(agentDir, "remote-state.json"),
  };
}

/** Service allowlist for service_control (remote-server.json, same file the daemon reads). */
function loadAllowedServices(p: Paths): string[] {
  const raw = readJsonFile<{ allowedServices?: unknown }>(
    join(p.agentDir, "remote-server.json"),
    {},
  );
  if (!Array.isArray(raw.allowedServices)) return ["pi-server"];
  const list = raw.allowedServices.filter(
    (s): s is string => typeof s === "string",
  );
  return list.length > 0 ? list : ["pi-server"];
}

/* ------------------------------------------------------------------ */
/* Module registry                                                     */
/* ------------------------------------------------------------------ */

const registry = new Map<string, ModuleRuntime>();

/**
 * Registration API for new modules (in-process companions):
 *   registerRemoteModule({
 *     name: "...",            // via def.name
 *     schema: ...,            // via def.schema
 *     getStatus: ...,         // extra status rows (optional)
 *     applyConfig: ...,       // via onConfigApplied(config)
 *     enable: ... / disable: ...  // via onEnabledChange(enabled, config)
 *   })
 * As registerRemoteModule({ def: {...}, onConfigApplied, onEnabledChange,
 * getStatus }). The definition alone determines what can be changed.
 */
export function registerRemoteModule(runtime: ModuleRuntime): void {
  const def = runtime.def;
  if (!isValidModuleName(def.name))
    throw new Error(`[remote-config] invalid module name: ${String(def.name)}`);
  if (typeof def.schema !== "object" || def.schema === null || Object.keys(def.schema).length === 0) {
    throw new Error(
      `[remote-config] module ${def.name} must declare a non-empty schema`,
    );
  }
  registry.set(def.name, runtime);
}

export type { ModuleRuntime };

/** Validate + backup + atomically write a module config. Returns backup path (if any). */
export function applyModulePatch(
  p: Paths,
  name: string,
  patch: unknown,
): { config: Record<string, PatchValue>; backup: string | null } {
  const runtime = registry.get(name);
  if (!runtime) throw new Error(`unknown_module:${name}`);
  return applyModulePatchFile(p.configDir, runtime.def, patch);
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
  hostname: string;
  appVersion: string;
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
    enabled: boolean | null;
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
    const config = readModuleConfigFile(p.configDir, runtime.def);
    modules.push({
      name,
      config,
      enabled: enabledOf(runtime.def, config),
      ...(extra ? { extra } : {}),
    });
  }
  const snap = store.snapshot();
  return {
    online: true,
    at: new Date().toISOString(),
    hostname: osHostname(),
    appVersion: readAppVersion(join(resolveAgentDir(), "..", "app")),
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
    `host ${s.hostname} | app ${s.appVersion}`,
    `os uptime: ${s.osUptime} | pi uptime: ${s.piUptime}`,
    `node ${s.node} | pi ${s.pi} | pi-telegram ${s.piTelegram}`,
    `mem: ${s.memory.usedPct}% used (${s.memory.freeMb}/${s.memory.totalMb} MB free) | load: ${s.load.join(" ")}`,
    `pm2: ${s.pm2.length > 0 ? s.pm2.map((x) => `${x.name}=${x.status}`).join(", ") : "unavailable"}`,
    `modules: ${s.modules.map((m) => `${m.name} ${JSON.stringify(m.config)}`).join(" | ")}`,
  ];
  return lines.join("\n");
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

async function runEnabledHook(
  name: string,
  enabled: boolean,
  config: Record<string, PatchValue>,
): Promise<string | null> {
  try {
    await registry.get(name)?.onEnabledChange?.(enabled, config);
    return null;
  } catch (err) {
    return err instanceof Error ? err.message : "hook_failed";
  }
}

export default function remoteConfigExtension(pi: ExtensionAPI): void {
  for (const def of BUILTIN_MODULES) {
    if (!registry.has(def.name)) registerRemoteModule({ def });
  }

  pi.on("session_start", async (_event, ctx) => {
    try {
      const p = paths();
      ensureDir(p.configDir, 0o700);
      for (const runtime of registry.values()) {
        const file = configPathFor(p.configDir, runtime.def);
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
      "Actions: list (show modules + current values), get (one module), set (apply a patch of KNOWN fields only; unknown fields, wrong types and out-of-range values are rejected). " +
      "To enable/disable a module, set its \"enabled\" field (e.g. {enabled:false}).",
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
        const mods = [...registry.values()].map((r) => {
          const config = readModuleConfigFile(p.configDir, r.def);
          return {
            name: r.def.name,
            description: r.def.description,
            config,
            enabled: enabledOf(r.def, config),
            fields: r.def.schema,
          };
        });
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
      const runtime = registry.get(name);
      if (action === "get") {
        const config = runtime
          ? readModuleConfigFile(join(p.configDir), runtime.def)
          : {};
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
        const patchObj = (params.patch ?? {}) as Record<string, unknown>;
        if (
          typeof patchObj["enabled"] === "boolean" &&
          runtime?.def.schema["enabled"]?.type === "boolean"
        ) {
          const hookErr = await runEnabledHook(
            name,
            patchObj["enabled"] as boolean,
            config,
          );
          if (hookErr) {
            return {
              content: [
                {
                  type: "text",
                  text: `${name} saved but enable/disable hook failed: ${hookErr}`,
                },
              ],
              details: { module: name, config, hookError: true },
            };
          }
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
      "Report this server node's health: online state, hostname, uptimes, Node/Pi/pi-telegram versions, memory, registered modules with their essential config, last remote request and last known error. Use it when the user asks how the server is doing.",
    promptSnippet:
      "server_status reports this node health: uptime, versions, memory, modules, last remote request",
    promptGuidelines: [
      "Use server_status for any 'how is the server / server status / are services running' question before answering from memory.",
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
      "Query or restart an explicitly allowed local service via PM2 (e.g. pi-server). Actions: status, restart. Only service names listed in remote-server.json allowedServices are accepted; anything else is refused. This is NOT a shell: no commands, paths or scripts can be passed.",
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
      const allowed = loadAllowedServices(p);
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
        content: [
          { type: "text", text: `🔄 ${service} restart requested.` },
        ],
        details: { service, restarted: true },
      };
    },
  });
  pi.registerTool({
    name: "server_model",
    label: "Server Model",
    description:
      "Inspect or change THIS server node's Pi startup default model (settings.json defaultProvider/defaultModel). " +
      "Actions: get (configured default + source), list (live Pi catalog with per-provider auth), " +
      "set (validate against live catalog + backup + atomic write; applies at next Pi start), " +
      "validate (dry run, nothing written). Unknown/ambiguous/unauthenticated models are refused.",
    promptSnippet:
      "server_model gets/lists/sets/validates this node Pi startup default model",
    promptGuidelines: [
      "Use server_model when the user asks which model this server uses, what models are available here, or wants to change the default.",
      "After set, always report that a restart is needed to apply (live session keeps its boot-time model).",
    ],
    parameters: Type.Object({
      action: Type.Union(
        [
          Type.Literal("get"),
          Type.Literal("list"),
          Type.Literal("set"),
          Type.Literal("validate"),
        ],
        { description: "get default, list catalog, set default, or dry-run validate" },
      ),
      provider: Type.Optional(Type.String({ description: "Provider id, e.g. openai" })),
      model: Type.Optional(Type.String({ description: "Model id, e.g. gpt-5.5 (exact id as listed)" })),
      thinkingLevel: Type.Optional(Type.String({ description: "Startup thinking level (set only)" })),
      applyNow: Type.Optional(Type.Boolean({ description: "Record intent to apply immediately (still needs a restart)" })),
    }),
    async execute(_toolCallId, params): Promise<TextResult> {
      const p = paths();
      const action = params.action as "get" | "list" | "set" | "validate";
      const fail = (text: string, error: unknown): TextResult => ({
        content: [{ type: "text", text }],
        details: { error },
      });
      if (action === "get") {
        try {
          const cfg = readConfiguredDefault(p.agentDir);
          const text = cfg.provider
            ? `🤖 startup default: ${cfg.provider}/${cfg.model} (thinking: ${cfg.thinkingLevel ?? "(Pi default)"}, source: ${cfg.source}). Takes effect at next Pi start; live session keeps its boot-time model.`
            : "🤖 no default model configured (Pi falls back to first available at startup).";
          return { content: [{ type: "text", text }], details: { ...cfg } };
        } catch (err) {
          return fail(`Refused: ${err instanceof Error ? err.message : "read_failed"}`, "settings_unreadable");
        }
      }
      if (action === "list") {
        const cat = await modelCatalogHere(p.agentDir);
        if (!cat.ok) return fail(`Refused: ${cat.message}`, cat.error);
        if (cat.models.length === 0) {
          return { content: [{ type: "text", text: "🤖 no available models (no logins on this server?)." }], details: { models: [] } };
        }
        const authed = await authedProvidersHere(p.agentDir, cat.models);
        const lines = cat.models.slice(0, 100).map((m) => {
          const ok = authed.includes(m.provider);
          return `- ${ok ? "✅" : "🔒"} ${m.provider}/${m.id}${m.thinking ? " (thinking)" : ""}`;
        });
        return {
          content: [{ type: "text", text: lines.join("\n") }],
          details: { models: cat.models.slice(0, 100).map((m) => ({ ...m, authenticated: authed.includes(m.provider) })) },
        };
      }
      const model = typeof params.model === "string" ? params.model.trim() : "";
      if (model.length === 0) {
        return fail(`Refused: model_required`, "model_required");
      }
      const provider = typeof params.provider === "string" ? params.provider.trim() : undefined;
      const thinkingRaw = params.thinkingLevel as unknown;
      if (thinkingRaw !== undefined && thinkingRaw !== null && !isValidThinkingLevel(thinkingRaw)) {
        return fail(`Refused: invalid_thinking_level`, "invalid_thinking_level");
      }
      const cat = await modelCatalogHere(p.agentDir);
      if (!cat.ok) return fail(`Refused: ${cat.message}`, cat.error);
      const authed = await authedProvidersHere(p.agentDir, cat.models);
      const norm = normalizeSelection({ provider, model }, cat.models, authed);
      if (!norm.ok) return fail(`Refused: ${norm.error}`, norm.error.split(":")[0]);
      if (!authed.includes(norm.provider)) {
        return fail(`Refused: provider_not_authenticated (${norm.provider} has no ready auth)`, "provider_not_authenticated");
      }
      if (action === "validate") {
        return {
          content: [{ type: "text", text: `✅ ${norm.provider}/${norm.model} is available and authenticated (dry run, nothing written).` }],
          details: { valid: true, provider: norm.provider, model: norm.model },
        };
      }
      try {
        const { backup } = writeConfiguredDefault(p.agentDir, {
          provider: norm.provider,
          model: norm.model,
          thinkingLevel: typeof thinkingRaw === "string" ? (thinkingRaw as string) : null,
        });
        const applyNow = params.applyNow === true;
        return {
          content: [{ type: "text", text: `✅ server default is now ${norm.provider}/${norm.model}.${applyNow ? " Restart the PiHomeServer task to apply now." : " Applies at next Pi start."}${backup ? ` (backup: ${backup})` : ""}` }],
          details: { provider: norm.provider, model: norm.model, backup, requiresRestart: true, applied: false },
        };
      } catch (err) {
        return fail(`Refused: ${err instanceof Error ? err.message : "write_failed"}`, "settings_write_failed");
      }
    },
  });

  pi.registerTool({
    name: "server_doctor",
    label: "Server Doctor",
    description:
      "Check THIS server node: structured diagnostics (active release, tasks, " +
      "processes, listener, Tailscale, update transaction) with healthy/degraded/" +
      "unhealthy status. Use when the user asks to check the server. With " +
      "repair:true it also applies safe allowlisted self-heal behind a circuit " +
      "breaker (MEDIUM risk). Read-only by default.",
    promptSnippet:
      "server_doctor reads node diagnostics (and optionally repairs)",
    promptGuidelines: [
      "Use server_doctor when the user asks to check the server; report the status and failing checks.",
      "After repair, report what was repaired and the verify status.",
    ],
    parameters: Type.Object({
      fresh: Type.Optional(Type.Boolean({ description: "Regenerate live (default cached report)" })),
      repair: Type.Optional(Type.Boolean({ description: "Run allowlisted self-heal (MEDIUM risk)" })),
      only: Type.Optional(Type.Array(Type.String(), { description: "Repair groups subset" })),
    }),
    async execute(_toolCallId, params): Promise<TextResult> {
      const p = paths();
      const root = piServerRoot(p.agentDir);
      const fail = (text: string, error: unknown): TextResult => ({
        content: [{ type: "text", text }],
        details: { error },
      });
      if (!v3Available(root)) {
        return fail("Refused: pointer releases not installed (pre-v0.3.0 layout).", "v3_unavailable");
      }
      const repair = params.repair === true;
      const fresh = params.fresh === true;
      if (!repair && !fresh) {
        const rep = readDoctorReport(root);
        if (!rep.ok) return fail(`Refused: ${rep.error}. Run with fresh:true first.`, rep.error);
        return { content: [{ type: "text", text: formatDoctorText(rep.status, rep.checks, null) }], details: { status: rep.status, checks: rep.checks } };
      }
      const onlyRaw = params.only === undefined ? null : params.only;
      if (onlyRaw !== null && !repair) {
        return fail("Refused: `only` needs repair:true.", "only_without_repair");
      }
      if (onlyRaw !== null && !(Array.isArray(onlyRaw) && onlyRaw.every((g) => isRepairGroup(g)))) {
        return fail("Refused: unknown repair group.", "bad_repair_group");
      }
      const spec = buildDoctorArgv(root, repair, onlyRaw);
      if (!spec.ok) return fail(`Refused: ${spec.error}.`, spec.error);
      const out = await runJsonCmd(spec.command, spec.args, 120000);
      if (out === null) return fail("Doctor produced no JSON (spawn failed or timed out).", "doctor_failed");
      const body = out as { status?: unknown; checks?: unknown; repaired?: unknown; detail?: unknown };
      const checks = Array.isArray(body["checks"]) ? body["checks"] : [];
      const repaired = Array.isArray(body["repaired"]) ? (body["repaired"] as unknown[]) : null;
      const detail = typeof body["detail"] === "string" ? body["detail"] : null;
      const status = typeof body["status"] === "string" ? body["status"] : "unknown";
      const head = repaired === null ? `status: ${status}` : `repaired: ${(repaired as unknown[]).join(", ") || "(nothing)"}`;
      const tail = detail ?? "";
      return {
        content: [{ type: "text", text: [head, formatDoctorChecks(checks), tail].filter((s) => s !== "").join("\n") }],
        details: { status, checks, repaired },
      };
    },
  });

  pi.registerTool({
    name: "server_update",
    label: "Server Update",
    description:
      "Manage releases on THIS server node: check (installed vs latest), plan " +
      "(dry-run risks for a version), apply (download, pointer-switch, verify, " +
      "auto-rollback), status (transaction + active release), rollback (previous " +
      "validated release), recover (finish interrupted update). apply/rollback " +
      "are MEDIUM risk. Versions come only from fixed GitHub releases.",
    promptSnippet:
      "server_update manages node releases (check/plan/apply/status/rollback/recover)",
    promptGuidelines: [
      "For apply, run plan first and report risks; after apply, poll status until completed or rolled back.",
      "After rollback or recover, run server_doctor before declaring success.",
    ],
    parameters: Type.Object({
      action: Type.Union(
        [
          Type.Literal("check"),
          Type.Literal("plan"),
          Type.Literal("apply"),
          Type.Literal("status"),
          Type.Literal("rollback"),
          Type.Literal("recover"),
        ],
        { description: "check availability, dry-run plan, apply, read status, roll back, or recover" },
      ),
      version: Type.Optional(Type.String({ description: "Target version vX.Y.Z (check/plan/apply)" })),
    }),
    async execute(_toolCallId, params): Promise<TextResult> {
      const p = paths();
      const root = piServerRoot(p.agentDir);
      const fail = (text: string, error: unknown): TextResult => ({
        content: [{ type: "text", text }],
        details: { error },
      });
      if (!v3Available(root)) {
        return fail("Refused: pointer releases not installed (pre-v0.3.0 layout).", "v3_unavailable");
      }
      const action = params.action as string;
      if (!isUpdateAction(action)) return fail("Refused: bad_action.", "bad_action");
      const ptr = readActivePointer(root);
      const installed = listInstalledReleases(root);
      const st = readUpdateState(root);
      const pending =
        st.found && !st.corrupt && !isTerminalPhase(st.phase) ? st : null;
      if (action === "status") {
        const lines = [
          `active: ${ptr.ok ? ptr.version : "(none)"}`,
          `installed: ${installed.join(", ") || "(none)"}`,
          pending ? `pending: ${pending.fromVersion} -> ${pending.toVersion} @ ${pending.phase}` : "no pending transaction",
        ];
        const hist = readHistoryTail(root, 1);
        if (hist.length > 0) {
          lines.push(`last: ${hist[0].fromVersion} -> ${hist[0].toVersion} = ${hist[0].result}`);
        }
        return { content: [{ type: "text", text: lines.join("\n") }], details: { active: ptr.version, installed, pending } };
      }
      if (action === "check") {
        const latest = await checkLatestRelease();
        const target = typeof params.version === "string" ? params.version : null;
        if (target !== null && !isReleaseVersion(target)) {
          return fail("Refused: bad_version.", "bad_version");
        }
        const lines = [
          `active: ${ptr.ok ? ptr.version : "(none)"}`,
          `installed: ${installed.join(", ") || "(none)"}`,
          latest.ok ? `latest: ${latest.tag}` : `latest: unknown (${latest.error})`,
        ];
        if (latest.ok && ptr.ok) lines.push(latest.tag === ptr.version ? "up to date" : "update available");
        if (target !== null) lines.push(`target ${target}: ${installed.includes(target) ? "installed" : "not installed"}`);
        return { content: [{ type: "text", text: lines.join("\n") }], details: { active: ptr.version, installed, latest: latest.tag } };
      }
      if (action === "plan") {
        const target = typeof params.version === "string" ? params.version : "";
        if (!isReleaseVersion(target)) return fail("Refused: plan requires version (vX.Y.Z).", "bad_version");
        const risks: string[] = [];
        if (!ptr.ok) risks.push(`active pointer unreadable (${ptr.error})`);
        if (pending) risks.push(`pending transaction ${pending.fromVersion} -> ${pending.toVersion} @ ${pending.phase}`);
        if (st.found && st.corrupt) risks.push("update-state corrupt (recover first)");
        const candidate = resolveReleaseDir(root, target);
        const lines = [
          `plan ${ptr.ok ? ptr.version : "(none)"} -> ${target}`,
          `candidate present: ${candidate.ok ? "yes" : "no"}`,
          `noop: ${ptr.ok && ptr.version === target ? "yes" : "no"}`,
          risks.length > 0 ? `risks: ${risks.join(" | ")}` : "risks: none",
        ];
        return { content: [{ type: "text", text: lines.join("\n") }], details: { target, risks, candidatePresent: candidate.ok } };
      }
      if (action === "rollback") {
        const prev = st.found && !st.corrupt ? st.previousVersion : "";
        if (!isReleaseVersion(prev) || !resolveReleaseDir(root, prev).ok) {
          return fail("Refused: no validated previous release to roll back to.", "no_rollback_target");
        }
        const spec = buildUpdaterArgv(root, "rollback", "", {});
        if (!spec.ok) return fail(`Refused: ${spec.error}.`, spec.error);
        const started = spawnDetached(spec.command, spec.args);
        if (!started) return fail("Refused: spawn_failed.", "spawn_failed");
        return {
          content: [{ type: "text", text: `Rollback to ${prev} started. Poll status for the outcome.` }],
          details: { accepted: true, target: prev },
        };
      }
      if (action === "recover") {
        const spec = buildUpdaterArgv(root, "recover", "", {});
        if (!spec.ok) return fail(`Refused: ${spec.error}.`, spec.error);
        const started = spawnDetached(spec.command, spec.args);
        if (!started) return fail("Refused: spawn_failed.", "spawn_failed");
        return {
          content: [{ type: "text", text: "Recovery started. Poll status for the outcome." }],
          details: { accepted: true },
        };
      }
      // apply
      const target = typeof params.version === "string" ? params.version : "";
      if (!isReleaseVersion(target)) return fail("Refused: apply requires version (vX.Y.Z).", "bad_version");
      if (pending) {
        return fail(`Refused: transaction already in flight (${pending.fromVersion} -> ${pending.toVersion} @ ${pending.phase}).`, "transaction_pending");
      }
      let staging = "";
      try {
        staging = mkdtempSync(join(tmpdir(), "pi-update-"));
      } catch {
        return fail("Refused: staging_failed.", "staging_failed");
      }
      const zipPath = join(staging, "mi-pi-server-windows.zip");
      const dl = await downloadRelease(target, zipPath);
      if (!dl.ok) {
        try { rmSync(staging, { recursive: true, force: true }); } catch { // ignore
        }
        return fail(`Refused: download failed (${dl.error}).`, dl.error);
      }
      const spec = buildUpdaterArgv(root, "update", target, { zipPath });
      if (!spec.ok) {
        try { rmSync(staging, { recursive: true, force: true }); } catch { // ignore
        }
        return fail(`Refused: ${spec.error}.`, spec.error);
      }
      const started = spawnDetached(spec.command, spec.args);
      if (!started) return fail("Refused: spawn_failed.", "spawn_failed");
      return {
        content: [{ type: "text", text: `Update to ${target} started (${dl.bytes}B verified). Poll status for the outcome.` }],
        details: { accepted: true, target },
      };
    },
  });

  async function runJsonCmd(
    cmd: string,
    args: string[],
    timeoutMs: number,
  ): Promise<unknown | null> {
    try {
      const { stdout } = await execFileAsync(cmd, args, {
        timeout: timeoutMs,
        windowsHide: true,
        maxBuffer: 1024 * 1024,
      });
      try {
        return JSON.parse(String(stdout ?? "")) as unknown;
      } catch {
        return null;
      }
    } catch (err) {
      const e = err as { stdout?: unknown };
      if (typeof e.stdout === "string") {
        try {
          return JSON.parse(e.stdout) as unknown;
        } catch {
          return null;
        }
      }
      return null;
    }
  }

  function spawnDetached(cmd: string, args: string[]): boolean {
    try {
      const child = spawn(cmd, args, {
        detached: true,
        stdio: "ignore",
        windowsHide: true,
      });
      child.unref();
      child.on("error", () => {
        // fire-and-forget: updater.log carries the outcome
      });
      return true;
    } catch {
      return false;
    }
  }

  function formatDoctorText(
    status: string,
    checks: unknown,
    _repaired: unknown,
  ): string {
    void _repaired;
    const lines: string[] = [`server ${status}`];
    lines.push(formatDoctorChecks(checks));
    return lines.filter((s) => s !== "").join("\n");
  }

  function formatDoctorChecks(checks: unknown): string {
    if (!Array.isArray(checks)) return "";
    const out: string[] = [];
    for (const c of checks as Array<Record<string, unknown>>) {
      if (typeof c !== "object" || c === null) continue;
      const mark = c["ok"] === true ? "·" : "✖";
      out.push(`${mark} ${String(c["name"] ?? "?")} [${String(c["severity"] ?? "?")}] :: ${String(c["detail"] ?? "")}`);
    }
    return out.join("\n");
  }

  async function modelCatalogHere(
    agentDir: string,
  ): Promise<{ ok: true; models: PiModelInfo[] } | { ok: false; error: string; message: string }> {
    const r = await runPiHere(agentDir, ["--list-models"], 30000);
    if (!r.ok) return { ok: false, error: "pi_unavailable", message: "pi --list-models failed." };
    const parsed = parseListModelsTable(r.stdout);
    if (!parsed.ok) return { ok: false, error: "pi_output_unparseable", message: "Could not parse pi --list-models output." };
    return { ok: true, models: parsed.models };
  }

  async function authedProvidersHere(agentDir: string, models: PiModelInfo[]): Promise<string[]> {
    const providers = [...new Set(models.map((m) => m.provider))].slice(0, 10);
    const out: string[] = [];
    for (const prov of providers) {
      if (!/^[A-Za-z0-9_.-]+$/.test(prov)) continue;
      const r = await runPiHere(agentDir, ["auth", "check", "--provider", prov, "--json", "--no-refresh"], 10000);
      if (!r.ok) continue;
      try {
        const lines = r.stdout
          .split(/\r?\n/)
          .map((l) => l.trim())
          .filter((l) => l.length > 0);
        for (let i = lines.length - 1; i >= 0; i--) {
          try {
            const j = JSON.parse(lines[i]) as { status?: unknown };
            if (j && j.status === "ready") out.push(prov);
            break;
          } catch {
            // keep scanning upward
          }
        }
      } catch {
        // treat as not ready
      }
    }
    return out;
  }

  async function runPiHere(
    agentDir: string,
    args: string[],
    timeoutMs: number,
  ): Promise<{ ok: boolean; stdout: string }> {
    // No PI_CODING_AGENT_DIR scoping needed: this tool runs inside the server
    // Pi process itself, whose env already carries the server agent dir
    // (run-task.ps1 sets it before spawn). Inherited env is correct by construction.
    const spec = buildPiSpawn("pi", process.platform, args);
    try {
      const { stdout } = await execFileAsync(spec.command, spec.args, {
        timeout: timeoutMs,
        windowsHide: true,
        windowsVerbatimArguments: !!spec.windowsVerbatimArguments,
        maxBuffer: 1024 * 1024,
      });
      return { ok: true, stdout: String(stdout ?? "") };
    } catch {
      return { ok: false, stdout: "" };
    }
  }
}
