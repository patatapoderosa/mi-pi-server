import type { ChildProcess } from "node:child_process";

export declare function buildPiSpawn(
  piBin: string,
  platform?: string,
  extraArgs?: string[],
): {
  command: string;
  args: string[];
  windowsVerbatimArguments: boolean;
};

export declare function spawnPi(
  piBin: string,
  options?: Record<string, unknown>,
): ChildProcess;

export declare function stopPi(
  child: ChildProcess | null | undefined,
  signal?: string,
): void;
