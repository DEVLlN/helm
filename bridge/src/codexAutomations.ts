import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

import type { CodexAutomationSummary, CreateCodexAutomationRequest } from "./types.js";

type TomlValue = string | number | string[];

const DAY_NAMES: Record<string, string> = {
  MO: "Monday",
  TU: "Tuesday",
  WE: "Wednesday",
  TH: "Thursday",
  FR: "Friday",
  SA: "Saturday",
  SU: "Sunday",
};

function codexAutomationsDir(): string {
  return process.env.CODEX_AUTOMATIONS_DIR?.trim()
    || path.join(homedir(), ".codex", "automations");
}

function parseTomlString(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed.startsWith("\"") || !trimmed.endsWith("\"")) {
    return null;
  }

  let result = "";
  for (let index = 1; index < trimmed.length - 1; index += 1) {
    const char = trimmed[index];
    if (char !== "\\") {
      result += char;
      continue;
    }

    index += 1;
    const escaped = trimmed[index];
    switch (escaped) {
      case "b":
        result += "\b";
        break;
      case "t":
        result += "\t";
        break;
      case "n":
        result += "\n";
        break;
      case "f":
        result += "\f";
        break;
      case "r":
        result += "\r";
        break;
      case "\"":
      case "\\":
        result += escaped;
        break;
      default:
        result += escaped ?? "";
        break;
    }
  }

  return result;
}

function splitTomlArrayItems(raw: string): string[] {
  const trimmed = raw.trim();
  if (!trimmed.startsWith("[") || !trimmed.endsWith("]")) {
    return [];
  }

  const body = trimmed.slice(1, -1);
  const items: string[] = [];
  let current = "";
  let quoted = false;
  let escaping = false;

  for (const char of body) {
    if (escaping) {
      current += `\\${char}`;
      escaping = false;
      continue;
    }

    if (char === "\\" && quoted) {
      escaping = true;
      continue;
    }

    if (char === "\"") {
      quoted = !quoted;
      current += char;
      continue;
    }

    if (char === "," && !quoted) {
      items.push(current.trim());
      current = "";
      continue;
    }

    current += char;
  }

  if (current.trim()) {
    items.push(current.trim());
  }
  return items;
}

function parseTomlStringArray(raw: string): string[] | null {
  const values = splitTomlArrayItems(raw)
    .map(parseTomlString)
    .filter((value): value is string => value !== null);
  return values.length > 0 ? values : [];
}

export function parseCodexAutomationToml(text: string, sourcePath = ""): CodexAutomationSummary | null {
  const values = new Map<string, TomlValue>();
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) {
      continue;
    }

    const separatorIndex = line.indexOf("=");
    if (separatorIndex <= 0) {
      continue;
    }

    const key = line.slice(0, separatorIndex).trim();
    const rawValue = line.slice(separatorIndex + 1).trim();
    const stringValue = parseTomlString(rawValue);
    if (stringValue !== null) {
      values.set(key, stringValue);
      continue;
    }

    if (rawValue.startsWith("[")) {
      values.set(key, parseTomlStringArray(rawValue) ?? []);
      continue;
    }

    const numberValue = Number(rawValue);
    if (Number.isFinite(numberValue)) {
      values.set(key, numberValue);
    }
  }

  const id = stringValue(values.get("id"));
  const name = stringValue(values.get("name")) ?? id;
  if (!id || !name) {
    return null;
  }

  const prompt = stringValue(values.get("prompt")) ?? "";
  const cwds = stringArrayValue(values.get("cwds"));
  const rrule = stringValue(values.get("rrule"));
  const kind = stringValue(values.get("kind")) ?? "manual";
  return {
    id,
    name,
    kind,
    status: stringValue(values.get("status")) ?? "UNKNOWN",
    schedule: rrule,
    scheduleSummary: automationScheduleSummary(kind, rrule),
    model: stringValue(values.get("model")),
    reasoningEffort: stringValue(values.get("reasoning_effort")),
    executionEnvironment: stringValue(values.get("execution_environment")),
    cwds,
    cwd: cwds[0] ?? null,
    prompt,
    promptPreview: promptPreview(prompt),
    createdAt: numberValue(values.get("created_at")),
    updatedAt: numberValue(values.get("updated_at")),
    sourcePath,
  };
}

export async function listCodexAutomations(): Promise<CodexAutomationSummary[]> {
  const root = codexAutomationsDir();
  let entries: Array<{ isDirectory(): boolean; name: string }>;
  try {
    entries = (await readdir(root, { withFileTypes: true })).map((entry) => ({
      isDirectory: () => entry.isDirectory(),
      name: String(entry.name),
    }));
  } catch {
    return [];
  }

  const automations: CodexAutomationSummary[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }

    const sourcePath = path.join(root, entry.name, "automation.toml");
    try {
      const automation = parseCodexAutomationToml(await readFile(sourcePath, "utf8"), sourcePath);
      if (automation) {
        automations.push(automation);
      }
    } catch {
      // A partially-written automation should not hide the rest of the list.
    }
  }

  return automations.sort(automationPrecedes);
}

