/**
 * pi-remote — Mac-side Pi extension.
 *
 * Registers tools the Mac agent uses AUTONOMOUSLY when the user speaks about
 * the server in natural language ("cambia l'intervallo sul server a 30
 * minuti", "dammi lo stato del server", ...). The user never types commands.
 *
 * Transport (verified Bot API reality): Telegram bots cannot DM each other,
 * so the Mac posts a signed envelope into the PRIVATE control group with the
 * ControlBot token over plain HTTPS (sendMessage). The server's ServerBot
 * observes it through pi-telegram's single getUpdates loop and replies in
 * the same chat. This extension then waits for the correlated reply with a
 * SHORT-LIVED getUpdates poll on the ControlBot token (nothing else polls
 * that bot, so there is no polling conflict).
 *
 * Secrets (ControlBot token, HMAC) live in macOS Keychain — never in files,
 * never in logs. Only non-sensitive routing lives in remote-server.json.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { homedir } from "node:os";
import {
  RESPONSE_PREFIX,
  createNonce,
  encodeEnvelope,
  verifySignedText,
} from "../../shared/protocol.ts";
import { readJsonFile } from "../../shared/store.ts";

const execFileAsync = promisify(execFile);
const LOG = "[pi-remote]";

interface MacConfig {
  controlChatId: number;
  keychainAccount: string;
  controlBotTokenService: string;
  hmacService: string;
  serverBotUsername?: string;
  responseTimeoutSeconds?: number;
}

function macConfigPath(): string {
  const override = process.env["PI_CODING_AGENT_DIR"];
  const agentDir =
    override && override.trim().length > 0
      ? override
      : join(homedir(), ".pi", "agent");
  return join(agentDir, "remote-server.json");
}

function loadMacConfig(): MacConfig | null {
  const raw = readJsonFile<Partial<MacConfig> | null>(macConfigPath(), null);
  if (!raw || typeof raw.controlChatId !== "number") return null;
  return {
    controlChatId: raw.controlChatId,
    keychainAccount:
      typeof raw.keychainAccount === "string" ? raw.keychainAccount : "default",
    controlBotTokenService:
      typeof raw.controlBotTokenService === "string"
        ? raw.controlBotTokenService
        : "pi-remote-control-bot",
    hmacService:
      typeof raw.hmacService === "string" ? raw.hmacService : "pi-remote-hmac",
    serverBotUsername:
      typeof raw.serverBotUsername === "string"
        ? raw.serverBotUsername
        : undefined,
    responseTimeoutSeconds:
      typeof raw.responseTimeoutSeconds === "number"
        ? Math.min(180, Math.max(30, raw.responseTimeoutSeconds))
        : 90,
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

async function telegramApi<T>(
  token: string,
  method: string,
  params: Record<string, unknown>,
  timeoutMs: number,
): Promise<T> {
  const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(params),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!res.ok) throw new Error(`telegram_${method}_http_${res.status}`);
  const data = (await res.json()) as {
    ok?: boolean;
    result?: T;
    description?: string;
  };
  if (!data.ok)
    throw new Error(
      `telegram_${method}_failed:${(data.description ?? "unknown").slice(0, 120)}`,
    );
  return data.result as T;
}

interface TgUpdate {
  update_id: number;
  message?: {
    message_id?: number;
    text?: string;
    chat?: { id?: number };
    from?: { id?: number };
  };
}

/**
 * Wait for the server's signed reply correlated by requestId.
 * Short-lived long-polling on the ControlBot token; exits on match/timeout
 * so there is never a second permanent polling loop.
 */
