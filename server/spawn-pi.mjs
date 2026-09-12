import { spawn } from "node:child_process";

const RPC_ARGS = ["--mode", "rpc"];

/**
 * Build a Windows-correct spawn invocation for the Pi CLI.
 *
 * Background: on Windows, Node's child_process.spawn uses CreateProcess,
 * which cannot execute .cmd/.bat shims (npm's `pi.cmd`) directly — the
 * spawn fails with ENOENT even when the file exists. The officially correct
 * route is cmd.exe /d /s /c with the quoted executable, fixed args only.
 *
 * @param {string} piBin - trusted local path (runtime-env.json) or bare name.
 * @param {string} [platform] - injectable for tests (defaults to process.platform).
 *   NEVER remote input: only fixed literals (--mode rpc) cross the shell.
 * @returns {{ command: string, args: string[] }} ready for child_process.spawn
 *   with stdio pipe + windowsHide (caller adds its own options).
 */
export function buildPiSpawn(piBin, platform = process.platform) {
  const bin = piBin && piBin.length > 0 ? piBin : "pi";
  if (platform === "win32" && !/\.(exe|com)$/i.test(bin)) {
    const comspec =
      process.env.ComSpec ?? "C:\\Windows\\System32\\cmd.exe";
    return {
      command: comspec,
      args: ["/d", "/s", "/c", `"${bin}"`, ...RPC_ARGS],
    };
  }
  return { command: bin, args: [...RPC_ARGS] };
}

/**
 * Spawn `pi --mode rpc` the same way the daemon does (single production path,
 * exercised by tests with a real temp .cmd on Windows).
 */
export function spawnPi(piBin, options = {}) {
  const { command, args } = buildPiSpawn(piBin);
  return spawn(command, args, {
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
    ...options,
  });
}
