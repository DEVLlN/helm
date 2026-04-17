import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

export type SessionLaunchOptions = {
  backendId: string;
  modelDefault: string | null;
  modelOptions: string[];
  effortOptions: string[];
  effortDefault: string | null;
  codexFastDefault: boolean | null;
  claudeContextOptions: string[];
  claudeContextDefault: string | null;
};

const CODEX_EFFORT_OPTIONS = ["none", "minimal", "low", "medium", "high", "xhigh"];
const CLAUDE_EFFORT_OPTIONS = ["low", "medium", "high", "max"];
const CLAUDE_CONTEXT_OPTIONS = ["normal", "1m"];
const CLAUDE_ALIAS_MODEL_OPTIONS = ["opus", "sonnet"];
const GEMMA_MODEL_OPTIONS = ["gemma4", "gemma3:27b", "gemma3:12b"];
const QWEN_MODEL_OPTIONS = ["qwen3.5", "qwen3:32b", "qwen3:14b"];

let cachedCodexModelOptions: string[] | null = null;
let cachedClaudeModelOptions: string[] | null = null;

function codexConfigPath(): string {
  return path.join(homedir(), ".codex", "config.toml");
}

function claudeSettingsPath(): string {
  return path.join(homedir(), ".claude", "settings.json");
}

function readOptionalFile(filePath: string): string | null {
  if (!existsSync(filePath)) {
    return null;
  }

  try {
    return readFileSync(filePath, "utf8");
  } catch {
    return null;
  }
}

function readOptionalBinary(filePath: string | null): string | null {
  if (!filePath || !existsSync(filePath)) {
    return null;
  }

  try {
    return readFileSync(filePath).toString("latin1");
  } catch {
    return null;
  }
}

function resolveInstalledBinary(candidates: string[]): string | null {
  for (const candidate of candidates) {
    if (!existsSync(candidate)) {
      continue;
    }

    try {
      return realpathSync(candidate);
    } catch {
      return candidate;
    }
  }

  return null;
}

function parseTopLevelTomlString(raw: string | null, key: string): string | null {
  if (!raw) {
    return null;
  }

  const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = raw.match(new RegExp(`^${escapedKey}\\s*=\\s*"([^"]*)"`, "m"));
  return match?.[1]?.trim() || null;
}

function stripClaudeContextSuffix(value: string): string {
  return value.trim().replace(/\[1m\]$/i, "");
}

function parseClaudeSettings(): { modelDefault: string | null; effortDefault: string | null } {
  const raw = readOptionalFile(claudeSettingsPath());
  if (!raw) {
    return {
      modelDefault: "opus",
      effortDefault: null,
    };
  }

  try {
    const parsed = JSON.parse(raw) as {
      model?: unknown;
      env?: unknown;
    };
    const modelValue = typeof parsed.model === "string" ? normalizeClaudeModel(parsed.model) : "opus";
    return {
      modelDefault: modelValue,
      effortDefault: null,
    };
  } catch {
    return {
      modelDefault: "opus",
      effortDefault: null,
    };
  }
}

function normalizeClaudeModel(value: string): string {
  const trimmed = stripClaudeContextSuffix(value);
  if (!trimmed) {
    return "opus";
  }
  return trimmed;
}

function uniqueNonEmpty(values: Array<string | null | undefined>): string[] {
  return Array.from(
    new Set(
      values
        .map((value) => value?.trim())
        .filter((value): value is string => Boolean(value))
    )
  );
}

function codexBinaryPath(): string | null {
  return resolveInstalledBinary([
    "/usr/local/bin/codex",
    path.join(homedir(), ".local", "bin", "codex"),
  ]);
}

function claudeBinaryPath(): string | null {
  return resolveInstalledBinary([
    path.join(homedir(), ".local", "bin", "claude"),
    "/usr/local/bin/claude",
  ]);
}

function discoverCodexModelOptions(): string[] {
  if (cachedCodexModelOptions) {
    return cachedCodexModelOptions;
  }

  const binary = readOptionalBinary(codexBinaryPath());
  if (!binary) {
    cachedCodexModelOptions = [];
    return cachedCodexModelOptions;
  }

  const slugMatches = Array.from(binary.matchAll(/"slug":\s*"([^"]+)"/g), (match) => match[1]);
  const extraModelMatches = Array.from(
    binary.matchAll(/\bgpt-(?:5(?:\.[0-9]+)?(?:-[a-z0-9]+)*|oss-\d+b)\b/g),
    (match) => match[0]
  ).filter((model) => {
    return model === "gpt-5.4-pro" || model === "gpt-5-mini" || model === "gpt-5-nano";
  });

  cachedCodexModelOptions = uniqueNonEmpty([...slugMatches, ...extraModelMatches]).filter((model) => {
    return model !== "gpt-5.x";
  });

  return cachedCodexModelOptions;
}