async function awaitResponse(opts: {
  token: string;
  hmac: string;
  requestId: string;
  timeoutMs: number;
  startAfter: number;
}): Promise<{ ok: boolean; body?: unknown; error?: string; message?: string }> {
  const deadline = Date.now() + opts.timeoutMs;
  let offset = opts.startAfter;
  while (Date.now() < deadline) {
    const waitSec = Math.max(
      1,
      Math.min(30, Math.ceil((deadline - Date.now()) / 1000)),
    );
    const updates = await telegramApi<TgUpdate[]>(
      opts.token,
      "getUpdates",
      { offset, limit: 20, timeout: waitSec },
      (waitSec + 15) * 1000,
    ).catch(() => [] as TgUpdate[]);
    for (const u of updates) {
      offset = Math.max(offset, (u.update_id ?? 0) + 1);
      const text = u.message?.text;
      if (typeof text !== "string" || !text.startsWith(RESPONSE_PREFIX + " "))
        continue;
      const verified = verifySignedText(text, RESPONSE_PREFIX, {
        secret: opts.hmac,
        checkEnvelope: false,
      });
      if (!verified.ok) continue;
      const payload = verified.payload;
      if (payload["requestId"] !== opts.requestId) continue;
      return {
        ok: payload["ok"] === true,
        body: payload["body"],
        error:
          typeof payload["error"] === "string" ? payload["error"] : undefined,
        message:
          typeof payload["message"] === "string"
            ? payload["message"]
            : undefined,
      };
    }
  }
  throw new Error("response_timeout");
}

interface RemoteCall {
  cfg: MacConfig;
  token: string;
  hmac: string;
}

/** Result envelope returned to the model (never contains secrets). */
interface CallResult {
  text: string;
  details: Record<string, unknown>;
}

async function setupCall(): Promise<RemoteCall> {
  const cfg = loadMacConfig();
  if (!cfg)
    throw new Error(`Missing ${macConfigPath()}. Run mac/setup-mac.sh first.`);
  const [token, hmac] = await Promise.all([
    readKeychain(cfg.controlBotTokenService, cfg.keychainAccount),
    readKeychain(cfg.hmacService, cfg.keychainAccount),
  ]);
  return { cfg, token, hmac };
}

/**
 * Send a signed envelope to the control group and wait for the correlated
 * server reply. Both directions are HMAC-verified; secrets never leave
 * Keychain/HTTPS except inside the HMAC computation.
 */
export async function remoteCall(
  op: "set_config" | "get_status" | "ping",
  fields: Record<string, unknown>,
  timeoutOverrideSec?: number,
): Promise<CallResult> {
  const { cfg, token, hmac } = await setupCall();
  const requestId = `mac-${Date.now().toString(36)}-${createNonce().slice(0, 8)}`;
  // Pin the inbox cursor BEFORE sending: a fast server reply must not be skipped.
  const seen = await telegramApi<TgUpdate[]>(
    token,
    "getUpdates",
    { limit: 1, timeout: 0 },
    20000,
  ).catch(() => [] as TgUpdate[]);
  const startAfter =
    seen.length > 0 ? (seen[seen.length - 1]?.update_id ?? 0) + 1 : 1;
  const wire = encodeEnvelope(
    { op, requestId, ...fields } as Parameters<typeof encodeEnvelope>[0],
    hmac,
  );
  await telegramApi(
    token,
    "sendMessage",
    { chat_id: cfg.controlChatId, text: wire, disable_notification: true },
    20000,
  );
  const timeoutMs =
    (timeoutOverrideSec ?? cfg.responseTimeoutSeconds ?? 90) * 1000;
  const resp = await awaitResponse({
    token,
    hmac,
    requestId,
    timeoutMs,
    startAfter,
  });
  if (resp.ok) {
    return {
      text: resp.message ?? "✅ Server confirmed.",
      details: { ok: true, requestId, body: resp.body ?? null },
    };
  }
  return {
    text: `❌ Server refused: ${resp.error ?? "unknown"}${resp.message ? ` — ${resp.message}` : ""}`,
    details: { ok: false, requestId, error: resp.error },
  };
}

interface TextResult {
  content: Array<{ type: "text"; text: string }>;
  details: Record<string, unknown>;
}

