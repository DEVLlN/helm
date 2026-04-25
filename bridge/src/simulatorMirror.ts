import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export type BootedSimulator = {
  udid: string;
  name: string;
  runtime: string;
  state: "Booted";
};

export type SimulatorAccessibilityFrame = {
  x: number;
  y: number;
  width: number;
  height: number;
};

export type SimulatorAccessibilityElement = {
  id: string;
  role: string;
  name: string | null;
  description: string | null;
  frame: SimulatorAccessibilityFrame;
  normalizedFrame: SimulatorAccessibilityFrame;
};

export type SimulatorAccessibilitySnapshot = {
  screenFrame: SimulatorAccessibilityFrame;
  elements: SimulatorAccessibilityElement[];
};

export function parseBootedSimulators(output: string): BootedSimulator[] {
  const simulators: BootedSimulator[] = [];
  let currentRuntime = "";

  for (const line of output.split(/\r?\n/)) {
    const runtimeMatch = line.match(/^--\s+(.+?)\s+--$/);
    if (runtimeMatch) {
      currentRuntime = runtimeMatch[1]?.trim() ?? "";
      continue;
    }

    const deviceMatch = line.match(/^\s*(.+?)\s+\(([0-9A-F-]{36})\)\s+\((Booted)\)\s*$/i);
    if (!deviceMatch) {
      continue;
    }

    const [, name, udid, state] = deviceMatch;
    if (!name || !udid || state !== "Booted") {
      continue;
    }

    simulators.push({
      udid,
      name: name.trim(),
      runtime: currentRuntime,
      state: "Booted",
    });
  }

  return simulators;
}

export async function listBootedSimulators(): Promise<BootedSimulator[]> {
  const { stdout } = await execFileAsync(
    "xcrun",
    ["simctl", "list", "devices"],
    { maxBuffer: 1024 * 1024 }
  );
  return parseBootedSimulators(stdout);
}

