export type JSONValue =
  | string
  | number
  | boolean
  | null
  | JSONValue[]
  | { [key: string]: JSONValue };

export type JSONRPCId = string | number;

export type TurnDeliveryMode = "queue" | "steer" | "interrupt";

export type StartTurnImageAttachment = {
  path: string;
  filename?: string;
  mimeType?: string;
};

export type StartTurnFileAttachment = {
  path: string;
  filename?: string;
  mimeType?: string;
};

export type StartTurnOptions = {
  deliveryMode?: TurnDeliveryMode;
  imageAttachments?: StartTurnImageAttachment[];
  fileAttachments?: StartTurnFileAttachment[];
};

export type JSONRPCRequest = {
  id: JSONRPCId;
  method: string;
  params?: JSONValue;
};

export type JSONRPCResponse = {
  id: JSONRPCId;
  result?: JSONValue;
  error?: {
    code: number;
    message: string;
    data?: JSONValue;
  };
};

export type JSONRPCNotification = {
  method: string;
  params?: JSONValue;
};

export type JSONRPCServerRequest = {
  id: JSONRPCId;
  method: string;
  params?: JSONValue;
};

export type JSONRPCMessage = JSONRPCRequest | JSONRPCResponse | JSONRPCNotification | JSONRPCServerRequest;

export type ThreadSummary = {
  id: string;
  name: string | null;
  preview: string;
  cwd: string;
  workspacePath?: string | null;
  status: string;
  updatedAt: number;
  sourceKind: string | null;
  launchSource?: string | null;
  backendId: string;
  backendLabel: string;
  backendKind: string;
  controller: ThreadController | null;
};

export type BackendCapabilities = {
  threadListing: boolean;
  threadCreation: boolean;
  turnExecution: boolean;
  turnInterrupt: boolean;
  approvals: boolean;
  planMode: boolean;
  voiceCommand: boolean;
  realtimeVoice: boolean;
  hooksAndSkillsParity: boolean;
  sharedThreadHandoff: boolean;
};

export type BackendCommandRouting = "threadTurns" | "providerChat" | "hybrid";
export type BackendApprovalSemantics = "bridgeDecisions" | "providerManaged" | "none";
export type BackendHandoffSemantics = "sharedThread" | "sessionResume" | "isolated";
export type BackendVoiceInputSemantics = "localSpeech" | "bridgeRealtime" | "providerNative" | "unsupported";
export type BackendVoiceOutputSemantics = "bridgeSpeech" | "bridgeRealtime" | "providerNative" | "none";

export type BackendCommandSemantics = {
  routing: BackendCommandRouting;
  approvals: BackendApprovalSemantics;
  handoff: BackendHandoffSemantics;
  voiceInput: BackendVoiceInputSemantics;
  voiceOutput: BackendVoiceOutputSemantics;
  supportsCommandFollowups: boolean;
  notes: string;
};

export type BackendSummary = {
  id: string;
  label: string;
  kind: string;
  description: string;
  isDefault: boolean;
  available: boolean;
  availabilityDetail?: string;
  capabilities: BackendCapabilities;
  command: BackendCommandSemantics;
};

export type CommandModeDriverSummary = {
  id: string;
  label: string;
  kind: "openai" | "custom";
  model: string;
  available: boolean;
  availabilityDetail?: string;
};

export type CommandModeSummary = {
  driver: CommandModeDriverSummary;
  routing: BackendCommandRouting;
  voiceProviderId?: string;
  voiceProviderLabel?: string;
  notes: string;
};

export type ConversationEvent = {
  method: string;
  params?: JSONValue;
};

export type ServerRequestEvent = {
  id: JSONRPCId;
  method: string;
  params?: JSONValue;
};

export type ThreadController = {
  clientId: string;
  clientName: string;
  claimedAt: number;
  lastSeenAt: number;
};

export type RuntimePhase = "idle" | "running" | "waitingApproval" | "blocked" | "completed" | "unknown";

export type RuntimeActivityEvent = {
  id: string;
  threadId: string;
  turnId: string | null;
  itemId: string | null;
  method: string;
  title: string;
  detail: string | null;
  phase: RuntimePhase;
  createdAt: number;
};

export type ApprovalKind = "command" | "fileChange" | "permissions";

export type PendingApproval = {
  requestId: string;
  threadId: string;
  turnId: string | null;
  itemId: string | null;
  kind: ApprovalKind;
  title: string;
  detail: string | null;
  requestedAt: number;
  canRespond: boolean;
  supportsAcceptForSession: boolean;
};

export type RuntimeThreadState = {
  threadId: string;
  phase: RuntimePhase;
  currentTurnId: string | null;
  title: string | null;
  detail: string | null;
  lastUpdatedAt: number;
  pendingApprovals: PendingApproval[];
  recentEvents: RuntimeActivityEvent[];
};

export type ThreadDetailItem = {
  id: string;
  turnId: string | null;
  type: string;
  title: string;
  detail: string | null;
  status: string | null;
  rawText: string | null;
  metadataSummary: string | null;
  command: string | null;
  cwd: string | null;
  exitCode: number | null;
};

export type ThreadDetailTurn = {
  id: string;
  status: string;
  error: string | null;
  items: ThreadDetailItem[];
};

export type ThreadDetail = {
  id: string;
  name: string | null;
  cwd: string;
  workspacePath?: string | null;
  status: string;
  updatedAt: number;
  sourceKind: string | null;
  launchSource: string | null;
  backendId: string;
  backendLabel: string;
  backendKind: string;
  command: BackendCommandSemantics;
  affordances: ThreadCommandAffordances;
  turns: ThreadDetailTurn[];
};

export type ThreadCommandAffordances = {
  canSendTurns: boolean;
  canInterrupt: boolean;
  canRespondToApprovals: boolean;
  canUseRealtimeCommand: boolean;
  showsOperationalSnapshot: boolean;
  sessionAccess: "helmManagedShell" | "cliAttach" | "editorResume" | "sharedThread";
  notes: string;
};

export type ControlRequest = {
  clientId: string;
  clientName?: string;
  force?: boolean;
};

export type ApprovalDecisionRequest = {
  decision: "accept" | "acceptForSession" | "decline" | "cancel";
};

export type VoiceCommandRequest = {
  threadId: string;
  text: string;
  clientId?: string;
  clientName?: string;
  style?: "codex" | "concise" | "formal" | "jarvis";
};

export type VoiceCommandResponse = {
  acknowledgement: string;
  displayResponse: string;
  spokenResponse: string | null;
  shouldResumeListening: boolean;
  backend: BackendSummary;
  commandMode?: CommandModeSummary;
  result?: JSONValue;
};

export type VoiceSpeechRequest = {
  text: string;
  threadId?: string;
  backendId?: string;
  voiceProviderId?: string;
  style?: "codex" | "concise" | "formal" | "jarvis";
};