const SettingsSchema = Type.Record(
  Type.String(),
  Type.Union([Type.String(), Type.Number(), Type.Boolean()]),
);

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
      ctx.ui.notify(`${LOG} ready (control chat configured)`, "info");
    } catch (err) {
      ctx.ui.notify(
        `${LOG} init failed: ${err instanceof Error ? err.message : "unknown"}`,
        "error",
      );
    }
  });

  pi.registerTool({
    name: "remote_server_config",
    label: "Remote Server Config",
    description:
      "Change a setting on the 24/7 Pi server node (old PC) over Telegram. " +
      "Use this automatically when the user asks — in any language — to change, enable, disable or tune something on the server: " +
      "'cambia l'intervallo sul server a 30 minuti', 'disattiva il modulo X sul server', 'riattiva il monitor', " +
      "'change the server interval to 30 minutes', 'disable module X on the server'. " +
      "Args: module (e.g. core, example-monitor) and settings (object with KNOWN fields only, e.g. {intervalMinutes: 30}). " +
      "Only whitelisted fields of registered modules are accepted; anything else is refused by the server.",
    promptSnippet:
      "remote_server_config changes whitelisted settings on the 24/7 server node via signed Telegram message",
    promptGuidelines: [
      "Whenever the user wants to change/enable/disable something ON THE SERVER, call remote_server_config with the right module and settings — do not ask for confirmation commands or slash commands.",
      "Module names: core (maintenanceMode, remoteControlEnabled), example-monitor (enabled, intervalMinutes). Ask the user which module only if it is truly ambiguous.",
      "After the call, report the server confirmation (or refusal reason) in the user's language.",
    ],
    parameters: Type.Object({
      module: Type.String({
        description: "Server module name, e.g. core or example-monitor",
      }),
      settings: SettingsSchema,
      timeoutSeconds: Type.Optional(
        Type.Number({
          description: "Reply wait timeout, 30-180s. Default 90.",
        }),
      ),
    }),
    executionMode: "sequential",
    async execute(_toolCallId, params): Promise<TextResult> {
      const module = params.module as string;
      const settings = (params.settings ?? {}) as Record<
        string,
        string | number | boolean
      >;
      const timeout =
        typeof params.timeoutSeconds === "number"
          ? Math.min(180, Math.max(30, params.timeoutSeconds))
          : undefined;
      try {
        const result = await remoteCall(
          "set_config",
          { module, patch: settings },
          timeout,
        );
        return {
          content: [{ type: "text", text: result.text }],
          details: result.details,
        };
      } catch (err) {
        const message =
          err instanceof Error ? err.message : "remote_call_failed";
        return {
          content: [
            { type: "text", text: `❌ Remote config failed: ${message}` },
          ],
          details: { ok: false, error: message },
        };
      }
    },
  });

  pi.registerTool({
    name: "remote_server_status",
    label: "Remote Server Status",
    description:
      "Ask the 24/7 Pi server node (old PC) how it is doing: online state, uptimes, versions, PM2 processes, memory, active modules and their config, last remote update. " +
      "Use this automatically when the user asks — in any language — about the server state: " +
      "'dammi lo stato del server', 'come sta il server?', 'quali moduli sono attivi?', 'are services running?', 'server status?'.",
    promptSnippet:
      "remote_server_status fetches live health from the 24/7 server node via signed Telegram request/response",
    promptGuidelines: [
      "Whenever the user asks about the server state, health, active modules or running services, call remote_server_status — do not answer from memory.",
      "Summarize the reply in the user's language; include module configs and any reported error.",
    ],
    parameters: Type.Object({
      timeoutSeconds: Type.Optional(
        Type.Number({
          description: "Reply wait timeout, 30-180s. Default 90.",
        }),
      ),
    }),
    executionMode: "sequential",
    async execute(): Promise<TextResult> {
      try {
        const timeout = undefined; // default from config
        const result = await remoteCall("get_status", {}, timeout);
        return {
          content: [{ type: "text", text: result.text }],
          details: result.details,
        };
      } catch (err) {
        const message =
          err instanceof Error ? err.message : "remote_call_failed";
        return {
          content: [
            { type: "text", text: `❌ Remote status failed: ${message}` },
          ],
          details: { ok: false, error: message },
        };
      }
    },
  });
}
