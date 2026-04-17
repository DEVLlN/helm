import type { JSONValue } from "./types.js";

const DEFAULT_PREFERRED_KEYS = [
  "text",
  "content",
  "message",
  "summary",
  "markdown",
  "reason",
  "output",
  "result",
  "stdout",
  "stderr",
  "aggregatedOutput",
  "query",
];

const METADATA_KEYS = new Set([
  "type",
  "kind",
  "id",
  "status",
  "phase",
  "role",
  "index",
  "timestamp",
  "createdAt",
  "updatedAt",
]);

export function extractReadableText(
  value: JSONValue | undefined,
  preferredKeys: string[] = []
): string | null {
  const strings = collectReadableStrings(value, preferredKeys);
  if (strings.length === 0) {
    return null;
  }

  return joinReadableStrings(strings);
}

function collectReadableStrings(
  value: JSONValue | undefined,
  preferredKeys: string[]
): string[] {
  if (value == null) {
    return [];
  }

  if (typeof value === "string") {
    return value.trim().length > 0 ? [value] : [];
  }

  if (Array.isArray(value)) {
    return value.flatMap((entry) => collectReadableStrings(entry, preferredKeys));
  }

  if (typeof value !== "object") {
    return [];
  }

  const keysToSearch = [...preferredKeys, ...DEFAULT_PREFERRED_KEYS];
  const prioritized: string[] = [];
  for (const key of keysToSearch) {
    const candidate = value[key];
    if (candidate === undefined) {
      continue;
    }
    prioritized.push(...collectReadableStrings(candidate, preferredKeys));
  }
  if (prioritized.length > 0) {
    return deduplicatedStrings(prioritized);
  }

  const fallback: string[] = [];
  for (const [key, nested] of Object.entries(value)) {
    if (METADATA_KEYS.has(key)) {
      continue;
    }
    fallback.push(...collectReadableStrings(nested, preferredKeys));
  }
  return deduplicatedStrings(fallback);
}

function deduplicatedStrings(strings: string[]): string[] {
  const result: string[] = [];
  for (const value of strings) {
    const trimmed = value.trim();
    if (!trimmed) {
      continue;
    }
    if (result[result.length - 1]?.trim() == trimmed) {
      continue;
    }
    result.push(value);
  }
  return result;
}

function joinReadableStrings(strings: string[]): string {
  var result = "";

  for (const current of strings) {
    if (!result) {
      result = current;
      continue;
    }

    const previousChar = result[result.length - 1];
    const nextChar = current[0];
    const separator = shouldInsertBlankLine(previousChar, nextChar) ? "\n\n" : "\n";
    result += separator + current;
  }

  return result;
}

function shouldInsertBlankLine(previousChar: string | undefined, nextChar: string | undefined): boolean {
  if (!previousChar || !nextChar) {
    return false;
  }

  if (previousChar === "\n" || nextChar === "\n") {
    return false;
  }

  if (nextChar === "-" || nextChar === "*" || /\d/.test(nextChar)) {
    return false;
  }

  return /[.!?:]$/.test(previousChar);
}
