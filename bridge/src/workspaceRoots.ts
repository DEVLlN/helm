import { execFile } from "node:child_process";
import { realpath } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const workspacePathCache = new Map<string, Promise<string>>();

export async function resolveWorkspacePath(cwd: string): Promise<string> {
  const trimmed = cwd.trim();
  if (!trimmed) {
    return "";
  }

  const normalized = path.resolve(trimmed);
  const cached = workspacePathCache.get(normalized);
  if (cached) {
    return cached;
  }

  const promise = resolveWorkspacePathUncached(normalized);
  workspacePathCache.set(normalized, promise);
  return promise;
}

async function resolveWorkspacePathUncached(cwd: string): Promise<string> {
  const canonicalCwd = await canonicalPath(cwd);
  const gitRoot = await gitRootFor(canonicalCwd);
  return gitRoot || canonicalCwd;
}

async function canonicalPath(input: string): Promise<string> {
  try {
    return await realpath(input);
  } catch {
    return path.resolve(input);
  }
}

async function gitRootFor(cwd: string): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["-C", cwd, "rev-parse", "--show-toplevel"],
      {
        timeout: 800,
        maxBuffer: 32 * 1024,
      }
    );
    const root = stdout.trim();
    if (!root) {
      return null;
    }
    return await canonicalPath(root);
  } catch {
    return null;
  }
}
