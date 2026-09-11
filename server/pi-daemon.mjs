#!/usr/bin/env node
/**
 * pi-daemon.mjs — robust wrapper that keeps `pi --mode rpc` alive under PM2.
 *
 * Why RPC mode: it is Pi's official headless mode (docs/rpc.md) — JSONL over
 * stdio, no TTY required. The daemon:
 * - spawns `pi --mode rpc` with piped stdio (stdin kept open),
 * - prefixes/logs stdout frames compactly ([pi-server]) and stderr ([pi-server:err]),
 * - sends one idempotent `/telegram-connect` after startup so pi-telegram
 *   acquires polling ownership even after a reboot (safe: the command only
 *   queues a hidden, non-triggering connection note),
 * - forwards SIGTERM/SIGINT for graceful shutdown (pi emits session_shutdown),
 * - exits with Pi's code so PM2's autorestart policy applies cleanly,
 * - heartbeats every 60s so `pm2 logs` shows liveness.
 *
 * Extension errors surfacing as `extension_error` / `type: "extension_error"`
 * events are logged with [pi-server:extension] and never crash the daemon.
 */
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const LOG = "[pi-server]";
const PI_BIN = process.env["PI_BIN"] ?? "pi";
const CONNECT_DELAY_MS = Number(
  process.env["PI_SERVER_CONNECT_DELAY_MS"] ?? 8000,
);
const AUTO_CONNECT = (process.env["PI_SERVER_AUTO_CONNECT"] ?? "1") !== "0";
const HEARTBEAT_MS = 60000;

function log(msg) {
  process.stdout.write(`${new Date().toISOString()} ${LOG} ${msg}\n`);
}
function logErr(msg) {
  process.stderr.write(`${new Date().toISOString()} ${LOG}:err ${msg}\n`);
}

let child = null;
let shuttingDown = false;
let connected = false;

function sendRpc(obj) {
  if (!child || child.exitCode !== null) return false;
  try {
    child.stdin.write(JSON.stringify(obj) + "\n");
    return true;
  } catch (err) {
    logErr(
      `stdin write failed: ${err instanceof Error ? err.message : "unknown"}`,
    );
    return false;
  }
}

function start() {
  log(`starting: ${PI_BIN} --mode rpc`);
  child = spawn(PI_BIN, ["--mode", "rpc"], {
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });

  child.on("error", (err) => {
    logErr(`spawn failed: ${err.message} (is pi installed and on PATH?)`);
    process.exit(2);
  });

  const rl = createInterface({ input: child.stdout });
  rl.on("line", (line) => {
    let evt = null;
    try {
      evt = JSON.parse(line);
    } catch {
      log(`non-json stdout: ${line.slice(0, 300)}`);
      return;
    }
    const t = evt?.type ?? "?";
    if (t === "extension_error") {
      logErr(
        `extension error in ${evt.extensionPath ?? "?"} during ${evt.event ?? "?"}: ${(evt.error ?? "").toString().slice(0, 300)}`,
      );
    } else if (t === "response") {
      log(
        `rpc response: command=${evt.command ?? "?"} success=${evt.success === true} ${evt.success === true ? "" : (evt.error ?? "")}`.slice(
          0,
          300,
        ),
      );
    } else if (
      t === "agent_end" ||
      t === "agent_settled" ||
      t === "compaction_end" ||
      t === "auto_retry_end"
    ) {
      log(`event: ${t}`);
    } else if (t === "extension_ui_request") {
      log(
        `extension ui request: method=${evt.method ?? "?"} id=${evt.id ?? "?"}`,
      );
    }
    // message_update / turn spam is intentionally not logged (too noisy).
  });

  child.stderr.on("data", (d) => {
    for (const line of String(d).split("\n")) {
      if (line.trim().length > 0) logErr(line.slice(0, 500));
    }
  });

  child.on("exit", (code, signal) => {
    if (shuttingDown) {
      log(`pi exited during shutdown (code=${code} signal=${signal})`);
      process.exit(code ?? 0);
      return;
    }
    logErr(
      `pi exited unexpectedly (code=${code} signal=${signal}) — exiting so PM2 restarts us`,
    );
    process.exit(code ?? 1);
  });

  // Keep stdin flowing; without a reader/writer the pipe can EPIPE.
  child.stdin.on("error", () => {});

  if (AUTO_CONNECT) {
    setTimeout(() => {
      if (shuttingDown || connected) return;
      connected = true;
      log("sending /telegram-connect (idempotent ownership acquire)");
      sendRpc({
        id: "pi-server-connect",
        type: "prompt",
        message: "/telegram-connect",
      });
    }, CONNECT_DELAY_MS);
  }
}

function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log(`received ${signal} — forwarding to pi (graceful, 15s)`);
  if (child && child.exitCode === null) {
    try {
      child.kill(signal);
    } catch {
      // already gone
    }
    setTimeout(() => {
      if (child && child.exitCode === null) {
        logErr("pi did not exit in time — SIGKILL");
        try {
          child.kill("SIGKILL");
        } catch {}
      }
      setTimeout(() => process.exit(0), 1000);
    }, 15000).unref();
  } else {
    process.exit(0);
  }
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("uncaughtException", (err) => {
  logErr(
    `uncaught: ${err instanceof Error ? err.message : "unknown"} — exiting for PM2 restart`,
  );
  process.exit(1);
});

setInterval(() => {
  if (!shuttingDown) log(`alive (pi pid=${child?.pid ?? "?"})`);
}, HEARTBEAT_MS).unref();

start();
