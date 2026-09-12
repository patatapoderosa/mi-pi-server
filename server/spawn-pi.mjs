import { spawn } from "node:child_process";

const RPC_ARGS = ["--mode", "rpc"];

/**
 * Build a Windows-correct spawn invocation for the Pi CLI.
 *
 * Background: on Windows, Node's child_process.spawn uses CreateProcess,
 * which cannot execute .cmd/.bat shims (npm's `pi.cmd`) directly — the
 * spawn fails with ENOENT even when the file exists. The officially correct
 * route is cmd.exe /d /s /c with ONE verbatim tail: cmd's /S rule strips the
 * OUTER quote pair, the INNER quoted exe (paths with spaces survive) plus
 * fixed args remain. Node must not re-quote -> windowsVerbatimArguments.
 *
 * @param {string} piBin - trusted local path (runtime-env.json) or bare name.
 *   NEVER remote input: only fixed literals (--mode rpc) cross the shell.
 * @param {string} [platform] - injectable for tests (defaults to process.platform).
 * @param {string[]} [extraArgs] - fixed literals appended after the binary (defaults to --mode rpc). Caller allowlists every element; never remote input.
 * @returns {{ command: string, args: string[], windowsVerbatimArguments: boolean }}
 */
export function buildPiSpawn(piBin, platform = process.platform, extraArgs = RPC_ARGS) {
  const bin = piBin && piBin.length > 0 ? piBin : "pi";
  const tail = Array.isArray(extraArgs) ? extraArgs : RPC_ARGS;
  if (platform === "win32" && !/\.(exe|com)$/i.test(bin)) {
    const comspec = process.env.ComSpec ?? "C:\\Windows\\System32\\cmd.exe";
    return {
      command: comspec,
      args: ["/d", "/s", "/c", `""${bin}" ${tail.join(" ")}"`],
      windowsVerbatimArguments: true,
    };
  }
  return {
    command: bin,
    args: [...tail],
    windowsVerbatimArguments: false,
  };
}

/**
 * Spawn `pi --mode rpc` the same way the daemon does (single production path,
 * exercised by tests with a real temp .cmd on Windows).
 */
export function spawnPi(piBin, options = {}) {
  const spec = buildPiSpawn(piBin);
  const child = spawn(spec.command, spec.args, {
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
    windowsVerbatimArguments: !!spec.windowsVerbatimArguments,
    ...options,
  });
  child.__piCmdWrapper = !!spec.windowsVerbatimArguments;
  return child;
}

/**
 * Stop a pi child started via spawnPi. On win32 the child may be a cmd.exe
 * wrapper (batch runs pi as a GRANDCHILD): plain kill() would orphan pi, so
 * taskkill /T /F takes down the whole tree first, then kill() finishes the
 * wrapper itself. Best-effort, never throws (shutdown path).
 */
export function stopPi(child, signal) {
  try {
    if (!child || child.exitCode !== null) return;
    if (
      process.platform === "win32" &&
      child.__piCmdWrapper === true &&
      Number.isInteger(child.pid)
    ) {
      try {
        spawn("taskkill", ["/pid", String(child.pid), "/T", "/F"], {
          stdio: "ignore",
          windowsHide: true,
        });
      } catch {
        /* fall through to kill() */
      }
    }
    try {
      child.kill(signal);
    } catch {
      /* already gone */
    }
  } catch {
    /* shutdown path is best-effort */
  }
}
