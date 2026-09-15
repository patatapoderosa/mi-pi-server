/**
 * pi-remote — Mac-side Pi extension.
 *
 * Registers tools the Mac agent uses AUTONOMOUSLY when the user speaks about
 * the server in natural language ("set the interval on the server to 30
 * minutes", "server status", ...). The user never types commands.
 *
 * Transport: plain HTTPS-style fetch() to the Windows box over Tailscale
 * (WireGuard encrypts the wire). Every request carries HMAC-SHA256 auth
 * headers (X-Pi-Timestamp / X-Pi-Nonce / X-Pi-Signature) over
 * METHOD + LF + PATH + LF + TS + LF + NONCE + LF + SHA256(body).
 * See shared/protocol.ts. Telegram is NOT involved anymore.
 *
 * Secrets: only the HMAC lives in macOS Keychain — never in files, never in
 * logs. Routing (serverBaseUrl) lives in remote-server.json (non-sensitive).
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { homedir } from "node:os";
import { createNonce, sha256Hex, signRequest } from "../../shared/protocol.ts";
import { readJsonFile } from "../../shared/store.ts";

const execFileAsync = promisify(execFile);
const LOG = "[pi-remote]";

interface MacConfig {
  serverBaseUrl: string;
  keychainAccount: string;
  hmacService: string;
  timeoutSeconds?: number;
}

function macConfigPath(): string {
  const override = process.env["PI_CODING_AGENT_DIR"];
  const agentDir =
    override && override.trim().length > 0
      ? override
      : join(homedir(), ".pi", "agent");
  return join(agentDir, "remote-server.json");
}

function normalizeBaseUrl(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const v = raw.trim().replace(/\/+$/, "");
  if (!/^https?:\/\/[^\s/]+(:\d+)?$/.test(v)) return null;
  return v;
}

function loadMacConfig(): MacConfig | null {
  const raw = readJsonFile<Partial<MacConfig> | null>(macConfigPath(), null);
  if (!raw) return null;
  const serverBaseUrl = normalizeBaseUrl(raw.serverBaseUrl);
  if (!serverBaseUrl) return null;
  return {
    serverBaseUrl,
    keychainAccount:
      typeof raw.keychainAccount === "string" ? raw.keychainAccount : "default",
    hmacService:
      typeof raw.hmacService === "string" ? raw.hmacService : "pi-remote-hmac",
    timeoutSeconds:
      typeof raw.timeoutSeconds === "number"
        ? Math.min(120, Math.max(5, raw.timeoutSeconds))
        : 30,
  };
}

/** Read a secret from macOS Keychain. The value is never logged. */
async function readKeychain(service: string, account: string): Promise<string> {
  try {
    const { stdout } = await execFileAsync(
      "security",
      ["find-generic-password", "-s", service, "-a", account, "-w"],
      { timeout: 15000 },
    );
    const value = stdout.trim();
    if (!value) throw new Error("empty");
    return value;
  } catch {
    throw new Error(
      `Keychain lookup failed (service="${service}" account="${account}"). Re-run mac/setup-mac.sh to store the secret.`,
    );
  }
}

interface ServerReply {
  ok: boolean;
  body?: unknown;
  error?: string;
  message?: string;
}

/**
 * One signed request to the remote daemon. Throws on transport errors
 * (server offline, timeout); returns the decoded envelope otherwise.
 */