export async function createCodexAutomation(input: CreateCodexAutomationRequest): Promise<CodexAutomationSummary> {
  const name = input.name.trim();
  const prompt = input.prompt.trim();
  const rrule = input.rrule.trim();
  if (!name) {
    throw new Error("Automation name is required");
  }
  if (!prompt) {
    throw new Error("Automation prompt is required");
  }
  if (!rrule) {
    throw new Error("Automation schedule is required");
  }

  const root = codexAutomationsDir();
  await mkdir(root, { recursive: true });

  const id = await uniqueAutomationId(root, slugify(name));
  const automationDir = path.join(root, id);
  await mkdir(automationDir, { recursive: false });

  const now = Date.now();
  const status = normalizedStatus(input.status);
  const content = [
    "version = 1",
    `id = ${tomlString(id)}`,
    `kind = "cron"`,
    `name = ${tomlString(name)}`,
    `prompt = ${tomlString(prompt)}`,
    `status = ${tomlString(status)}`,
    `rrule = ${tomlString(rrule)}`,
    optionalTomlString("model", input.model),
    optionalTomlString("reasoning_effort", input.reasoningEffort),
    optionalTomlString("execution_environment", input.executionEnvironment),
    `cwds = ${tomlStringArray(input.cwd?.trim() ? [input.cwd.trim()] : [])}`,
    `created_at = ${now}`,
    `updated_at = ${now}`,
    "",
  ].filter((line): line is string => line !== null).join("\n");

  const sourcePath = path.join(automationDir, "automation.toml");
  await writeFile(sourcePath, content, { encoding: "utf8", flag: "wx" });
  const automation = parseCodexAutomationToml(content, sourcePath);
  if (!automation) {
    throw new Error("Created automation could not be parsed");
  }
  return automation;
}

function automationPrecedes(lhs: CodexAutomationSummary, rhs: CodexAutomationSummary): number {
  const lhsActive = lhs.status.toUpperCase() === "ACTIVE";
  const rhsActive = rhs.status.toUpperCase() === "ACTIVE";
  if (lhsActive !== rhsActive) {
    return lhsActive ? -1 : 1;
  }

  const lhsUpdatedAt = lhs.updatedAt ?? 0;
  const rhsUpdatedAt = rhs.updatedAt ?? 0;
  if (lhsUpdatedAt !== rhsUpdatedAt) {
    return rhsUpdatedAt - lhsUpdatedAt;
  }

  return lhs.name.localeCompare(rhs.name, undefined, { sensitivity: "base" });
}

function automationScheduleSummary(kind: string, rrule: string | null): string {
  if (!rrule) {
    return kind === "cron" ? "Scheduled" : kind;
  }

  const parsed = Object.fromEntries(
    rrule
      .replace(/^RRULE:/i, "")
      .split(";")
      .map((part) => {
        const [key, value] = part.split("=");
        return [key, value];
      })
      .filter(([key, value]) => key && value)
  );
  const frequency = parsed.FREQ;
  const interval = Number(parsed.INTERVAL ?? "1");
  const time = formattedTime(parsed.BYHOUR, parsed.BYMINUTE);

  if (frequency === "HOURLY") {
    const base = interval > 1 ? `Every ${interval} hours` : "Hourly";
    return parsed.BYMINUTE !== undefined
      ? `${base} at minute ${String(parsed.BYMINUTE).padStart(2, "0")}`
      : base;
  }

  if (frequency === "DAILY") {
    return time ? `Daily at ${time}` : "Daily";
  }

  if (frequency === "WEEKLY") {
    const days = daySummary(parsed.BYDAY);
    if (days && time) {
      return `Weekly ${days} at ${time}`;
    }
    if (days) {
      return `Weekly ${days}`;
    }
    return time ? `Weekly at ${time}` : "Weekly";
  }

  return rrule.replace(/^RRULE:/i, "");
}

function formattedTime(hour: string | undefined, minute: string | undefined): string | null {
  if (hour === undefined) {
    return null;
  }

  const hourValue = Number(hour);
  const minuteValue = Number(minute ?? "0");
  if (!Number.isFinite(hourValue) || !Number.isFinite(minuteValue)) {
    return null;
  }

  const period = hourValue >= 12 ? "PM" : "AM";
  const displayHour = hourValue % 12 === 0 ? 12 : hourValue % 12;
  return `${displayHour}:${String(minuteValue).padStart(2, "0")} ${period}`;
}

function daySummary(value: string | undefined): string | null {
  if (!value) {
    return null;
  }

  const names = value
    .split(",")
    .map((day) => DAY_NAMES[day])
    .filter(Boolean);
  if (names.length === 7) {
    return "every day";
  }
  if (names.length === 1) {
    return names[0] ?? null;
  }
  return names.join(", ");
}

function promptPreview(prompt: string): string {
  const compact = prompt.replace(/\s+/g, " ").trim();
  if (compact.length <= 180) {
    return compact;
  }
  return `${compact.slice(0, 177).trimEnd()}...`;
}

async function uniqueAutomationId(root: string, base: string): Promise<string> {
  const cleanBase = base || "automation";
  for (let suffix = 0; suffix < 100; suffix += 1) {
    const id = suffix === 0 ? cleanBase : `${cleanBase}-${suffix + 1}`;
    try {
      await readFile(path.join(root, id, "automation.toml"), "utf8");
    } catch {
      return id;
    }
  }
  return `${cleanBase}-${Date.now()}`;
}

function slugify(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64);
}

function normalizedStatus(value: string | null | undefined): string {
  const trimmed = value?.trim().toUpperCase();
  return trimmed === "PAUSED" ? "PAUSED" : "ACTIVE";
}

function optionalTomlString(key: string, value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? `${key} = ${tomlString(trimmed)}` : null;
}

function tomlString(value: string): string {
  return `"${value
    .replace(/\\/g, "\\\\")
    .replace(/"/g, "\\\"")
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r")
    .replace(/\t/g, "\\t")}"`;
}

function tomlStringArray(values: string[]): string {
  return `[${values.map(tomlString).join(", ")}]`;
}

function stringValue(value: TomlValue | undefined): string | null {
  return typeof value === "string" ? value : null;
}

function stringArrayValue(value: TomlValue | undefined): string[] {
  return Array.isArray(value) ? value : [];
}

function numberValue(value: TomlValue | undefined): number | null {
  return typeof value === "number" ? value : null;
}