export async function captureSimulatorScreenshot(udid: string): Promise<Buffer> {
  const tempDir = await mkdtemp(path.join(tmpdir(), "helm-sim-mirror-"));
  const screenshotPath = path.join(tempDir, "frame.png");

  try {
    await execFileAsync(
      "xcrun",
      ["simctl", "io", udid, "screenshot", "--type=png", screenshotPath],
      { maxBuffer: 1024 * 1024 }
    );
    return await readFile(screenshotPath);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

export async function listSimulatorAccessibilityElements(): Promise<SimulatorAccessibilitySnapshot> {
  const { stdout } = await execFileAsync(
    "swift",
    ["-e", SIMULATOR_ACCESSIBILITY_SWIFT],
    { maxBuffer: 4 * 1024 * 1024 }
  );
  return parseSimulatorAccessibilitySnapshot(stdout);
}

export function parseSimulatorAccessibilitySnapshot(output: string): SimulatorAccessibilitySnapshot {
  const rawElements = output
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter(Boolean)
    .map(parseAccessibilityLine)
    .filter((element): element is Omit<SimulatorAccessibilityElement, "id" | "normalizedFrame"> => element !== null);

  const screenFrame = simulatorScreenFrame(rawElements);
  const seen = new Set<string>();
  const seenLargeActionLabels = new Set<string>();
  const elements: SimulatorAccessibilityElement[] = [];

  for (const element of rawElements) {
    if (!isSelectableAccessibilityElement(element)) {
      continue;
    }

    const normalizedFrame = normalizeFrame(element.frame, screenFrame);
    if (!normalizedFrame) {
      continue;
    }

    const label = element.description ?? element.name ?? "";
    const largeActionKey = largeActionDuplicateKey(element.role, label, normalizedFrame);
    if (largeActionKey) {
      if (seenLargeActionLabels.has(largeActionKey)) {
        continue;
      }
      seenLargeActionLabels.add(largeActionKey);
    }

    const identity = [
      element.role,
      label,
      Math.round(normalizedFrame.x * 1000),
      Math.round(normalizedFrame.y * 1000),
      Math.round(normalizedFrame.width * 1000),
      Math.round(normalizedFrame.height * 1000),
    ].join("|");
    if (seen.has(identity)) {
      continue;
    }
    seen.add(identity);

    elements.push({
      ...element,
      id: `ax-${elements.length + 1}`,
      normalizedFrame,
    });
  }

  return {
    screenFrame,
    elements: elements
      .sort((left, right) => frameArea(right.frame) - frameArea(left.frame))
      .slice(0, 180),
  };
}

function largeActionDuplicateKey(
  role: string,
  label: string,
  frame: SimulatorAccessibilityFrame
): string | null {
  if (role !== "AXButton") {
    return null;
  }

  if (label.length < 80) {
    return null;
  }

  if (frame.width < 0.5 || frame.height < 0.08) {
    return null;
  }

  return `${role}|${label.replace(/\s+/g, " ").trim()}`;
}

function parseAccessibilityLine(line: string): Omit<SimulatorAccessibilityElement, "id" | "normalizedFrame"> | null {
  const fields = line.split("\t");
  if (fields.length !== 7) {
    return null;
  }

  const [role, name, description, xText, yText, widthText, heightText] = fields;
  const x = Number(xText);
  const y = Number(yText);
  const width = Number(widthText);
  const height = Number(heightText);
  if (
    !role ||
    !Number.isFinite(x) ||
    !Number.isFinite(y) ||
    !Number.isFinite(width) ||
    !Number.isFinite(height) ||
    width <= 0 ||
    height <= 0
  ) {
    return null;
  }

  return {
    role,
    name: emptyToNull(name),
    description: emptyToNull(description),
    frame: { x, y, width, height },
  };
}

function simulatorScreenFrame(
  elements: Array<Omit<SimulatorAccessibilityElement, "id" | "normalizedFrame">>
): SimulatorAccessibilityFrame {
  const candidates = elements
    .filter((element) => {
      const ratio = element.frame.width / element.frame.height;
      return element.role === "AXGroup" &&
        element.frame.width >= 250 &&
        element.frame.height >= 500 &&
        ratio >= 0.35 &&
        ratio <= 0.65;
    })
    .sort((left, right) => frameArea(right.frame) - frameArea(left.frame));

  return candidates[0]?.frame ?? { x: 0, y: 0, width: 1, height: 1 };
}

function isSelectableAccessibilityElement(
  element: Omit<SimulatorAccessibilityElement, "id" | "normalizedFrame">
): boolean {
  if (frameArea(element.frame) < 36) {
    return false;
  }

  if (element.description === "group" || element.description === "toolbar") {
    return false;
  }

  return [
    "AXButton",
    "AXTextField",
    "AXStaticText",
    "AXHeading",
    "AXImage",
    "AXGenericElement",
    "AXSlider",
    "AXScrollArea",
  ].includes(element.role);
}

function normalizeFrame(
  frame: SimulatorAccessibilityFrame,
  screenFrame: SimulatorAccessibilityFrame
): SimulatorAccessibilityFrame | null {
  const left = Math.max(frame.x, screenFrame.x);
  const top = Math.max(frame.y, screenFrame.y);
  const right = Math.min(frame.x + frame.width, screenFrame.x + screenFrame.width);
  const bottom = Math.min(frame.y + frame.height, screenFrame.y + screenFrame.height);
  const width = right - left;
  const height = bottom - top;
  if (width <= 0 || height <= 0) {
    return null;
  }

  return {
    x: (left - screenFrame.x) / screenFrame.width,
    y: (top - screenFrame.y) / screenFrame.height,
    width: width / screenFrame.width,
    height: height / screenFrame.height,
  };
}

function frameArea(frame: SimulatorAccessibilityFrame): number {
  return frame.width * frame.height;
}

function emptyToNull(value: string | undefined): string | null {
  const trimmed = value?.trim() ?? "";
  return trimmed.length > 0 ? trimmed : null;
}

const SIMULATOR_ACCESSIBILITY_SWIFT = String.raw`
import AppKit
import ApplicationServices

struct ElementRecord {
  let role: String
  let title: String
  let description: String
  let frame: CGRect
}

func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
    return ""
  }
  return value as? String ?? ""
}

func elementFrame(_ element: AXUIElement) -> CGRect? {
  var positionRef: CFTypeRef?
  var sizeRef: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
        let positionValue = positionRef,
        let sizeValue = sizeRef,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID()
  else {
    return nil
  }

  var position = CGPoint.zero
  var size = CGSize.zero
  AXValueGetValue((positionValue as! AXValue), .cgPoint, &position)
  AXValueGetValue((sizeValue as! AXValue), .cgSize, &size)
  guard size.width > 0, size.height > 0 else { return nil }
  return CGRect(origin: position, size: size)
}

func childElements(_ element: AXUIElement) -> [AXUIElement] {
  for attribute in [kAXVisibleChildrenAttribute as CFString, kAXChildrenAttribute as CFString] {
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
       let children = value as? [AXUIElement] {
      return children
    }
  }
  return []
}

func clean(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\t", with: " ")
    .replacingOccurrences(of: "\n", with: " ")
    .replacingOccurrences(of: "\r", with: " ")
}

guard let simulator = NSWorkspace.shared.runningApplications.first(where: {
  $0.bundleIdentifier == "com.apple.iphonesimulator" || $0.localizedName == "Simulator"
}) else {
  exit(2)
}

let application = AXUIElementCreateApplication(simulator.processIdentifier)
var windowsRef: CFTypeRef?
guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsRef) == .success,
      let windows = windowsRef as? [AXUIElement],
      let window = windows.first
else {
  exit(3)
}

var records: [ElementRecord] = []
var visitedCount = 0

func walk(_ element: AXUIElement, depth: Int) {
  guard visitedCount <= 700, depth <= 10 else { return }
  visitedCount += 1
  let role = stringAttribute(element, kAXRoleAttribute as CFString)
  let title = stringAttribute(element, kAXTitleAttribute as CFString)
  let description = stringAttribute(element, kAXDescriptionAttribute as CFString)
  if let frame = elementFrame(element) {
    records.append(ElementRecord(role: role, title: title, description: description, frame: frame))
  }
  for child in childElements(element) {
    walk(child, depth: depth + 1)
  }
}

walk(window, depth: 0)

for record in records {
  print([
    clean(record.role),
    clean(record.title),
    clean(record.description),
    String(Int(record.frame.minX.rounded())),
    String(Int(record.frame.minY.rounded())),
    String(Int(record.frame.width.rounded())),
    String(Int(record.frame.height.rounded())),
  ].joined(separator: "\t"))
}
`;