async function remoteCall(
  cfg: MacConfig,
  hmac: string,
  method: "GET" | "PATCH" | "POST",
  path: string,
  body: unknown,
  timeoutOverrideSec?: number,
): Promise<ServerReply> {
  const rawBody = body === undefined ? "" : JSON.stringify(body);
  const ts = Math.floor(Date.now() / 1000);
  const nonce = createNonce();
  const signature = signRequest(hmac, {
    method,
    path,
    ts,
    nonce,
    bodyHash: sha256Hex(rawBody),
  });
  const timeoutMs = (timeoutOverrideSec ?? cfg.timeoutSeconds ?? 30) * 1000;
  let res: Response;
  try {
    res = await fetch(cfg.serverBaseUrl + path, {
      method,
      headers: {
        "content-type": "application/json",
        "x-pi-timestamp": String(ts),
        "x-pi-nonce": nonce,
        "x-pi-signature": signature,
      },
      body: method === "GET" ? undefined : rawBody,
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "fetch_failed";
    if (/aborted|timeout/i.test(message)) {
      throw new Error(
        `server unreachable (timeout after ${Math.round(timeoutMs / 1000)}s): is Tailscale up and the daemon online?`,
      );
    }
    throw new Error(
      `server unreachable (${message}): is Tailscale up and the daemon online?`,
    );
  }
  let data: Record<string, unknown>;
  try {
    data = (await res.json()) as Record<string, unknown>;
  } catch {
    throw new Error(`server returned HTTP ${res.status} with a non-JSON body`);
  }
  if (!res.ok || data["ok"] !== true) {
    const error =
      typeof data["error"] === "string" ? data["error"] : `http_${res.status}`;
    const message =
      typeof data["message"] === "string" ? data["message"] : undefined;
    return {
      ok: false,
      error,
      message,
      body: data["body"],
    };
  }
  return {
    ok: true,
    body: data["body"],
    message: typeof data["message"] === "string" ? data["message"] : undefined,
  };
}

interface Ctx2 {
  cfg: MacConfig;
  hmac: string;
}

async function setupCall(): Promise<Ctx2> {
  const cfg = loadMacConfig();
  if (!cfg)
    throw new Error(`Missing ${macConfigPath()}. Run mac/setup-mac.sh first.`);
  const hmac = await readKeychain(cfg.hmacService, cfg.keychainAccount);
  return { cfg, hmac };
}

interface TextResult {
  content: Array<{ type: "text"; text: string }>;
  details: Record<string, unknown>;
}

function failResult(prefix: string, err: unknown): TextResult {
  const message = err instanceof Error ? err.message : "remote_call_failed";
  return {
    content: [{ type: "text", text: `❌ ${prefix}: ${message}` }],
    details: { ok: false, error: message },
  };
}

function summarizeModules(body: unknown): string {
  const mods = (
    body as {
      modules?: Array<{
        name: string;
        enabled: boolean | null;
        config: unknown;
      }>;
    }
  )?.modules;
  if (!Array.isArray(mods)) return "No module list in reply.";
  return mods
    .map((m) => {
      let state = "";
      if (m.enabled === true) state = " (enabled)";
      else if (m.enabled === false) state = " (disabled)";
      return `- ${m.name}${state}: ${JSON.stringify(m.config)}`;
    })
    .join("\n");
}

const SettingsSchema = Type.Record(
  Type.String(),
  Type.Union([Type.String(), Type.Number(), Type.Boolean()]),
);

const TimeoutSchema = Type.Optional(
  Type.Number({ description: "Request timeout, 5-120s. Default 30." }),
);

function formatDoctor(body: unknown, repaired: boolean): string {
  if (typeof body !== "object" || body === null) return "❌ unreadable doctor response";
  const b = body as { status?: unknown; checks?: unknown; repaired?: unknown; detail?: unknown; exitNote?: unknown };
  const lines: string[] = [];
  if (Array.isArray(b["repaired"])) {
    lines.push(`🔧 repaired: ${(b["repaired"] as unknown[]).join(", ") || "(nothing)"}`);
  }
  if (typeof b["detail"] === "string" && b["detail"] !== "") lines.push(b["detail"]);
  const status = typeof b["status"] === "string" ? b["status"] : "unknown";
  const icon = status === "healthy" ? "✅" : status === "degraded" ? "⚠️" : "❌";
  lines.push(`${icon} server ${status}`);
  if (Array.isArray(b["checks"])) {
    for (const c of b["checks"] as Array<Record<string, unknown>>) {
      if (typeof c !== "object" || c === null) continue;
      const mark = c["ok"] === true ? "·" : "✖";
      lines.push(`${mark} ${String(c["name"] ?? "?")} [${String(c["severity"] ?? "?")}] :: ${String(c["detail"] ?? "")}`);
    }
  }
  if (typeof b["exitNote"] === "string") lines.push(b["exitNote"]);
  if (!repaired && status !== "healthy") lines.push("Run server_doctor with repair:true to attempt safe self-heal.");
  return lines.join("\n");
}

function formatUpdateStatus(body: unknown): string {
  if (typeof body !== "object" || body === null) return "❌ unreadable update status";
  const b = body as Record<string, unknown>;
  const lines: string[] = [`📌 active: ${String(b["active"] ?? "(none)")}`];
  if (Array.isArray(b["installed"])) lines.push(`📦 installed: ${(b["installed"] as unknown[]).join(", ") || "(none)"}`);
  const pt = b["pendingTransaction"];
  if (pt !== null && pt !== undefined && typeof pt === "object") {
    const t = pt as Record<string, unknown>;
    lines.push(`⏳ pending: ${String(t["fromVersion"])} -> ${String(t["toVersion"])} @ ${String(t["phase"])}`);
  } else {
    lines.push("⏳ no pending transaction");
  }
  if (b["stateCorrupt"] === true) lines.push("⚠️ update-state corrupt (recover first)");
  const hist = b["historyTail"];
  if (Array.isArray(hist) && hist.length > 0) {
    const last = hist[hist.length - 1] as Record<string, unknown>;
    lines.push(`🕘 last: ${String(last["fromVersion"])} -> ${String(last["toVersion"])} = ${String(last["result"])}`);
  }
  return lines.join("\n");
}

function formatUpdateResult(action: string, body: unknown): string {
  if (typeof body !== "object" || body === null) return "❌ unreadable update response";
  const b = body as Record<string, unknown>;
  const lines: string[] = [`▶️ update ${action} accepted: ${b["accepted"] === true ? "yes" : "no"}`];
  for (const k of ["target", "current", "latest", "message"]) {
    if (b[k] !== undefined && b[k] !== null && b[k] !== "") lines.push(`${k}: ${String(b[k])}`);
  }
  if (b["updateAvailable"] !== undefined && b["updateAvailable"] !== null) {
    lines.push(`updateAvailable: ${String(b["updateAvailable"])}`);
  }
  if (Array.isArray(b["risks"])) {
    const risks = b["risks"] as unknown[];
    lines.push(risks.length > 0 ? `risks: ${risks.join(" | ")}` : "risks: none");
  }
  if (b["noop"] === true) lines.push("noop: target already active");
  return lines.join("\n");
}

export default function piRemoteExtension(pi: ExtensionAPI): void {
  pi.on("session_start", async (_event, ctx) => {
    try {
      const cfg = loadMacConfig();
      if (!cfg) {
        ctx.ui.notify(
          `${LOG} not configured yet — run mac/setup-mac.sh`,
          "warning",
        );
        return;
      }
      ctx.ui.notify(`${LOG} ready (${cfg.serverBaseUrl})`, "info");
    } catch (err) {
      ctx.ui.notify(
        `${LOG} init failed: ${err instanceof Error ? err.message : "unknown"}`,
        "error",
      );
    }
  });

  pi.registerTool({
    name: "remote_server_status",
    label: "Remote Server Status",
    description:
      "Ask the 24/7 Pi server node (Windows, over Tailscale) how it is doing: online state, hostname, uptimes, versions, memory, active modules and their config, last remote request. " +
      "Use this automatically when the user asks — in any language — about the server state: " +
      "'server status', 'how is the server?', 'which modules are active?', 'stato server?'.",
    promptSnippet:
      "remote_server_status fetches live health from the 24/7 server node over Tailscale",
    promptGuidelines: [
      "Whenever the user asks about the server state, health, active modules or running services, call remote_server_status — do not answer from memory.",
      "Summarize the reply in the user's language; include module configs and any reported error.",
    ],
    parameters: Type.Object({ timeoutSeconds: TimeoutSchema }),
    executionMode: "sequential",
    async execute(_toolCallId, params): Promise<TextResult> {
      try {
        const { cfg, hmac } = await setupCall();
        const timeout =
          typeof params.timeoutSeconds === "number"
            ? Math.min(120, Math.max(5, params.timeoutSeconds))
            : undefined;
        const resp = await remoteCall(
          cfg,
          hmac,
          "GET",
          "/v1/status",
          undefined,
          timeout,
        );
        if (!resp.ok) {
          return {
            content: [
              {
                type: "text",
                text: `❌ Server refused: ${resp.error ?? "unknown"}`,
              },
            ],
            details: { ok: false, error: resp.error },
          };
        }
        const body = resp.body as {
          hostname?: string;
          appVersion?: string;
          osUptime?: string;
          modules?: unknown;
        };
        const lines = [
          `🟢 server online (${body.hostname ?? "?"} | app ${body.appVersion ?? "?"})`,
          `os uptime: ${body.osUptime ?? "?"}`,
          summarizeModules(resp.body),
        ];
        return {
          content: [{ type: "text", text: lines.join("\n") }],
          details: { ok: true, body: resp.body },
        };
      } catch (err) {
        return failResult("Remote status failed", err);
      }
    },
  });

  pi.registerTool({
    name: "remote_server_config",
    label: "Remote Server Config",
    description:
      "Change a setting on the 24/7 Pi server node (Windows, over Tailscale). " +
      "Use this automatically when the user asks — in any language — to change or tune something on the server: " +
      "'set the interval to 30 minutes', 'metti il modulo X ogni 30 minuti', 'change the server interval'. " +
      "Args: module (e.g. core, example-monitor) and settings (object with KNOWN fields only, e.g. {intervalMinutes: 30}). " +
      "Only whitelisted fields of registered modules are accepted; anything else is refused by the server. " +
      "To enable/disable a whole module, prefer remote_module_enable / remote_module_disable.",
    promptSnippet:
      "remote_server_config changes whitelisted settings on the 24/7 server node via signed HTTPS",
    promptGuidelines: [
      "Whenever the user wants to change or tune something ON THE SERVER, call remote_server_config with the right module and settings.",
      "Module names: core (maintenanceMode, remoteControlEnabled), example-monitor (enabled, intervalMinutes). Ask the user which module only if it is truly ambiguous.",
      "After the call, report the server confirmation (or refusal reason) in the user's language.",
    ],
    parameters: Type.Object({
      module: Type.String({
        description: "Server module name, e.g. core or example-monitor",
      }),
      settings: SettingsSchema,
      timeoutSeconds: TimeoutSchema,
    }),
    executionMode: "sequential",
    async execute(_toolCallId, params): Promise<TextResult> {
      try {
        const { cfg, hmac } = await setupCall();
        const module = params.module as string;
        const settings = (params.settings ?? {}) as Record<
          string,
          string | number | boolean
        >;
        const timeout =
          typeof params.timeoutSeconds === "number"
            ? Math.min(120, Math.max(5, params.timeoutSeconds))
            : undefined;
        const resp = await remoteCall(
          cfg,
          hmac,
          "PATCH",
          `/v1/modules/${encodeURIComponent(module)}/config`,
          { patch: settings },
          timeout,
        );
        if (!resp.ok) {
          return {
            content: [
              {
                type: "text",
                text: `❌ Server refused (${resp.error ?? "unknown"}): ${resp.message ?? "no detail"}`,
              },
            ],
            details: { ok: false, error: resp.error },
          };
        }
        const body = resp.body as { config?: unknown };
        return {
          content: [
            {
              type: "text",
              text: `✅ ${module} updated: ${JSON.stringify(body.config ?? {})}`,
            },
          ],
          details: { ok: true, body: resp.body },
        };
      } catch (err) {
        return failResult("Remote config failed", err);
      }
    },
  });

  async function toggleModule(
    module: string,
    want: boolean,
    timeout?: number,
  ): Promise<TextResult> {
    try {
      const { cfg, hmac } = await setupCall();
      const resp = await remoteCall(
        cfg,
        hmac,
        "POST",
        `/v1/modules/${encodeURIComponent(module)}/${want ? "enable" : "disable"}`,
        {},
        timeout,
      );
      if (!resp.ok) {
        return {
          content: [
            {
              type: "text",
              text: `❌ Server refused (${resp.error ?? "unknown"}): ${resp.message ?? "no detail"}`,
            },
          ],
          details: { ok: false, error: resp.error },
        };
      }
      return {
        content: [
          {
            type: "text",
            text: want ? `✅ ${module} enabled.` : `✅ ${module} disabled.`,
          },
        ],
        details: { ok: true, body: resp.body },
      };
    } catch (err) {
      return failResult(
        want ? "Remote enable failed" : "Remote disable failed",
        err,
      );
    }
  }

  const ModuleParam = Type.Object({
    module: Type.String({
      description: "Server module name, e.g. example-monitor",
    }),
    timeoutSeconds: TimeoutSchema,
  });

  pi.registerTool({
    name: "remote_module_enable",
    label: "Remote Module Enable",
    description:
      "Enable a module on the 24/7 Pi server node (Windows, over Tailscale). " +
      "Use automatically for 'enable module X', 'attiva il modulo X', 'riattiva il monitor'.",
    promptSnippet:
      "remote_module_enable flips a module's enabled flag on via signed HTTPS",
    promptGuidelines: [
      "Prefer this over remote_server_config when the user says enable/activate/riattiva.",
    ],
    parameters: ModuleParam,
    executionMode: "sequential",
    async execute(_toolCallId, params): Promise<TextResult> {
      const timeout =
        typeof params.timeoutSeconds === "number"
          ? Math.min(120, Math.max(5, params.timeoutSeconds))
          : undefined;
      return toggleModule(params.module as string, true, timeout);
    },
  });

  pi.registerTool({
    name: "remote_module_disable",
    label: "Remote Module Disable",
    description:
      "Disable a module on the 24/7 Pi server node (Windows, over Tailscale). " +
      "Use automatically for 'disable module X', 'disattiva il modulo X', 'spegni il monitor'.",
    promptSnippet:
      "remote_module_disable flips a module's enabled flag off via signed HTTPS",
    promptGuidelines: [
      "Prefer this over remote_server_config when the user says disable/deactivate/disattiva.",
    ],
    parameters: ModuleParam,
    executionMode: "sequential",
    async execute(_toolCallId, params): Promise<TextResult> {
      const timeout =
        typeof params.timeoutSeconds === "number"
          ? Math.min(120, Math.max(5, params.timeoutSeconds))
          : undefined;
      return toggleModule(params.module as string, false, timeout);
    },
  });
  pi.registerTool({
    name: "server_model_get",
    label: "Server Model Get",
    description:
      "Ask which default model the 24/7 Pi server node (Windows, over Tailscale) will use at startup: provider, model id, thinking level, settings source. " +
      "Use this automatically when the user asks — in any language — which model the server uses: " +
      "'che modello usa il server?', 'which model does the server use?', 'server default model'. " +
      "This is the CONFIGURED startup default from the server settings.json; the live session keeps its boot-time model until Pi restarts.",
    promptSnippet:
      "server_model_get reads the server startup model default via signed HTTPS",
    promptGuidelines: [
      "Whenever the user asks which model the server uses or has configured, call server_model_get — do not answer from memory.",
      "Always report whether a restart is needed for a pending default to take effect.",
    ],
    parameters: Type.Object({ timeoutSeconds: TimeoutSchema }),
    executionMode: "sequential",
    async execute(_toolCallId, params): Promise<TextResult> {
      try {
        const { cfg, hmac } = await setupCall();
        const timeout =
          typeof params.timeoutSeconds === "number"
            ? Math.min(120, Math.max(5, params.timeoutSeconds))
            : undefined;
        const resp = await remoteCall(
          cfg,
          hmac,
          "GET",
          "/v1/model",
          undefined,
          timeout,
        );
        if (!resp.ok) {
          return {
            content: [
              {
                type: "text",
                text: `❌ Server refused (${resp.error ?? "unknown"}): ${resp.message ?? "no detail"}`,
              },
            ],
            details: { ok: false, error: resp.error },
          };
        }
        const b = resp.body as {
          provider?: unknown;
          model?: unknown;
          thinkingLevel?: unknown;
          source?: unknown;
          requiresRestart?: unknown;
          note?: unknown;
        };
        const lines = b.provider
          ? [
              `🤖 server startup default: ${b.provider}/${b.model}`,
              `thinking: ${b.thinkingLevel ?? "(Pi default)"}`,
              `source: ${b.source ?? "settings.json"}`,
              b.requiresRestart
                ? "takes effect at next Pi start (restart PiHomeServer to apply now)"
                : "active",
              `${b.note ?? ""}`,
            ]
          : [
              "🤖 server has no default model configured (Pi falls back to first available at startup).",
            ];
        return {
          content: [{ type: "text", text: lines.join("\n") }],
          details: { ok: true, body: resp.body },
        };
      } catch (err) {
        return failResult("Server model get failed", err);
      }
    },
  });
  pi.registerTool({
    name: "server_model_list",
    label: "Server Model List",
    description:
      "List the models REALLY available on the 24/7 Pi server node (Windows, over Tailscale): live Pi catalog with per-provider auth status. " +
      "Use this automatically when the user asks — in any language — what the server offers: " +
      "'mostrami i modelli disponibili sul server', 'list server models', 'what models can the server use?'.",
    promptSnippet:
      "server_model_list fetches the live server model catalog with auth status via signed HTTPS",
    promptGuidelines: [
      "Whenever the user asks which models are available on the server, call server_model_list — do not answer from memory.",
      "Only models with ready auth (authenticated: true) can be set as default.",
    ],
    parameters: Type.Object({ timeoutSeconds: TimeoutSchema }),
    executionMode: "sequential",
    async execute(_toolCallId, params): Promise<TextResult> {
      try {
        const { cfg, hmac } = await setupCall();
        const timeout =
          typeof params.timeoutSeconds === "number"
            ? Math.min(120, Math.max(5, params.timeoutSeconds))
            : 60;
        const resp = await remoteCall(
          cfg,
          hmac,
          "GET",
          "/v1/models",
          undefined,
          timeout,
        );
        if (!resp.ok) {
          return {
            content: [
              {
                type: "text",
                text: `❌ Server refused (${resp.error ?? "unknown"}): ${resp.message ?? "no detail"}`,
              },
            ],
            details: { ok: false, error: resp.error },
          };
        }
        const body = resp.body as {
          models?: Array<{
            provider?: unknown;
            id?: unknown;
            thinking?: unknown;
            images?: unknown;
            context?: unknown;
            authenticated?: unknown;
          }>;
          truncated?: unknown;
        };
        const models = Array.isArray(body.models) ? body.models : [];
        if (models.length === 0) {
          return {
            content: [
              {
                type: "text",
                text: "🤖 server reports no available models (no logins on the server?).",
              },
            ],
            details: { ok: true, body: resp.body },
          };
        }
        const lines = models.map((m) => {
          const flags = [
            `${m.authenticated === true ? "✅" : "🔒"} ${m.provider}/${m.id}`,
          ];
          const caps: string[] = [];
          if (m.thinking === true) caps.push("thinking");
          if (m.images === true) caps.push("images");
          if (typeof m.context === "string") caps.push(`${m.context} ctx`);
          return `- ${flags[0]}${caps.length > 0 ? ` (${caps.join(", ")})` : ""}`;
        });
        if (body.truncated === true) lines.push("…truncated to 100 rows.");
        return {
          content: [{ type: "text", text: lines.join("\n") }],
          details: { ok: true, body: resp.body },
        };
      } catch (err) {
        return failResult("Server model list failed", err);
      }
    },
  });
  pi.registerTool({
    name: "server_model_set",
    label: "Server Model Set",
    description:
      "Set the default model of the 24/7 Pi server node (Windows, over Tailscale): provider + model id, optional thinking level and apply-now flag. " +
      "Use this automatically when the user asks — in any language — to change the server default: " +
      "'imposta openai/gpt-... come default sul server', 'metti X come modello predefinito e applicalo subito'. " +
      "The server validates the selection against its LIVE catalog (unknown/ambiguous/unauthenticated models are refused). " +
      "The change applies at next Pi start; applyNow:true only records intent, a PiHomeServer restart is still required.",
    promptSnippet:
      "server_model_set writes the server startup model default via signed HTTPS",
    promptGuidelines: [
      "Whenever the user wants to change the server default model, call server_model_set with provider + model.",
      "If unsure which model, call server_model_list first and pick an authenticated one.",
      "After setting, always report whether a PiHomeServer restart is needed.",
    ],
    parameters: Type.Object({
      provider: Type.Optional(
        Type.String({
          description:
            "Provider id, e.g. openai (optional if model is provider/model)",
        }),
      ),
      model: Type.String({
        description: "Model id, e.g. gpt-5.5 (exact id as listed)",
      }),
      thinkingLevel: Type.Optional(
        Type.Union(
          [
            Type.Literal("off"),
            Type.Literal("minimal"),
            Type.Literal("low"),
            Type.Literal("medium"),
            Type.Literal("high"),
            Type.Literal("xhigh"),
            Type.Literal("max"),
          ],
          { description: "Startup thinking level (optional)" },
        ),
      ),
      applyNow: Type.Optional(
        Type.Boolean({
          description:
            "Record intent to apply immediately (still requires a PiHomeServer restart)",
        }),
      ),
      timeoutSeconds: TimeoutSchema,
    }),
    executionMode: "sequential",
    async execute(_toolCallId, params): Promise<TextResult> {
      try {
        const { cfg, hmac } = await setupCall();
        const payload: Record<string, unknown> = {
          model: params.model as string,
        };
        if (typeof params.provider === "string")
          payload["provider"] = params.provider;
        if (typeof params.thinkingLevel === "string")
          payload["thinkingLevel"] = params.thinkingLevel;
        if (typeof params.applyNow === "boolean")
          payload["applyNow"] = params.applyNow;
        const timeout =
          typeof params.timeoutSeconds === "number"
            ? Math.min(120, Math.max(5, params.timeoutSeconds))
            : 60;
        const resp = await remoteCall(
          cfg,
          hmac,
          "POST",
          "/v1/model",
          payload,
          timeout,
        );
        if (!resp.ok) {
          return {
            content: [
              {
                type: "text",
                text: `❌ Server refused (${resp.error ?? "unknown"}): ${resp.message ?? "no detail"}`,
              },
            ],
            details: { ok: false, error: resp.error },
          };
        }
        const b = resp.body as {
          provider?: unknown;
          model?: unknown;
          thinkingLevel?: unknown;
          requiresRestart?: unknown;
          message?: unknown;
        };
        return {
          content: [
            {
              type: "text",
              text: `✅ server default is now ${b.provider}/${b.model} (thinking: ${b.thinkingLevel ?? "(unchanged)"}). ${b.message ?? ""}`,
            },
          ],
          details: { ok: true, body: resp.body },
        };
      } catch (err) {
        return failResult("Server model set failed", err);
      }
    },
  });

  pi.registerTool({
    name: "server_doctor",
    label: "Server Doctor",
    description:
      "Check the 24/7 Pi server node (Windows, over Tailscale): structured diagnostics " +
      "(active release, tasks, processes, listener, Tailscale, update transaction) with " +
      "healthy/degraded/unhealthy status. Use automatically when the user asks — in any " +
      "language — to check the server: 'controlla il server', 'check the server', " +
      "'server sano?', 'come sta il server?'. With repair:true it also applies safe " +
      "allowlisted self-heal (restart tasks, sweep owned orphans, recover transactions) " +
      "behind a circuit breaker: use when the user says 'aggiusta quello che puoi', " +
      "'fix what you can', 'ripara il server'. Read-only by default; repair is MEDIUM risk.",
    promptSnippet:
      "server_doctor reads server diagnostics (and optionally repairs) via signed HTTPS",
    promptGuidelines: [
      "When the user asks to check the server, call server_doctor — do not answer from memory.",
      "After repair, always report what was repaired and the verify status; if unhealthy remains, say manual intervention is needed.",
    ],
    parameters: Type.Object({
      fresh: Type.Optional(Type.Boolean({ description: "Regenerate live (default cached report)" })),
      repair: Type.Optional(Type.Boolean({ description: "Run allowlisted self-heal (MEDIUM risk)" })),
      only: Type.Optional(Type.Array(Type.String(), { description: "Repair groups subset" })),
      timeoutSeconds: TimeoutSchema,
    }),
    executionMode: "sequential",
    async execute(_toolCallId, params): Promise<TextResult> {
      try {
        const { cfg, hmac } = await setupCall();
        const timeout =
          typeof params.timeoutSeconds === "number"
            ? Math.min(300, Math.max(5, params.timeoutSeconds))
            : undefined;
        const repair = params.repair === true;
        const fresh = params.fresh === true;
        if (!repair && !fresh) {
          const resp = await remoteCall(cfg, hmac, "GET", "/v1/doctor", undefined, timeout);
          if (!resp.ok) {
            return {
              content: [{ type: "text", text: `❌ Doctor refused (${resp.error ?? "unknown"}): ${resp.message ?? "no detail"}` }],
              details: { ok: false, error: resp.error },
            };
          }
          return { content: [{ type: "text", text: formatDoctor(resp.body, false) }], details: { ok: true, body: resp.body } };
        }
        const body: Record<string, unknown> = { fresh, repair };
        if (Array.isArray(params.only)) body["only"] = params.only;
        const resp = await remoteCall(cfg, hmac, "POST", "/v1/doctor", body, timeout);
        if (!resp.ok) {
          return {
            content: [{ type: "text", text: `❌ Doctor refused (${resp.error ?? "unknown"}): ${resp.message ?? "no detail"}` }],
            details: { ok: false, error: resp.error },
          };
        }
        return { content: [{ type: "text", text: formatDoctor(resp.body, repair) }], details: { ok: true, body: resp.body } };
      } catch (err) {
        return failResult("Server doctor failed", err);
      }
    },
  });

  pi.registerTool({
    name: "server_update",
    label: "Server Update",
    description:
      "Manage server releases on the 24/7 Pi node (Windows, over Tailscale): check " +
      "(installed vs latest), plan (dry-run risks for a version), apply (download, " +
      "pointer-switch, verify, auto-rollback), status (transaction + active release), " +
      "rollback (previous validated release), recover (finish interrupted update). " +
      "Use automatically: 'aggiorna il server' → apply, 'l'update ha funzionato?' → status, " +
      "'torna alla versione precedente' → rollback, 'is an update available?' → check. " +
      "apply/rollback are MEDIUM risk (pointer switch + task restart, automatic rollback " +
      "on health failure). Never downloads from arbitrary URLs: fixed GitHub releases only.",
    promptSnippet:
      "server_update manages server releases (check/plan/apply/status/rollback/recover) via signed HTTPS",
    promptGuidelines: [
      "For apply, always run plan first and report risks; after apply, poll status until completed or rolled back.",
      "After rollback or recover, verify with server_doctor before declaring success.",
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
      timeoutSeconds: TimeoutSchema,
    }),
    executionMode: "sequential",
    async execute(_toolCallId, params): Promise<TextResult> {
      try {
        const { cfg, hmac } = await setupCall();
        const timeout =
          typeof params.timeoutSeconds === "number"
            ? Math.min(300, Math.max(5, params.timeoutSeconds))
            : undefined;
        const action = params.action as string;
        if (action === "status") {
          const resp = await remoteCall(cfg, hmac, "GET", "/v1/update", undefined, timeout);
          if (!resp.ok) {
            return {
              content: [{ type: "text", text: `❌ Update status refused (${resp.error ?? "unknown"}): ${resp.message ?? "no detail"}` }],
              details: { ok: false, error: resp.error },
            };
          }
          return { content: [{ type: "text", text: formatUpdateStatus(resp.body) }], details: { ok: true, body: resp.body } };
        }
        const body: Record<string, unknown> = { action };
        if (typeof params.version === "string") body["version"] = params.version;
        const resp = await remoteCall(cfg, hmac, "POST", "/v1/update", body, timeout);
        if (!resp.ok) {
          return {
            content: [{ type: "text", text: `❌ Update refused (${resp.error ?? "unknown"}): ${resp.message ?? "no detail"}` }],
            details: { ok: false, error: resp.error },
          };
        }
        return { content: [{ type: "text", text: formatUpdateResult(action, resp.body) }], details: { ok: true, body: resp.body } };
      } catch (err) {
        return failResult("Server update failed", err);
      }
    },
  });
}
