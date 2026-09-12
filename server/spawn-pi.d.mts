import type { ChildProcess } from "node:child_process";

export declare function buildPiSpawn(
  piBin: string,
  platform?: string,
): {
  command: string;
  args: string[];
};

export declare function spawnPi(
  piBin: string,
  options?: Record<string, unknown>,
): ChildProcess;
