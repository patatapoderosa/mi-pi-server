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
import { execFile } from "node:child_process";
import { createRequire } from "node:module";
import { existsSync, readFileSync } from "node:fs";
import { freemem, loadavg, totalmem, uptime as osUptime } from "node:os";
import { hostname as osHostname } from "node:os";
import { join } from "node:path";
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
}