function normalizeDiscoveredClaudeModel(value: string): string | null {
  const trimmed = stripClaudeContextSuffix(value).toLowerCase();
  if (!trimmed || trimmed.endsWith("-")) {
    return null;
  }

  return trimmed
    .replace(/-v\d+$/i, "")
    .replace(/(\d)\.(\d)/g, "$1-$2");
}

function discoverClaudeModelOptions(): string[] {
  if (cachedClaudeModelOptions) {
    return cachedClaudeModelOptions;
  }

  const binary = readOptionalBinary(claudeBinaryPath());
  if (!binary) {
    cachedClaudeModelOptions = CLAUDE_ALIAS_MODEL_OPTIONS;
    return cachedClaudeModelOptions;
  }

  const matches = Array.from(
    binary.matchAll(/\bclaude-(?:opus|sonnet)-\d(?:[-.]\d+)*(?:-\d{8})?(?:-v\d+)?\b/gi),
    (match) => normalizeDiscoveredClaudeModel(match[0])
  );

  cachedClaudeModelOptions = uniqueNonEmpty([...CLAUDE_ALIAS_MODEL_OPTIONS, ...matches]);
  return cachedClaudeModelOptions;
}

export function sessionLaunchOptionsForBackend(backendId: string): SessionLaunchOptions {
  switch (backendId) {
    case "grok": {
      return {
        backendId,
        modelDefault: null,
        modelOptions: [],
        effortOptions: [],
        effortDefault: null,
        codexFastDefault: null,
        claudeContextOptions: [],
        claudeContextDefault: null,
      };
    }
    case "local-gemma-4": {
      const modelDefault = process.env.HELM_GEMMA_MODEL?.trim() || "gemma4";
      return {
        backendId,
        modelDefault,
        modelOptions: uniqueNonEmpty([modelDefault, ...GEMMA_MODEL_OPTIONS]),
        effortOptions: [],
        effortDefault: null,
        codexFastDefault: null,
        claudeContextOptions: [],
        claudeContextDefault: null,
      };
    }
    case "local-qwen-3.5": {
      const modelDefault = process.env.HELM_QWEN_MODEL?.trim() || "qwen3.5";
      return {
        backendId,
        modelDefault,
        modelOptions: uniqueNonEmpty([modelDefault, ...QWEN_MODEL_OPTIONS]),
        effortOptions: [],
        effortDefault: null,
        codexFastDefault: null,
        claudeContextOptions: [],
        claudeContextDefault: null,
      };
    }
    case "claude-code": {
      const claude = parseClaudeSettings();
      return {
        backendId,
        modelDefault: claude.modelDefault,
        modelOptions: uniqueNonEmpty([claude.modelDefault, ...discoverClaudeModelOptions()]),
        effortOptions: CLAUDE_EFFORT_OPTIONS,
        effortDefault: claude.effortDefault,
        codexFastDefault: null,
        claudeContextOptions: CLAUDE_CONTEXT_OPTIONS,
        claudeContextDefault: "normal",
      };
    }
    case "codex":
    default: {
      const raw = readOptionalFile(codexConfigPath());
      const modelDefault = parseTopLevelTomlString(raw, "model") ?? "gpt-5.4";
      const modelProvider = parseTopLevelTomlString(raw, "model_provider");
      const serviceTier = parseTopLevelTomlString(raw, "service_tier");
      const discoveredModels = discoverCodexModelOptions().filter((model) => {
        return modelProvider === "oss" || !model.startsWith("gpt-oss-");
      });
      return {
        backendId: "codex",
        modelDefault,
        modelOptions: uniqueNonEmpty([modelDefault, ...discoveredModels]),
        effortOptions: CODEX_EFFORT_OPTIONS,
        effortDefault: parseTopLevelTomlString(raw, "model_reasoning_effort"),
        codexFastDefault: serviceTier == null ? null : serviceTier === "fast",
        claudeContextOptions: [],
        claudeContextDefault: null,
      };
    }
  }
}
