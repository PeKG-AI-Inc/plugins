/**
 * PeKG OpenCode Plugin v3.14.1
 *
 * Connects OpenCode agents to PeKG (pekg.ai) personal knowledge graph.
 * Current version is also exposed at runtime via PLUGIN_VERSION (User-Agent
 * header on every API call) and via the experimental.session.compacting
 * preserved-context block. Auto-update checks against api.pekg.ai/plugins/
 * opencode.json compare with this constant.
 *
 * Enforcement model: hooks deliver and gate, the LLM decides.
 * - chat.message / chat.messages.transform / system.transform: deliver context.
 * - tool.execute.before / permission.ask / command.execute.before: throw or deny.
 * - tool.definition: re-describe tools when blockers are active.
 *
 * BYOLLM: every model call goes through the user's session via
 * ctx.client.session.prompt; no PeKG-side inference. BYOLLM verifications
 * (blocker ack, feedback signal, compile, hive transform) run in CHILD
 * sessions spawned with parentID + a "[pekg-internal]" title so they
 * never enter the parent's hook chain or the user's TUI.
 *
 * Install:
 *   curl -o ~/.config/opencode/plugins/pekg.ts https://api.pekg.ai/plugins/opencode.ts
 */

import { type Plugin, tool } from "@opencode-ai/plugin";

// BunShell isn't re-exported from @opencode-ai/plugin's public entry, so
// pull it through Plugin's first-arg input type.
type BunShell = Parameters<Plugin>[0]["$"];

const API_BASE = "https://api.pekg.ai";
const MCP_URL = "https://mcp.pekg.ai/mcp";
const HOME = process.env.HOME || process.env.USERPROFILE || "~";
const CONFIG_PATH = `${HOME}/.pekg/config.json`;
const OPENCODE_CONFIG = `${HOME}/.config/opencode/opencode.json`;
const FEEDBACK_QUEUE_DIR = `${HOME}/.pekg/feedback-queue`;
const PLUGIN_VERSION = "3.14.1"; // 3.14.1: PEKG_OFFLINE=1 now bypasses stale persisted blocker state in rehydrateBlockerState
const SESSION_STATE_DIR = `${HOME}/.pekg/sessions`;
const PEKG_OFFLINE = process.env.PEKG_OFFLINE === "1";
const NETWORK_BLOCKER_ID = "00000000-0000-0000-0000-pekgNetworkErr";
const FILE_MUTATING_TOOLS = new Set([
  "edit",
  "write",
  "multiedit",
  "multi_edit",
  "apply_patch",
  "patch",
  "str_replace_editor",
  "str_replace_based_edit",
]);
const USER_AGENT = `opencode-pekg-plugin/${PLUGIN_VERSION}`;
const PLUGIN_INSTALL_PATH = `${HOME}/.config/opencode/plugins/pekg.ts`;
const UPDATE_CHECK_MARKER = `${HOME}/.pekg/plugin-update-check.json`;
const UPDATE_CHECK_INTERVAL_MS = 60 * 60 * 1000;
const PLUGIN_META_URL = `${API_BASE}/plugins/opencode.json`;
const PLUGIN_DOWNLOAD_URL = `${API_BASE}/plugins/opencode.ts`;

// Minimal local types for SDK response shapes — declares only what this
// file actually reads. Hook-callback signatures and BunShell come from
// the @opencode-ai/plugin types directly.
interface SessionResponse {
  data?: { id?: string; title?: string };
}

interface MessagePart {
  type: string;
  text?: string;
}

interface MessageResponse {
  data?: {
    parts?: MessagePart[];
    message?: { content?: string };
  };
}

interface ToolOutputShape {
  output?: string;
}

interface HookInput {
  command?: string;
  sessionID?: string;
  tool?: string;
  type?: string;
  toolID?: string;
  properties?: Record<string, unknown>;
}

interface PromptBody {
  parts: Array<{ type: "text"; text: string }>;
  system: string;
  model?: { providerID: string; modelID: string };
}

interface OtpResponse {
  otp: string;
  connectUrl: string;
}

interface MessageInfo {
  id?: string;
  sessionID?: string;
  role?: "user" | "assistant" | string;
  time?: { completed?: number | string };
}

interface EventProperties {
  sessionID?: string;
  info?: MessageInfo;
  path?: string;
  filePath?: string;
}

// Keyword sets for markdown-context re-tier (Issue 8) and subagent
// inheritance overlap heuristic (Issue 9). The plugin is shipped to users
// as a self-contained TS file (no bundler), so it cannot import from
// @pekg/shared. **These lists MUST stay in sync with
// packages/shared/src/code-domain.ts** — when adding/removing keywords,
// update BOTH places. Server uses the shared package for its assignTier
// CODE_DOMAIN_KEYWORDS; plugin uses this inline copy.
const _PEKG_CODE_DOMAIN_KEYWORDS = [
  "function",
  "async",
  "await",
  "hook",
  "sql",
  "query",
  "parse",
  "plugin",
  "config",
  "server",
  "route",
  "endpoint",
  "mcp",
  "opencode",
  "typescript",
  "javascript",
  "regex",
  "stream",
  "promise",
  "fetch",
  "request",
  "response",
  "schema",
  "migration",
  "react",
  "vue",
  "css",
  "ui",
  "frontend",
  "docker",
  "kubernetes",
  "redis",
  "postgres",
  "drizzle",
] as const;
const PEKG_NON_CODE_KEYWORDS = [
  "security",
  "vulnerability",
  "credential",
  "secret",
  "auth",
  "privacy",
  "pii",
  "compliance",
  "audit",
  "documentation",
  "readme",
  "changelog",
  "policy",
  "license",
] as const;
const PEKG_MARKDOWN_EXT_RE = /\.(md|mdx|txt|rst|adoc)$/i;

const FEEDBACK_COOLDOWN_MS = 30 * 1000; // Minimum time between feedback submissions
const COMPILE_COOLDOWN_MS = 60 * 1000; // Minimum time between compilation checks
const COMPILE_INTERVAL_MS = 5 * 60 * 1000; // Periodic compilation check interval
const HIVE_COOLDOWN_MS = 10 * 60 * 1000; // Minimum time between hive contributions
const INGEST_ANALYSIS_MIN_LINES = 10; // Minimum diff size to trigger ingestion prompt
const _SESSION_IDLE_TIMEOUT_MS = 30 * 1000; // Time of inactivity before session.idle fires

const CONTEXT_TOKEN_BUDGET = 4000;
const AVG_CHARS_PER_TOKEN = 4;
const _GUARANTEED_SOURCE_TYPES = ["project_config", "user_preferences"] as const;

// Full context (blockers + warnings + info + guaranteed) only on the first
// message in a session; later messages get blockers + guaranteed only.
const INJECT_FULL_CONTEXT_ON_FIRST_ONLY: boolean = process.env.PEKG_FULL_CONTEXT_EVERY_TURN !== "1";

// Cap on BYOLLM verifications per parent session; over the cap we fall back
// to the deterministic ack heuristic. Failed runs count 0.5.
const MAX_CHILD_VERIFICATIONS_PER_SESSION = Number.parseInt(process.env.PEKG_MAX_CHILD_VERIFICATIONS ?? "", 10) || 5;

// Title prefix for child sessions we spawn. Hooks early-return on it so
// the plugin never gates its own internal calls (race-free at create time,
// unlike a Set populated post-create).
const PEKG_INTERNAL_TITLE_PREFIX = "[pekg-internal]";

// Read opencode.json once at init to discover the user's small_model so
// child-session BYOLLM verifications run on the cheap model. If absent,
// we omit the model field and opencode falls back to the session default.
function loadOpencodeSmallModel(): { providerID: string; modelID: string } | null {
  try {
    const fs = require("node:fs") as typeof import("node:fs");
    const candidates = [`${HOME}/.config/opencode/opencode.json`, `${HOME}/.opencode/opencode.json`];
    for (const path of candidates) {
      if (!fs.existsSync(path)) continue;
      const cfg = JSON.parse(fs.readFileSync(path, "utf-8"));
      const sm = typeof cfg?.small_model === "string" ? cfg.small_model : "";
      if (sm.includes("/")) {
        const idx = sm.indexOf("/");
        const providerID = sm.slice(0, idx);
        const modelID = sm.slice(idx + 1);
        if (providerID && modelID) return { providerID, modelID };
      }
    }
  } catch {}
  return null;
}

// ---------------------------------------------------------------------------
// Config helpers
// ---------------------------------------------------------------------------

interface PeKGConfig {
  token: string;
  endpoint: string;
}

async function loadPeKGConfig(): Promise<PeKGConfig | null> {
  try {
    const fs = await import("node:fs");
    const raw = fs.readFileSync(CONFIG_PATH, "utf-8");
    const config = JSON.parse(raw);
    if (config.token?.startsWith("pekg_sk_")) return config;
    return null;
  } catch {
    return null;
  }
}

async function savePeKGConfig(token: string): Promise<void> {
  const fs = await import("node:fs");
  const path = await import("node:path");
  fs.mkdirSync(path.dirname(CONFIG_PATH), { recursive: true });
  fs.writeFileSync(CONFIG_PATH, JSON.stringify({ token, endpoint: MCP_URL }, null, 2));
  fs.chmodSync(CONFIG_PATH, 0o600);
}

type RegistrationResult = "unchanged" | "new" | "token_rotated" | "metadata_updated";

async function ensureMcpRegistered(token: string): Promise<RegistrationResult> {
  try {
    const fs = await import("node:fs");
    const path = await import("node:path");

    if (!fs.existsSync(OPENCODE_CONFIG)) {
      fs.mkdirSync(path.dirname(OPENCODE_CONFIG), { recursive: true });
      fs.writeFileSync(
        OPENCODE_CONFIG,
        JSON.stringify({ $schema: "https://opencode.ai/config.json", mcp: {} }, null, 2),
      );
    }

    const raw = fs.readFileSync(OPENCODE_CONFIG, "utf-8");
    const config = JSON.parse(raw);
    config.mcp = config.mcp || {};

    const existing = config.mcp.pekg;
    const expectedAuth = `Bearer ${token}`;
    const uaMatches = existing?.headers?.["User-Agent"] === USER_AGENT;
    const authMatches = existing?.headers?.Authorization === expectedAuth;
    const shapeMatches = existing?.type === "remote" && existing?.url === MCP_URL;
    if (shapeMatches && authMatches && uaMatches) {
      return "unchanged";
    }

    const wasNew = !existing;

    config.mcp.pekg = {
      type: "remote",
      url: MCP_URL,
      enabled: true,
      headers: {
        Authorization: expectedAuth,
        "User-Agent": USER_AGENT,
      },
    };

    fs.writeFileSync(OPENCODE_CONFIG, JSON.stringify(config, null, 2));
    if (wasNew) return "new";
    return authMatches ? "metadata_updated" : "token_rotated";
  } catch {
    return "unchanged";
  }
}

// ---------------------------------------------------------------------------
// Self-update
// ---------------------------------------------------------------------------

interface PluginMeta {
  name: string;
  version: string;
  url: string;
}

interface UpdateCheckMarker {
  lastCheckedAt: number;
  lastSeenVersion: string;
}

function compareVersions(a: string, b: string): number {
  const parse = (v: string): number[] => v.split(/[.-]/).map((p) => Number.parseInt(p, 10) || 0);
  const pa = parse(a);
  const pb = parse(b);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const x = pa[i] ?? 0;
    const y = pb[i] ?? 0;
    if (x > y) return 1;
    if (x < y) return -1;
  }
  return 0;
}

async function loadUpdateMarker(): Promise<UpdateCheckMarker | null> {
  try {
    const fs = await import("node:fs");
    const raw = fs.readFileSync(UPDATE_CHECK_MARKER, "utf-8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function saveUpdateMarker(version: string): Promise<void> {
  try {
    const fs = await import("node:fs");
    const path = await import("node:path");
    fs.mkdirSync(path.dirname(UPDATE_CHECK_MARKER), { recursive: true });
    const marker: UpdateCheckMarker = {
      lastCheckedAt: Date.now(),
      lastSeenVersion: version,
    };
    fs.writeFileSync(UPDATE_CHECK_MARKER, JSON.stringify(marker, null, 2));
  } catch {}
}

async function fetchWithTimeout(url: string, timeoutMs = 10000): Promise<Response | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, {
      signal: controller.signal,
      headers: { "User-Agent": USER_AGENT },
    });
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function checkForUpdate(): Promise<string | null> {
  const marker = await loadUpdateMarker();
  if (marker && Date.now() - marker.lastCheckedAt < UPDATE_CHECK_INTERVAL_MS) {
    return null;
  }

  const metaRes = await fetchWithTimeout(PLUGIN_META_URL, 5000);
  if (!metaRes || !metaRes.ok) return null;

  let meta: PluginMeta;
  try {
    meta = await metaRes.json();
  } catch {
    return null;
  }

  if (compareVersions(meta.version, PLUGIN_VERSION) <= 0) {
    await saveUpdateMarker(meta.version);
    return null;
  }

  const tsRes = await fetchWithTimeout(meta.url || PLUGIN_DOWNLOAD_URL, 15000);
  if (!tsRes || !tsRes.ok) return null;

  const newContent = await tsRes.text();

  if (
    newContent.length < 5000 ||
    !newContent.includes("export const PeKGPlugin") ||
    !newContent.includes("PLUGIN_VERSION")
  ) {
    return null;
  }

  const downloadedVersion = newContent.match(/PLUGIN_VERSION\s*=\s*["']([^"']+)["']/)?.[1];
  if (!downloadedVersion || compareVersions(downloadedVersion, PLUGIN_VERSION) <= 0) {
    return null;
  }

  try {
    const fs = await import("node:fs");
    const path = await import("node:path");
    if (fs.existsSync(PLUGIN_INSTALL_PATH)) {
      fs.copyFileSync(PLUGIN_INSTALL_PATH, `${PLUGIN_INSTALL_PATH}.prev`);
    }
    const tempPath = `${PLUGIN_INSTALL_PATH}.tmp.${process.pid}.${Date.now()}`;
    fs.mkdirSync(path.dirname(PLUGIN_INSTALL_PATH), { recursive: true });
    fs.writeFileSync(tempPath, newContent);
    fs.renameSync(tempPath, PLUGIN_INSTALL_PATH);
  } catch {
    return null;
  }

  await saveUpdateMarker(downloadedVersion);
  return downloadedVersion;
}

// ---------------------------------------------------------------------------
// Feedback queue (for failed submissions)
// ---------------------------------------------------------------------------

interface QueuedFeedback {
  articleId: string;
  signal: string;
  projectOrigin?: string;
  timestamp: number;
}

async function queueFeedback(feedback: QueuedFeedback): Promise<void> {
  try {
    const fs = await import("node:fs");
    const path = await import("node:path");
    fs.mkdirSync(FEEDBACK_QUEUE_DIR, { recursive: true });
    const filename = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}.json`;
    fs.writeFileSync(path.join(FEEDBACK_QUEUE_DIR, filename), JSON.stringify(feedback));
  } catch {}
}

async function replayFeedbackQueue(token: string): Promise<void> {
  try {
    const fs = await import("node:fs");
    const path = await import("node:path");
    if (!fs.existsSync(FEEDBACK_QUEUE_DIR)) return;

    const files = fs.readdirSync(FEEDBACK_QUEUE_DIR).filter((f: string) => f.endsWith(".json"));
    for (const file of files.slice(0, 10)) {
      // Process max 10 at a time
      const filePath = path.join(FEEDBACK_QUEUE_DIR, file);
      try {
        const content = fs.readFileSync(filePath, "utf-8");
        const feedback = JSON.parse(content) as QueuedFeedback;

        const res = await fetch(`${API_BASE}/api/v1/articles/${feedback.articleId}/feedback`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
            "User-Agent": USER_AGENT,
          },
          body: JSON.stringify({
            signal: feedback.signal,
            source: "agent",
            projectOrigin: feedback.projectOrigin,
          }),
        });

        if (res.ok) {
          fs.unlinkSync(filePath); // Delete on success
        }
      } catch {}
    }
  } catch {}
}

// ---------------------------------------------------------------------------
// Onboarding tool: pekg_connect
// ---------------------------------------------------------------------------

function buildConnectTool($: BunShell) {
  return tool({
    description:
      "Connect to PeKG knowledge graph. Opens browser for Google sign-in, polls for token, saves config, registers PeKG as an MCP server in opencode.json. Run this once per machine.",
    args: {},
    async execute(_args, _context) {
      let otpResp: OtpResponse | undefined;
      try {
        const res = await fetch(`${API_BASE}/api/v1/auth/otp`);
        if (!res.ok) return `Failed to get OTP: HTTP ${res.status}`;
        otpResp = (await res.json()) as OtpResponse;
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        return `PeKG API unreachable: ${msg}. Try again later or visit https://pekg.ai`;
      }
      if (!otpResp) return "Failed to parse OTP response";

      const { otp, connectUrl } = otpResp;

      try {
        const { platform } = await import("node:os");
        const p = platform();
        if (p === "darwin") await $`open ${connectUrl}`.quiet();
        else if (p === "win32") await $`start ${connectUrl}`.quiet();
        else await $`xdg-open ${connectUrl}`.quiet();
      } catch {}

      const MAX_ATTEMPTS = 100;
      const POLL_INTERVAL = 3000;
      let token: string | null = null;

      for (let i = 0; i < MAX_ATTEMPTS; i++) {
        await new Promise((r) => setTimeout(r, POLL_INTERVAL));
        try {
          const res = await fetch(`${API_BASE}/api/v1/auth/otp-status?otp=${otp}`);
          if (res.status === 200) {
            const data = await res.json();
            if (data.status === "paired" && data.token) {
              token = data.token;
              break;
            }
          } else if (res.status === 404) {
            return "OTP expired. Run pekg_connect again.";
          }
        } catch {}
      }

      if (!token) return `Pairing timed out after 5 minutes. Run pekg_connect again. Or open ${connectUrl} manually.`;

      await savePeKGConfig(token);
      const wrote = await ensureMcpRegistered(token);

      try {
        const res = await fetch(`${API_BASE}/api/v1/dashboard/stats`, {
          headers: { Authorization: `Bearer ${token}`, "User-Agent": USER_AGENT },
        });
        if (!res.ok) return `Token saved but verification failed (HTTP ${res.status}). Restart opencode.`;
      } catch {
        return "Token saved but could not verify. Restart opencode.";
      }

      const restartNote = wrote
        ? "PeKG MCP server registered in opencode.json."
        : "PeKG MCP server already registered.";

      return [
        "PeKG connected successfully!",
        `Token saved to ${CONFIG_PATH}.`,
        restartNote,
        "",
        "IMPORTANT: Restart opencode to activate PeKG MCP tools.",
      ].join("\n");
    },
  });
}

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

interface KBStats {
  totalArticles: number;
  pendingClusters: number;
  hiveContributionEnabled: boolean;
  hivePendingCount: number;
  // Issue 5: orphan count for session.idle warning
  orphanCount: number;
  orphanWarnThreshold: number;
}

async function fetchKBStats(token: string): Promise<KBStats | null> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5000);
    const res = await fetch(`${API_BASE}/api/v1/dashboard/stats`, {
      method: "GET",
      headers: { Authorization: `Bearer ${token}`, "User-Agent": USER_AGENT },
      signal: controller.signal,
    });
    clearTimeout(timer);
    if (!res.ok) return null;
    const data = (await res.json()) as {
      articleCount?: number;
      pendingClusters?: number;
      sharing?: { hiveContributionEnabled?: boolean };
      hivePendingTransform?: { count?: number };
      // Issue 5: orphan metrics
      orphanCount?: number;
      orphanArchivePolicy?: { warnThreshold?: number };
    };
    return {
      totalArticles: data.articleCount ?? 0,
      pendingClusters: data.pendingClusters ?? 0,
      hiveContributionEnabled: data.sharing?.hiveContributionEnabled ?? false,
      hivePendingCount: data.hivePendingTransform?.count ?? 0,
      orphanCount: data.orphanCount ?? 0,
      orphanWarnThreshold: data.orphanArchivePolicy?.warnThreshold ?? 10,
    };
  } catch {
    return null;
  }
}

interface ContextArticle {
  articleId: string;
  title: string;
  tier: string;
  summary?: string;
  snippet?: string;
  relevance?: number;
}

interface ContextResult {
  context: string;
  articles: ContextArticle[];
  blockers: ContextArticle[];
  status: "ok" | "empty" | "network_error";
}

const NETWORK_BLOCKER_ARTICLE: ContextArticle = {
  articleId: NETWORK_BLOCKER_ID,
  title: "PeKG offline — context fetch failed",
  tier: "blocker",
  summary:
    "PeKG could not be reached. Edits are blocked until PeKG is reachable. To override, set PEKG_OFFLINE=1 in the environment and restart opencode.",
  relevance: 1,
};

async function fetchContext(token: string, projectOrigin: string, currentTask: string): Promise<ContextResult> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 4000);
    const res = await fetch(`${API_BASE}/api/v1/context`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        "User-Agent": USER_AGENT,
      },
      body: JSON.stringify({ projectOrigin, currentTask }),
      signal: controller.signal,
    });
    clearTimeout(timer);
    if (!res.ok) {
      return { context: "", articles: [], blockers: [], status: "network_error" };
    }

    const data = (await res.json()) as { relevant?: ContextArticle[] };
    const articles = data.relevant ?? [];

    // Issue 6: plugin-side per-tier relevance floor (replaces hard-coded
    // 0.5/0.6/0.7 split below). Demotes low-relevance blockers to warnings
    // instead of dropping them outright — preserves accumulated value while
    // cutting blocker-tier noise. Applied BEFORE the token budget so quality
    // filtering happens first, then size constraints.
    const floored = pekgApplyTierFloor(articles);
    const blockers = floored.filter((a) => a.tier === "blocker");
    const warnings = floored.filter((a) => a.tier === "warning");
    const info = floored.filter((a) => a.tier === "info");

    // Combine and apply token budget with stable ordering
    const allRelevant = [...blockers, ...warnings, ...info];
    const budgetedArticles = applyTokenBudget(allRelevant, CONTEXT_TOKEN_BUDGET);

    // Re-extract after budgeting
    const budgetedBlockers = budgetedArticles.filter((a) => a.tier === "blocker");
    const budgetedWarnings = budgetedArticles.filter((a) => a.tier === "warning");
    const budgetedInfo = budgetedArticles.filter((a) => a.tier === "info");

    if (budgetedBlockers.length === 0 && budgetedWarnings.length === 0 && budgetedInfo.length === 0) {
      return { context: "", articles: [], blockers: [], status: "empty" };
    }

    const lines: string[] = [];

    // Render budgeted articles (already stable-sorted and token-limited)
    if (budgetedBlockers.length > 0) {
      lines.push("BLOCKERS (known bugs/gotchas - address BEFORE proceeding):");
      for (const b of budgetedBlockers) {
        const summary = (b.summary || b.snippet || "").replace(/\n/g, " ").slice(0, 250);
        lines.push(`  [${b.articleId.slice(0, 8)}] ${b.title}`);
        lines.push(`      ${summary}`);
      }
    }

    if (budgetedWarnings.length > 0) {
      lines.push("WARNINGS (patterns to be aware of):");
      for (const w of budgetedWarnings) {
        const summary = (w.summary || w.snippet || "").replace(/\n/g, " ").slice(0, 200);
        lines.push(`  [${w.articleId.slice(0, 8)}] ${w.title}: ${summary}`);
      }
    }

    if (budgetedInfo.length > 0 && budgetedBlockers.length === 0) {
      lines.push("CONTEXT:");
      for (const i of budgetedInfo) {
        const summary = (i.summary || i.snippet || "").replace(/\n/g, " ").slice(0, 150);
        lines.push(`  [${i.articleId.slice(0, 8)}] ${i.title}: ${summary}`);
      }
    }

    return {
      context: lines.join("\n"),
      articles: budgetedArticles,
      blockers: budgetedBlockers,
      status: "ok",
    };
  } catch {
    return { context: "", articles: [], blockers: [], status: "network_error" };
  }
}

// render only the BLOCKERS section so subsequent turns inject
// blockers + guaranteed only, not the full warnings/info dump.
function renderBlockersOnly(blockers: ContextArticle[]): string {
  if (blockers.length === 0) return "";
  const lines: string[] = ["BLOCKERS (known bugs/gotchas - address BEFORE proceeding):"];
  for (const b of blockers) {
    const summary = (b.summary || b.snippet || "").replace(/\n/g, " ").slice(0, 250);
    lines.push(`  [${b.articleId.slice(0, 8)}] ${b.title}`);
    lines.push(`      ${summary}`);
  }
  return lines.join("\n");
}

// Issue 8: re-tier helpers. When the user is editing a markdown file
// (docs/README/changelog/etc.), code-domain blockers are demoted from
// `blocker` to `warning` so the gate doesn't fire. Security / privacy /
// compliance / docs-tagged blockers are NEVER demoted — those legitimately
// apply to documentation work too.
//
// Empty-tag blockers default to `demote` because most plugin-surfaced
// blockers come from regular `articles` (not hive_articles) and don't
// carry explicit `technologies`/`pattern_type` tags. Title+summary keyword
// matching is the available signal.
function pekgIsMarkdownPath(filePath: string | undefined | null): boolean {
  if (!filePath) return false;
  return PEKG_MARKDOWN_EXT_RE.test(filePath);
}

function pekgTextMatchesAny(text: string, keywords: readonly string[]): boolean {
  const t = text.toLowerCase();
  for (const kw of keywords) {
    // Prefix-only word boundary so plural / -ed / -ing variants match.
    // "\\bcredential" matches both "credential" and "credentials"; tradeoff
    // is we'd also match "credentialism" — acceptable false-positive risk
    // for shorter, cleaner keyword set.
    if (new RegExp(`\\b${kw}`).test(t)) return true;
  }
  return false;
}

// effectiveTier: returns the blocker's tier as it should be USED for
// gating, not as it was assigned by the server. The cross-project clamp
// (Issue 1) already lives on the server; this is the markdown-context
// clamp (Issue 8) that's plugin-side because the file path is only known
// at tool-execution time.
//
// Rules:
//   - If file is NOT markdown → return blocker's natural tier (no change).
//   - If file IS markdown AND blocker mentions security/privacy/docs/etc.
//     → keep at natural tier (those legitimately apply to markdown work).
//   - If file IS markdown AND blocker is code-domain (or untagged with
//     code-domain title/summary keywords) → demote blocker → warning.
//   - Demote rule never PROMOTES; warning/info stay where they are.
function pekgEffectiveTier(
  blocker: { tier: string; title?: string; summary?: string },
  filePath: string | undefined | null,
): string {
  if (blocker.tier !== "blocker") return blocker.tier; // never promote
  if (!pekgIsMarkdownPath(filePath)) return blocker.tier;
  const text = `${blocker.title ?? ""} ${blocker.summary ?? ""}`;
  // Security / privacy / docs carve-out — those still gate on markdown.
  if (pekgTextMatchesAny(text, PEKG_NON_CODE_KEYWORDS)) return blocker.tier;
  // Code-domain blocker → demote. Untagged → defaults to demote on
  // markdown (safer than gating doc work indefinitely).
  return "warning";
}

// pekgFilterBlockersForFile: given a list of blockers and the target
// file path, return the subset whose effective tier is still `blocker`.
// Used by both the Edit/Write gate and the bash-mutation gate to decide
// whether to throw.
function pekgFilterBlockersForFile<T extends { tier: string; title?: string; summary?: string }>(
  blockers: readonly T[],
  filePath: string | undefined | null,
): T[] {
  return blockers.filter((b) => pekgEffectiveTier(b, filePath) === "blocker");
}

// Issue 9: filter inherited blockers when spawning a Task subagent. Today
// the parent session's full blocker list is prepended to the subagent's
// prompt, forcing it to ack blockers irrelevant to its task. The filter:
//   - Score each blocker by token-overlap between (title + summary) and
//     the subagent's prompt. Lowercased, alphanum, ≥4-char tokens.
//   - Keep only blockers with non-zero overlap.
//   - Cap at top 3 most-relevant.
//   - When the original list exceeded what survived, the call site
//     appends a "N more filtered" hint so the subagent can fetch its own
//     full context if its work spans multiple domains.
//
// projectOrigin filter (locked Q9 part-a) is deferred until ContextArticle
// gets a projectOrigin field; today's data doesn't expose it client-side.
// Issue 1 (server-side cross-project clamp) is the primary defence —
// cross-project blockers don't reach blocker tier in the parent context to
// begin with, so they never enter this filter.
function pekgFilterInheritedBlockers<T extends { title?: string; summary?: string }>(
  blockers: readonly T[],
  subagentPrompt: string,
): { kept: T[]; filteredCount: number } {
  const cap = 3;
  if (blockers.length === 0) return { kept: [], filteredCount: 0 };
  const promptTokens = pekgExtractTokens(subagentPrompt);
  if (promptTokens.size === 0) {
    // Empty / too-terse prompt — no signal to filter on. Apply only the cap.
    const kept = blockers.slice(0, cap);
    return { kept: [...kept], filteredCount: blockers.length - kept.length };
  }
  const scored: Array<{ blocker: T; score: number }> = blockers.map((b) => {
    const text = `${b.title ?? ""} ${b.summary ?? ""}`;
    const tokens = pekgExtractTokens(text);
    let score = 0;
    for (const t of tokens) if (promptTokens.has(t)) score++;
    return { blocker: b, score };
  });
  scored.sort((a, b) => b.score - a.score);
  const kept = scored
    .filter((s) => s.score > 0)
    .slice(0, cap)
    .map((s) => s.blocker);
  return { kept, filteredCount: blockers.length - kept.length };
}

function pekgExtractTokens(text: string): Set<string> {
  return new Set(
    text
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((t) => t.length >= 4),
  );
}

// Issue 6: per-tier plugin-side relevance floor. Server's RELEVANCE_THRESHOLD
// stays at 0.5 for non-gating clients (dashboard search, Codex hooks). Plugin
// is opinionated: a blocker below 0.65 is demoted to warning (still visible,
// doesn't gate). A warning below 0.55 is dropped. Info below 0.7 is dropped.
// Floors are constants at module top so we can A/B by editing one line.
//
// Apply order: floor BEFORE budget. Otherwise a 0.99 blocker can be evicted
// by a 0.66 warning under budget pressure — the floor is a quality filter,
// the budget is a size filter; quality wins.
const PEKG_BLOCKER_FLOOR = 0.65;
const PEKG_WARNING_FLOOR = 0.55;
const PEKG_INFO_FLOOR = 0.7;

function pekgApplyTierFloor(articles: readonly ContextArticle[]): ContextArticle[] {
  return articles
    .map((a) => {
      const r = a.relevance ?? 0;
      // Demote blockers below floor → warning (visible, non-gating).
      if (a.tier === "blocker" && r < PEKG_BLOCKER_FLOOR) return { ...a, tier: "warning" };
      return a;
    })
    .filter((a) => {
      const r = a.relevance ?? 0;
      if (a.tier === "blocker" && r < PEKG_BLOCKER_FLOOR) return false;
      if (a.tier === "warning" && r < PEKG_WARNING_FLOOR) return false;
      if (a.tier === "info" && r < PEKG_INFO_FLOOR) return false;
      return true;
    });
}

// Issue 7: filter blockers by per-blocker ack cooldown. Blockers whose
// articleId was acked within COOLDOWN_MS are suppressed (gate doesn't fire
// for them). Acks older than the cooldown re-fire the gate as a "still
// relevant?" reminder. Pure function — easy to unit-test in isolation.
function pekgFilterAckedBlockers<T extends { articleId: string }>(
  blockers: readonly T[],
  ackedAt: Record<string, number> | undefined,
  now: number,
  cooldownMs: number,
): T[] {
  if (!ackedAt) return [...blockers];
  return blockers.filter((b) => {
    const ts = ackedAt[b.articleId];
    if (!ts) return true; // never acked → keep active
    return now - ts >= cooldownMs; // cooldown expired → keep active
  });
}

// Issue 7: prune ackedAt entries older than PRUNE_MS. Bounds memory
// growth in long-running sessions. Mutates in place; returns void.
function pekgPruneAckedAt(ackedAt: Record<string, number>, now: number, pruneMs: number): void {
  for (const id of Object.keys(ackedAt)) {
    if (now - ackedAt[id] >= pruneMs) delete ackedAt[id];
  }
}

// Heuristic: does this bash command target a markdown file as its
// mutation destination? Looks for typical write/edit operators with a
// markdown filename appearing anywhere after them on the same command
// (allowing intermediate args like `sed -i 'expr' file.md`). False
// negatives are acceptable (gate falls back to today's behavior). False
// positives skip the gate, which is the worse direction — so the regex is
// intentionally narrow on the operator set.
function pekgBashCmdTargetsMarkdown(cmd: string): boolean {
  return /(?:\bsed\s+-[A-Za-z]*i\b|\btee\b|>>?\s*|\bcp\b|\bmv\b)[^|;&]*\.(md|mdx|txt|rst|adoc)\b/i.test(cmd);
}

function isWorkspaceFileMutationCommand(cmd: string, workspaceDir: string): boolean {
  if (!cmd) return false;
  const c = cmd;
  const ws = workspaceDir.replace(/\/$/, "");
  if (/(^|[\s;&|`])sed\s+(-[A-Za-z]*i|--in-place)\b/.test(c)) return true;
  if (/(^|[\s;&|`])perl\s+(-[A-Za-z]*pi|-i)\b/.test(c)) return true;
  if (/(^|[\s;&|`])awk\s+(-i\s+inplace|--in-place)\b/.test(c)) return true;
  if (/(^|[\s;&|`])tee\b/.test(c)) return true;
  if (
    /(^|[\s;&|`])(rm|mv|cp)\s+(-[A-Za-z]+\s+)*\S+/.test(c) &&
    (c.includes(ws) || /\.\.?\//.test(c) || !c.includes("/"))
  )
    return true;
  // File-write redirect: > or >> (optionally preceded by a fd digit, or &>
  // for stdout+stderr), followed by a target that is NOT an fd alias (&N)
  // and NOT /dev/*. This excludes `2>&1`, `1>&2`, `2>/dev/null`, etc.
  if (/(?:^|[\s;&|`])(?:[0-9]?>>?|&>)\s*(?!&)(?!\/dev\/)[^\s]/.test(c)) return true;
  // Heredoc alone is not a file write — `cat <<EOF` outputs to stdout.
  // Heredocs paired with `> file` are already caught by the redirect rule.
  if (/(python|python3|node|bun|deno)\s+-[ec]\s+["'][\s\S]*(open\(|writeFileSync|writeFile|fs\.write)/.test(c))
    return true;
  if (/(^|[\s;&|`])git\s+(apply|restore|checkout\s+--|reset\s+--hard)\b/.test(c)) return true;
  return false;
}

async function submitFeedback(
  token: string,
  articleId: string,
  signal: "applied" | "avoided_bug",
  projectOrigin?: string,
): Promise<boolean> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 3000);
    const res = await fetch(`${API_BASE}/api/v1/articles/${articleId}/feedback`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        "User-Agent": USER_AGENT,
      },
      body: JSON.stringify({ signal, source: "agent", projectOrigin }),
      signal: controller.signal,
    });
    clearTimeout(timer);
    return res.ok;
  } catch {
    return false;
  }
}

interface CompileManifest {
  manifest: {
    clusterId: string;
    topic: string;
    sources: Array<{
      sourceId: string;
      title: string;
      content: string;
      sourceType: string;
    }>;
    relatedArticles: Array<{ articleId: string; title: string; summary: string }>;
    compilationProfile: {
      type: string;
      sections: string[];
      tone: string;
    };
  };
  submitParams: {
    clusterId: string;
    compilationProfile: string;
  };
}

async function fetchCompileManifest(token: string): Promise<CompileManifest | null> {
  try {
    const clustersRes = await fetch(`${API_BASE}/api/v1/compile/clusters`, {
      headers: { Authorization: `Bearer ${token}`, "User-Agent": USER_AGENT },
    });
    if (!clustersRes.ok) return null;

    const clustersData = (await clustersRes.json()) as { clusters?: Array<{ id: string }> };
    const readyClusters = clustersData.clusters ?? [];
    if (readyClusters.length === 0) return null;

    const manifestRes = await fetch(`${API_BASE}/api/v1/compile`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        "User-Agent": USER_AGENT,
      },
      body: JSON.stringify({ clusterId: readyClusters[0].id }),
    });
    if (!manifestRes.ok) return null;

    return (await manifestRes.json()) as CompileManifest;
  } catch {
    return null;
  }
}

async function submitCompiledArticle(
  token: string,
  title: string,
  content: string,
  clusterId: string,
  compilationProfile: string,
  entities: Array<{ name: string; type: string }>,
  relations: Array<{ from: string; to: string; type: string }>,
): Promise<boolean> {
  try {
    const res = await fetch(`${API_BASE}/api/v1/ingest`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        "User-Agent": USER_AGENT,
      },
      body: JSON.stringify({
        title,
        content,
        sourceType: "compiled_article",
        clusterId,
        compilationProfile,
        entities,
        relations,
      }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

async function submitIngest(
  token: string,
  title: string,
  content: string,
  sourceType: string,
  projectOrigin: string,
  tags: string[],
): Promise<boolean> {
  try {
    const res = await fetch(`${API_BASE}/api/v1/ingest`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        "User-Agent": USER_AGENT,
      },
      body: JSON.stringify({ title, content, sourceType, projectOrigin, tags }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Hive contribution helpers
// ---------------------------------------------------------------------------

interface HivePendingItem {
  id: string;
  source: string;
  sourceUrl: string;
  title: string;
  body: string;
  answerBody?: string;
  upvotes: number;
  tags: string[];
}

async function fetchPendingHiveItems(token: string): Promise<HivePendingItem[]> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 10000);
    const res = await fetch(`${API_BASE}/api/v1/hive/pending`, {
      method: "GET",
      headers: { Authorization: `Bearer ${token}`, "User-Agent": USER_AGENT },
      signal: controller.signal,
    });
    clearTimeout(timer);
    if (!res.ok) return [];
    const data = (await res.json()) as { items?: HivePendingItem[] };
    return data.items ?? [];
  } catch {
    return [];
  }
}

async function submitHiveArticle(
  token: string,
  scrapedId: string,
  title: string,
  content: string,
  technologies: string[],
  patternType: string,
  severity: string,
): Promise<boolean> {
  try {
    const res = await fetch(`${API_BASE}/api/v1/hive/submit`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        "User-Agent": USER_AGENT,
      },
      body: JSON.stringify({
        scrapedId,
        title,
        content,
        technologies,
        patternType,
        severity,
      }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Technology detection for proactive context
// ---------------------------------------------------------------------------

const TECH_PATTERNS: Array<{ pattern: RegExp; tech: string; searchTerms: string[] }> = [
  // Databases
  { pattern: /from ['"]drizzle-orm|import.*drizzle/i, tech: "drizzle", searchTerms: ["drizzle", "postgres-js", "ORM"] },
  {
    pattern: /from ['"]@clickhouse|clickhouse.*client/i,
    tech: "clickhouse",
    searchTerms: ["clickhouse", "ReplacingMergeTree", "AggregatingMergeTree"],
  },
  {
    pattern: /from ['"]ioredis|from ['"]redis|new Redis\(/i,
    tech: "redis",
    searchTerms: ["redis", "connection pool", "ioredis"],
  },
  {
    pattern: /from ['"]pg['"]|from ['"]postgres['"]|PostgreSQL/i,
    tech: "postgresql",
    searchTerms: ["postgresql", "postgres", "connection"],
  },

  // Auth
  {
    pattern: /OAuth|from ['"]jose['"]|JWT|jsonwebtoken/i,
    tech: "auth",
    searchTerms: ["OAuth", "JWT", "authentication", "token"],
  },
  { pattern: /from ['"]better-auth/i, tech: "better-auth", searchTerms: ["better-auth", "OAuth", "authentication"] },

  // Frameworks
  { pattern: /from ['"]fastify|Fastify/i, tech: "fastify", searchTerms: ["fastify", "middleware", "bodyLimit"] },
  { pattern: /from ['"]express['"]|express\(\)/i, tech: "express", searchTerms: ["express", "middleware", "cors"] },
  { pattern: /from ['"]hono['"]|new Hono\(/i, tech: "hono", searchTerms: ["hono", "middleware"] },
  {
    pattern: /from ['"]next|NextResponse|getServerSideProps/i,
    tech: "nextjs",
    searchTerms: ["nextjs", "App Router", "fetch caching"],
  },

  // React
  { pattern: /from ['"]react['"]|useState|useEffect/i, tech: "react", searchTerms: ["react", "hooks", "state"] },

  // MCP/Agents
  {
    pattern: /@modelcontextprotocol|MCP|StreamableHTTP/i,
    tech: "mcp",
    searchTerms: ["MCP", "session", "StreamableHTTP"],
  },

  // Temporal
  { pattern: /from ['"]@temporalio|Temporal\./i, tech: "temporal", searchTerms: ["temporal", "workflow", "activity"] },
];

function detectTechnologies(content: string): string[] {
  const detected: Set<string> = new Set();
  for (const { pattern, tech } of TECH_PATTERNS) {
    if (pattern.test(content)) {
      detected.add(tech);
    }
  }
  return Array.from(detected);
}

// Token estimation for budget enforcement
function estimateTokens(text: string): number {
  return Math.ceil(text.length / AVG_CHARS_PER_TOKEN);
}

// Stable ordering for prompt caching (inspired by opencode-agent-memory)
// Deterministic order = more LLM prompt cache hits = lower latency + cost
function stableSortArticles(articles: ContextArticle[]): ContextArticle[] {
  return [...articles].sort((a, b) => {
    // 1. Tier priority: blocker > warning > info
    const tierOrder: Record<string, number> = { blocker: 0, warning: 1, info: 2 };
    const tierA = tierOrder[a.tier] ?? 3;
    const tierB = tierOrder[b.tier] ?? 3;
    if (tierA !== tierB) return tierA - tierB;

    // 2. Within same tier: higher relevance first
    const relA = a.relevance ?? 0;
    const relB = b.relevance ?? 0;
    if (relA !== relB) return relB - relA;

    // 3. Tie-breaker: articleId for deterministic ordering
    return a.articleId.localeCompare(b.articleId);
  });
}

// Apply token budget, truncating lowest-priority articles first
function applyTokenBudget(articles: ContextArticle[], budget: number): ContextArticle[] {
  const sorted = stableSortArticles(articles);
  const result: ContextArticle[] = [];
  let usedTokens = 0;

  for (const article of sorted) {
    const articleText = `${article.title}\n${article.summary || article.snippet || ""}`;
    const tokens = estimateTokens(articleText);

    if (usedTokens + tokens > budget) {
      // Budget exceeded - stop adding articles
      // But always include at least one blocker if present
      if (article.tier === "blocker" && result.every((a) => a.tier !== "blocker")) {
        result.push(article);
      }
      break;
    }

    result.push(article);
    usedTokens += tokens;
  }

  return result;
}

function getSearchTermsForTech(techs: string[]): string[] {
  const terms: Set<string> = new Set();
  for (const tech of techs) {
    const entry = TECH_PATTERNS.find((p) => p.tech === tech);
    if (entry) {
      for (const term of entry.searchTerms) {
        terms.add(term);
      }
    }
  }
  return Array.from(terms);
}

async function searchKnowledge(token: string, query: string, limit = 5): Promise<ContextArticle[]> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 4000);
    const res = await fetch(`${API_BASE}/api/v1/search`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        "User-Agent": USER_AGENT,
      },
      body: JSON.stringify({ query, limit }),
      signal: controller.signal,
    });
    clearTimeout(timer);
    if (!res.ok) return [];

    const data = (await res.json()) as { results?: ContextArticle[] };
    return data.results ?? [];
  } catch {
    return [];
  }
}

// Fetch guaranteed-injection blocks (project_config, user_preferences)
// These are always injected regardless of relevance, solving "agent forgets commands" problem
// Uses explicit projectOrigin filter per blocker [7d318850] to prevent cross-project bleeding
// Per blocker [8e69cb58]: Uses dedicated /context/guaranteed endpoint with required projectOrigin
async function fetchGuaranteedBlocks(token: string, projectOrigin: string): Promise<ContextArticle[]> {
  if (!projectOrigin) return []; // projectOrigin required per blocker [8e69cb58]

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 3000);
    const res = await fetch(`${API_BASE}/api/v1/context/guaranteed`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        "User-Agent": USER_AGENT,
      },
      body: JSON.stringify({
        projectOrigin,
        limit: 10,
      }),
      signal: controller.signal,
    });
    clearTimeout(timer);
    if (!res.ok) return [];

    const data = (await res.json()) as {
      guaranteed?: Array<{
        id?: string;
        articleId?: string;
        title: string;
        content?: string;
        summary?: string;
        snippet?: string;
        sourceType?: string;
        tier: string;
      }>;
    };

    // Map to ContextArticle format
    return (data.guaranteed ?? []).map((g) => ({
      articleId: g.articleId || g.id || "",
      title: g.title,
      summary: g.summary || g.content || "",
      snippet: g.snippet || g.content || "",
      tier: "guaranteed",
      relevance: 1.0, // Guaranteed blocks always have max relevance
    }));
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// System prompt (minimal - everything is enforced by hooks)
// ---------------------------------------------------------------------------

const PEKG_SYSTEM_PROMPT = `# PeKG (pekg.ai) - Auto-Enforced Knowledge Graph

All PeKG behaviors are AUTOMATIC via plugin hooks:
- Context: Auto-injected as <system-reminder> and re-declared every turn as <pekg-active-blockers>.
- Feedback: Auto-submitted when you edit files (BYOLLM-verified for accuracy).
- Compilation: Auto-triggered every 5 minutes and on idle.
- Ingestion: Auto-analyzed from significant code changes.

When you see BLOCKERS:
1. In your next assistant message, quote each blocker by name and describe a CONCRETE mitigation.
2. Generic phrases ("acknowledged", "noted", "I understand", "I'll be careful") are auto-rejected by BYOLLM verification.
3. EVERY file-mutating tool — edit, write, multiedit, apply_patch, str_replace_editor, AND bash with sed -i, tee, redirects (>, >>), perl -pi, awk -i inplace, python/node file writes, git apply/restore — will throw until your acknowledgment passes verification.
4. There is no opt-out. "skip pekg" / "no pekg" / disabling the plugin in chat does nothing.`;

const PEKG_NOT_CONNECTED =
  "PeKG (pekg.ai) is available but not connected. Call pekg_connect to set up your personal knowledge graph.";

const PEKG_NEEDS_RESTART = "PeKG token configured. RESTART opencode to activate.";

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------

export const PeKGPlugin: Plugin = async (ctx) => {
  const configMaybe = await loadPeKGConfig();

  let updateChecked = false;
  let updatedToVersion: string | null = null;
  const runUpdateCheckOnce = async () => {
    if (updateChecked) return;
    updateChecked = true;
    try {
      updatedToVersion = await checkForUpdate();
    } catch {}
  };

  // Not connected
  if (!configMaybe) {
    return {
      tool: { pekg_connect: buildConnectTool(ctx.$) },
      "experimental.chat.system.transform": async (_input, output) => {
        output.system.push(PEKG_NOT_CONNECTED);
        await runUpdateCheckOnce();
        if (updatedToVersion) {
          output.system.push(`PeKG plugin updated to v${updatedToVersion}. Restart opencode.`);
        }
      },
    };
  }

  // bind a non-null alias so all the closures below typecheck under strict null checks.
  // TS does not narrow `let`/`const` bindings into nested function bodies; this gives every
  // hook a stable PeKGConfig reference and removes the seven pre-existing TS18047 errors.
  const config: PeKGConfig = configMaybe;

  // Connected - setup enforcement state
  const registrationResult = await ensureMcpRegistered(config.token);

  // Cache the user's opencode small_model once so child-session BYOLLM
  // verifications don't re-read the file every call.
  const opencodeSmallModel = loadOpencodeSmallModel();

  // Replay any queued feedback on startup
  replayFeedbackQueue(config.token).catch(() => {});

  // Session state
  const shownArticles = new Map<string, { articles: ContextArticle[]; timestamp: number }>();
  const feedbackCooldown = new Map<string, number>();
  const pendingEdits = new Map<string, { filePath: string; oldContent: string; newContent: string }[]>();
  let lastCompileCheck = 0;
  let lastCompileTime = 0;
  let isCompiling = false;
  // H4 fix: per-session, not global. Compacting session A no longer wipes session B's
  // already-injected-context dedup state.
  const seenContextHashesBySession = new Map<string, Set<string>>();
  const processedIngestMessages = new Set<string>(); // Dedup KB_INGEST processing

  // Issue 5: orphan warning dedup (one warning per session max)
  const orphanWarningShownInSession = new Set<string>();

  // Proactive context tracking
  const detectedTechBySession = new Map<string, Set<string>>(); // Track detected technologies per session
  const proactiveContextShown = new Map<string, number>(); // Track when proactive context was last shown
  const PROACTIVE_CONTEXT_COOLDOWN_MS = 60 * 1000; // Don't spam proactive context
  const pendingProactiveContext = new Map<string, string[]>(); // Queue context to inject

  // ---------------------------------------------------------------------------
  // Flash Compaction: Session Task State Tracking
  // ---------------------------------------------------------------------------

  interface FileTrackingState {
    filesRead: Set<string>; // Files agent looked at (raw paths preserved)
    filesModified: Set<string>; // Files agent changed (raw paths preserved)
    filesDiscovered: Set<string>; // Files found via glob/grep (raw paths preserved)
    fileOperations: Array<{
      // Ordered history with full details
      type: "read" | "edited" | "created" | "deleted";
      path: string;
      timestamp: number;
    }>;
  }

  interface SessionTaskState {
    currentTask: string; // Most recent user intent
    activeFiles: FileTrackingState; // Files tracked via hooks (raw paths)
    failedApproaches: string[]; // What didn't work
    completedSteps: string[]; // What was accomplished
    keyDecisions: string[]; // Important choices made
  }

  const sessionTaskState = new Map<string, SessionTaskState>();

  // Flash compaction coordination counter. NOT a boolean — handles edge case
  // of concurrent compactions in the same opencode process. Normal chat sees
  // depth === 0 and short-circuits; only actual compaction calls increment.
  let compactingDepth = 0;
  // H2 fix: stamp the depth so messages.transform can drop a leaked flag.
  // If session.compacting increments depth but opencode throws before
  // messages.transform fires (e.g., structuredClone on circular refs), depth
  // would stay > 0 indefinitely and the next normal chat would have its
  // history cleared. The staleness guard caps that window.
  let compactingDepthSetAt = 0;
  const COMPACTING_STALE_MS = 30 * 1000;

  // Session state cleanup throttling
  const MAX_SESSION_FILES = 100;
  const CLEANUP_INTERVAL_MS = 60 * 60 * 1000; // 1 hour
  const SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
  let lastCleanupTime = 0;

  function createEmptyFileTrackingState(): FileTrackingState {
    return {
      filesRead: new Set(),
      filesModified: new Set(),
      filesDiscovered: new Set(),
      fileOperations: [],
    };
  }

  function getOrCreateSessionTaskState(sessionId: string): SessionTaskState {
    let state = sessionTaskState.get(sessionId);
    if (!state) {
      state = {
        currentTask: "",
        activeFiles: createEmptyFileTrackingState(),
        failedApproaches: [],
        completedSteps: [],
        keyDecisions: [],
      };
      sessionTaskState.set(sessionId, state);
    }
    return state;
  }

  // Sanitize failed approach text before persisting to disk.
  // Strips secrets, absolute paths outside workspace, and stack frames.
  // H5 fix: the previous workspace-preserve lookahead `(?!${wsEscaped})` checked
  // the wrong position (zero-width after the absolute path) and never matched,
  // so workspace paths were redacted along with everything else. New approach:
  // walk matches and only redact when the captured path does NOT start with the
  // workspace prefix. This works at any position in the string.
  function _sanitizeFailedApproach(text: string, workspaceDir: string): string {
    let sanitized = text;
    // Strip common secret patterns
    sanitized = sanitized.replace(
      /\b(sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|Bearer\s+[a-zA-Z0-9._-]+|apiKey=[^\s&]+|password=[^\s&]+|secret=[^\s&]+)/gi,
      "[REDACTED]",
    );
    // Strip absolute paths outside workspace; keep workspace paths.
    const ws = workspaceDir.replace(/\/$/, "");
    sanitized = sanitized.replace(/(\/Users\/[^\s"']+|\/home\/[^\s"']+|C:\\Users\\[^\s"']+)/g, (m) =>
      ws && m.startsWith(ws) ? m : "[PATH]",
    );
    // Strip stack frames like `   at Foo (file.ts:1:2)`
    sanitized = sanitized.replace(/\s+at\s+[^\n]+\([^)]+\)/g, "");
    // Trim and cap length AFTER sanitization so secrets don't survive truncation.
    return sanitized.trim().slice(0, 100);
  }

  function buildFileSection(state: FileTrackingState): string {
    const sections: string[] = [];

    // Most important: files that were modified (last 5)
    if (state.filesModified.size > 0) {
      const recent = [...state.filesModified].slice(-5);
      sections.push(`### Files Modified\n${recent.map((f) => `- ${f}`).join("\n")}`);
    }

    // Secondary: files that were read (for context), last 3 that weren't also modified
    if (state.filesRead.size > 0) {
      const recent = [...state.filesRead].filter((f) => !state.filesModified.has(f)).slice(-3);
      if (recent.length > 0) {
        sections.push(`### Files Read (for reference)\n${recent.map((f) => `- ${f}`).join("\n")}`);
      }
    }

    return sections.join("\n\n");
  }

  interface FlashCompactionInput {
    task?: SessionTaskState;
    blockers?: BlockerState;
    projectOrigin: string;
  }

  function buildFlashCompactionPrompt(input: FlashCompactionInput): string {
    const sections: string[] = [];

    // 1. Current task (most important for continuation)
    if (input.task?.currentTask) {
      sections.push(`## Current Task\n${input.task.currentTask}`);
    }

    // 2. Files section (with proper tracking)
    if (input.task?.activeFiles) {
      const fileSection = buildFileSection(input.task.activeFiles);
      if (fileSection) {
        sections.push(`## Files\n${fileSection}`);
      }
    }

    // 3. Failed approaches (avoid repeating)
    if (input.task?.failedApproaches && input.task.failedApproaches.length > 0) {
      sections.push(
        `## Approaches Already Tried (avoid repeating)\n${input.task.failedApproaches.map((f) => `- ${f}`).join("\n")}`,
      );
    }

    // 4. Completed steps (summary)
    if (input.task?.completedSteps && input.task.completedSteps.length > 0) {
      const count = input.task.completedSteps.length;
      const recent = input.task.completedSteps.slice(-3);
      sections.push(
        `## Completed Steps\n${count} steps completed. Most recent:\n${recent.map((s) => `- ${s}`).join("\n")}`,
      );
    }

    // 5. Active blockers (CRITICAL)
    if (input.blockers && !input.blockers.acknowledged && input.blockers.blockers.length > 0) {
      sections.push(
        `## ACTIVE BLOCKERS (must acknowledge before file mutations)\n${input.blockers.blockers
          .map((b) => `- [${b.articleId?.slice(0, 8) || "local"}] ${b.title}: ${(b.summary || "").slice(0, 100)}`)
          .join("\n")}`,
      );
    }

    // 6. Project context
    sections.push(`## Project\n${input.projectOrigin || "Unknown"}`);

    // 7. Resume instructions
    sections.push(
      "## Instructions\nContinue the task. Address blockers first. Avoid failed approaches. The files listed above were actively being worked on.",
    );

    return sections.join("\n\n");
  }

  // Persist session task state alongside blocker state for crash recovery
  interface PersistedSessionState {
    task: {
      currentTask: string;
      filesRead: string[];
      filesModified: string[];
      failedApproaches: string[];
      completedSteps: string[];
    } | null;
    blockers: BlockerState | null;
    timestamp: number;
    expiresAt: number;
  }

  // persistFullSessionState removed — persistBlockerState below is now the
  // single writer of the PersistedSessionState envelope (see C2 fix).

  // loadFullSessionState removed: rehydrateBlockerState below now reads the
  // PersistedSessionState envelope and rehydrates BOTH blockers and task state
  // from a single canonical reader.

  // Lazy cleanup of expired session files
  async function maybeRunCleanup(): Promise<void> {
    const now = Date.now();
    if (now - lastCleanupTime < CLEANUP_INTERVAL_MS) return;
    lastCleanupTime = now;

    // Non-blocking cleanup. Errors are silently swallowed — opencode TUI renders
    // plugin console.* output as input-area garbage, and a cleanup failure isn't
    // user-actionable.
    cleanupExpiredSessions().catch(() => {});
  }

  async function cleanupExpiredSessions(): Promise<void> {
    const fs = require("node:fs/promises") as typeof import("node:fs/promises");

    let files: string[];
    try {
      files = await fs.readdir(SESSION_STATE_DIR);
    } catch {
      return; // Directory doesn't exist yet
    }

    const jsonFiles = files.filter((f: string) => f.endsWith(".json"));
    const now = Date.now();

    // Collect file info
    const fileStats: Array<{ file: string; mtime: number; expired: boolean }> = [];

    for (const file of jsonFiles) {
      const path = `${SESSION_STATE_DIR}/${file}`;
      try {
        const [stat, content] = await Promise.all([fs.stat(path), fs.readFile(path, "utf-8")]);

        let expired = false;
        try {
          const state = JSON.parse(content) as PersistedSessionState;
          expired = !!(state.expiresAt && state.expiresAt < now);
        } catch {
          expired = true; // Malformed JSON, mark for deletion
        }

        fileStats.push({ file, mtime: stat.mtimeMs, expired });
      } catch {
        // File disappeared, skip
      }
    }

    // Layer 2: Delete expired files
    for (const { file, expired } of fileStats) {
      if (expired) {
        await fs.unlink(`${SESSION_STATE_DIR}/${file}`).catch(() => {});
      }
    }

    // Layer 4: Enforce hard cap on non-expired files
    const activeFiles = fileStats.filter((f) => !f.expired);
    if (activeFiles.length > MAX_SESSION_FILES) {
      // Sort by mtime ascending (oldest first)
      activeFiles.sort((a, b) => a.mtime - b.mtime);

      const toDelete = activeFiles.slice(0, activeFiles.length - MAX_SESSION_FILES);
      for (const { file } of toDelete) {
        await fs.unlink(`${SESSION_STATE_DIR}/${file}`).catch(() => {});
      }
    }
  }

  // Active blockers that must be addressed before edits
  // Map<sessionId, { blockers, acknowledged, verificationPending, lastAgentResponse }>
  // Issue 7: ackedAt maps articleId → ack timestamp for per-blocker cooldown.
  // The boolean `acknowledged` remains for full-session clear (heuristic
  // matched majority); ackedAt provides finer-grained "this specific blocker
  // was acked X seconds ago, don't re-fire the gate just because a context
  // refresh re-emitted it." Record<> over Map for JSON-persistability.
  interface BlockerState {
    blockers: ContextArticle[];
    acknowledged: boolean;
    verificationPending: boolean;
    lastAgentResponse?: string;
    verifiedAt?: number;
    ackedAt?: Record<string, number>;
  }
  const activeBlockers = new Map<string, BlockerState>();
  // Issue 7 constants. 10-min cooldown matches typical multi-edit task
  // flow. 30-min prune bounds ackedAt growth across long sessions.
  const BLOCKER_ACK_COOLDOWN_MS = 10 * 60 * 1000;
  const BLOCKER_ACK_PRUNE_MS = 30 * 60 * 1000;

  // Single writer for ~/.pekg/sessions/<sid>.json: always writes the
  // PersistedSessionState envelope, preserving any task-tracking state already
  // on disk. v3.11.x had two writers (persistBlockerState + persistFullSessionState)
  // overwriting the same path with different shapes — that's now collapsed.
  // persistBlockerState below read-modify-writes within the envelope.
  function persistBlockerState(sessionId: string): void {
    try {
      const fs = require("node:fs") as typeof import("node:fs");
      fs.mkdirSync(SESSION_STATE_DIR, { recursive: true });
      const file = `${SESSION_STATE_DIR}/${sessionId}.json`;
      const blockerState = activeBlockers.get(sessionId);
      const taskState = sessionTaskState.get(sessionId);

      // Read existing envelope to preserve task-tracking when only blockers changed.
      let existing: PersistedSessionState | null = null;
      if (fs.existsSync(file)) {
        try {
          existing = JSON.parse(fs.readFileSync(file, "utf-8")) as PersistedSessionState;
        } catch {
          existing = null;
        }
      }

      // If neither in-memory state has anything to persist, drop the file.
      const hasBlockerContent = !!(blockerState && blockerState.blockers.length > 0);
      const hasTaskContent =
        !!taskState?.currentTask ||
        (taskState?.activeFiles.filesModified.size ?? 0) > 0 ||
        (taskState?.activeFiles.filesRead.size ?? 0) > 0 ||
        (taskState?.failedApproaches.length ?? 0) > 0;
      const hasExistingTaskContent = !!existing?.task;
      if (!hasBlockerContent && !hasTaskContent && !hasExistingTaskContent) {
        if (fs.existsSync(file)) fs.unlinkSync(file);
        return;
      }

      const envelope: PersistedSessionState = {
        task: taskState
          ? {
              currentTask: taskState.currentTask,
              filesRead: [...taskState.activeFiles.filesRead],
              filesModified: [...taskState.activeFiles.filesModified],
              failedApproaches: taskState.failedApproaches,
              completedSteps: taskState.completedSteps,
            }
          : (existing?.task ?? null),
        blockers: blockerState ?? null,
        timestamp: Date.now(),
        expiresAt: Date.now() + SESSION_TTL_MS,
      };

      fs.writeFileSync(file, JSON.stringify(envelope));
    } catch {}
  }

  // Reads the PersistedSessionState envelope and rehydrates BOTH activeBlockers
  // and sessionTaskState. Single source of truth on disk.
  function rehydrateBlockerState(sessionId: string): void {
    // PEKG_OFFLINE=1 is the documented escape hatch — it must override any
    // pre-existing persisted state, otherwise a stale NETWORK_BLOCKER from a
    // prior online session would deadlock offline mode (synthesis is gated
    // but the gate reads in-memory state populated by this function).
    if (PEKG_OFFLINE) return;
    if (activeBlockers.has(sessionId) && sessionTaskState.has(sessionId)) return;
    try {
      const fs = require("node:fs") as typeof import("node:fs");
      const file = `${SESSION_STATE_DIR}/${sessionId}.json`;
      if (!fs.existsSync(file)) return;
      const raw = fs.readFileSync(file, "utf-8");
      const envelope = JSON.parse(raw) as PersistedSessionState;
      // TTL check
      if (envelope.expiresAt && envelope.expiresAt < Date.now()) {
        fs.unlinkSync(file);
        return;
      }
      // Rehydrate blockers from envelope.blockers (which is BlockerState | null)
      if (envelope.blockers && Array.isArray(envelope.blockers.blockers) && !activeBlockers.has(sessionId)) {
        activeBlockers.set(sessionId, envelope.blockers);
      }
      // Rehydrate task state from envelope.task
      if (envelope.task && !sessionTaskState.has(sessionId)) {
        sessionTaskState.set(sessionId, {
          currentTask: envelope.task.currentTask,
          activeFiles: {
            filesRead: new Set(envelope.task.filesRead),
            filesModified: new Set(envelope.task.filesModified),
            filesDiscovered: new Set(),
            fileOperations: [],
          },
          failedApproaches: envelope.task.failedApproaches,
          completedSteps: envelope.task.completedSteps,
          keyDecisions: [],
        });
      }
    } catch {}
  }

  // Track context shown for feedback verification
  interface ShownContext {
    articles: ContextArticle[];
    contextText: string;
    timestamp: number;
  }
  const shownContextForVerification = new Map<string, ShownContext>();

  // per-session "first message already injected" flag.
  // Persisted alongside blocker state so -c continuation respects the first-turn budget.
  const firstMessageInjected = new Map<string, boolean>();

  // Pending context to inject via system.transform (avoids TUI input area bleed).
  // chat.message populates this, system.transform consumes it.
  // This is the FIX for the synthetic parts bleeding into the TUI input area:
  // output.parts.unshift() in chat.message shows in input area even with synthetic:true,
  // but output.system.push() in system.transform never renders in TUI.
  let pendingSystemContext: string | null = null;

  // per-session blocker-set hash for tool.definition cache stability.
  // Re-emit modified tool descriptions only when the hash changes.
  const toolDefinitionLastHashBySession = new Map<string, string>();

  // per-parent-session count of child-session BYOLLM verifications,
  // for the cost circuit-breaker.
  const childVerificationCountBySession = new Map<string, number>();

  // cache of resolved git-toplevel project origin per ctx.directory,
  // since it doesn't change across hook calls in one process.
  let cachedProjectOrigin: string | null = null;

  function getProjectOrigin(): string {
    if (cachedProjectOrigin !== null) return cachedProjectOrigin;
    try {
      const cp = require("node:child_process") as typeof import("node:child_process");
      const out = cp
        .execFileSync("git", ["-C", ctx.directory, "rev-parse", "--show-toplevel"], {
          stdio: ["ignore", "pipe", "ignore"],
          timeout: 1500,
        })
        .toString()
        .trim();
      if (out) {
        const path = require("node:path") as typeof import("node:path");
        cachedProjectOrigin = path.basename(out);
        return cachedProjectOrigin;
      }
    } catch {}
    cachedProjectOrigin = ctx.directory.split("/").pop() || "";
    return cachedProjectOrigin;
  }

  // returns true if the given session is one PeKG owns
  // (a child session spawned for verification/compile/hive). Hooks early-return
  // for these so PeKG does not fire its own enforcement on its own internal calls.
  async function isPekgManagedSession(sessionId: string | undefined): Promise<boolean> {
    if (!sessionId) return false;
    try {
      const data = await ctx.client.session.get({ path: { id: sessionId } });
      const title = (data as SessionResponse)?.data?.title ?? "";
      return typeof title === "string" && title.startsWith(PEKG_INTERNAL_TITLE_PREFIX);
    } catch {
      return false;
    }
  }

  // BYOLLM verification in a child session — never visible in the
  // parent's TUI, never recurses through the parent's hook chain. Always cleans up.
  // Returns the parsed reply on success, or null on parse-failure / cap-exceeded /
  // SDK error so callers can fall back to the deterministic heuristic.
  async function runInChildSession<T>(
    parentID: string,
    kind: "verify-blocker" | "verify-feedback" | "compile" | "hive",
    promptText: string,
    parse: (replyText: string) => T | null,
  ): Promise<T | null> {
    const used = childVerificationCountBySession.get(parentID) ?? 0;
    if (used >= MAX_CHILD_VERIFICATIONS_PER_SESSION) return null;
    childVerificationCountBySession.set(parentID, used + 1);

    let childID: string | null = null;
    try {
      const created = await ctx.client.session.create({
        body: {
          parentID,
          title: `${PEKG_INTERNAL_TITLE_PREFIX} ${kind}`,
        },
      });
      childID = (created as SessionResponse)?.data?.id ?? null;
      if (!childID) return null;

      const promptBody: PromptBody = {
        parts: [{ type: "text", text: promptText }],
        system:
          "You are a deterministic JSON classifier. Output ONLY the requested JSON object. " +
          "No prose, no markdown fences, no explanation. Do not call any tools.",
      };
      // Use the user's small_model if configured; otherwise omit and let
      // opencode fall back to the parent session's model. NEVER pass empty
      // providerID/modelID — that crashed opencode's effect runtime in
      // versions <= 3.10.2 with a Bun stack trace in the TUI.
      if (opencodeSmallModel) promptBody.model = opencodeSmallModel;

      const reply = await ctx.client.session.prompt({
        path: { id: childID },
        body: promptBody,
      });

      const replyText = (reply as MessageResponse)?.data?.message?.content ?? "";
      const parsed = parse(replyText);
      if (parsed === null) {
        // Failed parse counts as half a strike, still bounded.
        childVerificationCountBySession.set(parentID, used + 0.5);
      }
      return parsed;
    } catch {
      childVerificationCountBySession.set(parentID, used + 0.5);
      return null;
    } finally {
      if (childID) {
        ctx.client.session.delete({ path: { id: childID } }).catch(() => {});
      }
    }
  }

  // Issue 10: smart pre-truncation — first 1500 + last 500 chars, but
  // EXPAND to include any paragraph that mentions a blocker ID. Eliminates
  // the "ack lost in middle of long response" failure mode.
  function pekgTruncateForVerifier(response: string, blockerIds: readonly string[], maxChars = 2000): string {
    if (response.length <= maxChars) return response;
    const head = response.slice(0, 1500);
    const tail = response.slice(-500);
    // Scan middle for blocker-ID prefix mentions. If found, include the
    // surrounding ~200-char window so the verifier sees the ack.
    const middle = response.slice(1500, response.length - 500);
    const idHits: string[] = [];
    for (const id of blockerIds) {
      const prefix = id.slice(0, 8).toLowerCase();
      const idx = middle.toLowerCase().indexOf(prefix);
      if (idx !== -1) {
        const start = Math.max(0, idx - 100);
        const end = Math.min(middle.length, idx + prefix.length + 100);
        idHits.push(middle.slice(start, end));
      }
    }
    const middleExtract = idHits.length > 0 ? `\n[...] ${idHits.join(" [...] ")} [...]\n` : "\n[...]\n";
    return head + middleExtract + tail;
  }

  // Issue 10: structured-output verifier prompt. ~200 tokens vs ~672 in
  // the prior prose version. Returns JSON {addressedIds, concrete, reason}
  // so the caller can attribute acks to SPECIFIC blockers (Issue 7's
  // ackedAt map), not just "yes/no for the whole batch".
  function pekgBuildVerifierPrompt(blockers: ContextArticle[], agentResponse: string): string {
    const blockerLines = blockers.map((b) => `- ${b.articleId.slice(0, 8)}: ${b.title}`).join("\n");
    const ids = blockers.map((b) => b.articleId);
    const truncated = pekgTruncateForVerifier(agentResponse, ids);
    return `OUTPUT JSON: {"addressedIds":["8charprefix",...],"concrete":bool,"reason":"short"}
addressedIds = list 8-char prefixes of blockers the response explicitly mentions and proposes action for. concrete = true if response names specific files/changes/code (not generic "noted"/"will be careful").

BLOCKERS:
${blockerLines}

RESPONSE:
${truncated}`;
  }

  /**
   * Issue 10: BYOLLM ack verifier. Returns the array of addressed blocker
   * IDs (8-char prefixes) and a `concrete` flag. Compressed prompt + single
   * call across all blockers (was N retries × full-prose prompt).
   */
  interface PekgVerifierResult {
    addressedIds: string[];
    concrete: boolean;
    reason?: string;
  }

  async function verifyBlockerAcknowledgmentStructured(
    sessionId: string,
    blockers: ContextArticle[],
    agentResponse: string,
  ): Promise<PekgVerifierResult | null> {
    const prompt = pekgBuildVerifierPrompt(blockers, agentResponse);
    return runInChildSession<PekgVerifierResult>(sessionId, "verify-blocker", prompt, (text) => {
      // Tolerant parser — model occasionally wraps in markdown fences.
      const m = text.match(/\{[\s\S]*"addressedIds"[\s\S]*\}/);
      if (!m) return null;
      try {
        const parsed = JSON.parse(m[0]) as Partial<PekgVerifierResult>;
        if (!Array.isArray(parsed.addressedIds)) return null;
        const ids = parsed.addressedIds.filter((x): x is string => typeof x === "string");
        return {
          addressedIds: ids,
          concrete: parsed.concrete === true,
          reason: typeof parsed.reason === "string" ? parsed.reason : undefined,
        };
      } catch {
        return null;
      }
    });
  }

  // Backwards-compat wrapper. The old function returned a boolean —
  // sufficient for "is this ack OK to release the gate?" decisions. Maps
  // to: structured verifier returned a result with concrete=true AND any
  // addressedIds. Old call sites that depended on full-batch yes/no
  // continue to work; new call sites can use the structured variant
  // directly to update Issue 7's per-blocker ackedAt.
  async function _verifyBlockerAcknowledgment(
    sessionId: string,
    blockers: ContextArticle[],
    agentResponse: string,
  ): Promise<boolean> {
    const result = await verifyBlockerAcknowledgmentStructured(sessionId, blockers, agentResponse);
    if (!result) return false;
    return result.concrete && result.addressedIds.length > 0;
  }

  /**
   * BYOLLM: Verify that an edit actually used/addressed the shown context
   * Returns the appropriate feedback signal
   */
  async function verifyFeedbackAccuracy(
    sessionId: string,
    shownContext: ShownContext,
    editedFile: string,
    diff: string,
  ): Promise<"applied" | "avoided_bug" | "ignored" | null> {
    const contextSummary = shownContext.articles.map((a) => `[${a.tier}] ${a.title}`).join("\n");

    const verificationPrompt = `You are an INDEPENDENT code review system. Analyze if the code change relates to the knowledge context. Be SKEPTICAL - default to "ignored" unless clear evidence exists.

KNOWLEDGE CONTEXT THAT WAS SHOWN:
${contextSummary}

Full context text:
${shownContext.contextText.slice(0, 1500)}

FILE EDITED: ${editedFile}

ACTUAL CODE CHANGE (diff):
${diff.slice(0, 2000)}

STRICT CLASSIFICATION RULES:

"avoided_bug" - ONLY if ALL are true:
- Context contained a BLOCKER about a specific bug/crash/error
- The code change DIRECTLY prevents that specific issue
- You can point to EXACT lines in the diff that implement the fix
- Example: Context warns "Date objects crash in raw SQL", diff shows ".toISOString()" conversion

"applied" - ONLY if ALL are true:
- Context contained a pattern, best practice, or warning
- The code change follows that specific pattern
- You can identify WHICH pattern and WHERE in the diff
- Example: Context shows "use connection pooling", diff adds pool configuration

"ignored" - DEFAULT choice if:
- The edit is unrelated to any context topic
- The edit is in a different area than context discussed
- You cannot point to specific evidence of context usage
- The connection is vague or coincidental

IMPORTANT: When in doubt, choose "ignored". False "applied" signals pollute feedback data.

OUTPUT FORMAT (JSON only):
{"signal": "avoided_bug|applied|ignored", "evidence": "specific line or pattern from diff that proves usage, or 'none' if ignored", "contextUsed": "which specific context item was applied, or 'none'", "confidence": "high|medium|low"}`;

    // child session, see verifyBlockerAcknowledgment.
    return await runInChildSession<"applied" | "avoided_bug" | "ignored">(
      sessionId,
      "verify-feedback",
      verificationPrompt,
      (text) => {
        const m = text.match(/\{[\s\S]*"signal"[\s\S]*\}/);
        if (!m) return null;
        try {
          const parsed = JSON.parse(m[0]);
          if (["applied", "avoided_bug", "ignored"].includes(parsed.signal)) {
            return parsed.signal as "applied" | "avoided_bug" | "ignored";
          }
        } catch {}
        return null;
      },
    );
  }

  function hashContext(ctx: string): string {
    let hash = 0;
    for (let i = 0; i < ctx.length; i++) {
      hash = (hash << 5) - hash + ctx.charCodeAt(i);
      hash = hash & hash;
    }
    return hash.toString(36);
  }

  // deterministic ack detection. The previous BYOLLM verifier called
  // ctx.client.session.prompt(...) which (a) is visible in the TUI as a user message,
  // and (b) recurses on its own message.updated event, looping forever. We now require
  // the assistant message to mention each blocker's 8-char article-ID prefix AND contain
  // a minimum amount of substantive text. Easy to game in adversarial settings, but the
  // hard gate (throw in tool.execute.before) is the real enforcement; this just decides
  // when to release.
  // Returns the array of blockers that the agent's response specifically
  // addressed (by 8-char prefix or by ≥5-char title token). Issue 7 uses
  // this to record per-blocker ackedAt timestamps so individual blockers
  // can be cleared without requiring a full session-wide ack.
  function getHeuristicallyAcknowledgedBlockers(content: string, blockers: ContextArticle[]): ContextArticle[] {
    if (!content || blockers.length === 0) return [];
    const text = content.toLowerCase();
    if (text.length < 200) return [];

    // Generic-only acks fail (no per-blocker matches recorded either).
    const genericOnly =
      /^[\s\S]{0,400}$/.test(content) &&
      /(acknowledged|noted|i understand|will be careful|got it)/i.test(content) &&
      !/(because|specifically|to avoid|will (?:not|never)|instead of|use\s+\w+|wrap\s+|move\s+|defer|lazy)/i.test(
        content,
      );
    if (genericOnly) return [];

    const matched: ContextArticle[] = [];
    for (const b of blockers) {
      const prefix = b.articleId.slice(0, 8).toLowerCase();
      const titleTokens = (b.title || "")
        .toLowerCase()
        .split(/[^a-z0-9]+/)
        .filter((t) => t.length >= 5);
      const prefixHit = text.includes(prefix);
      const titleHit = titleTokens.length > 0 && titleTokens.some((t) => text.includes(t));
      if (prefixHit || titleHit) matched.push(b);
    }
    return matched;
  }

  // Original predicate retained for callers that just want a yes/no.
  // Majority match required (always at least one).
  function _isHeuristicallyAcknowledged(content: string, blockers: ContextArticle[]): boolean {
    const matched = getHeuristicallyAcknowledgedBlockers(content, blockers);
    const required = Math.max(1, Math.ceil(blockers.length / 2));
    return matched.length >= required;
  }

  function recordShownArticles(sessionId: string, articles: ContextArticle[]): void {
    const existing = shownArticles.get(sessionId);
    if (existing) {
      const seen = new Set(existing.articles.map((a) => a.articleId));
      for (const a of articles) {
        if (!seen.has(a.articleId)) {
          existing.articles.push(a);
          seen.add(a.articleId);
        }
      }
      existing.timestamp = Date.now();
    } else {
      shownArticles.set(sessionId, { articles: [...articles], timestamp: Date.now() });
    }

    // Cleanup old sessions
    const now = Date.now();
    for (const [sid, data] of shownArticles) {
      if (now - data.timestamp > 60 * 60 * 1000) shownArticles.delete(sid);
    }
  }

  async function submitImplicitFeedback(sessionId: string, projectOrigin?: string): Promise<void> {
    const shown = shownArticles.get(sessionId);
    if (!shown || shown.articles.length === 0) return;

    const now = Date.now();
    for (const article of shown.articles) {
      const lastFeedback = feedbackCooldown.get(article.articleId);
      if (lastFeedback && now - lastFeedback < FEEDBACK_COOLDOWN_MS) continue;

      const signal = article.tier === "blocker" ? "avoided_bug" : "applied";
      const success = await submitFeedback(config.token, article.articleId, signal, projectOrigin);

      if (!success) {
        // Queue for later retry
        await queueFeedback({
          articleId: article.articleId,
          signal,
          projectOrigin,
          timestamp: now,
        });
      }

      feedbackCooldown.set(article.articleId, now);
    }

    shownArticles.delete(sessionId);

    for (const [aid, ts] of feedbackCooldown) {
      if (now - ts > 5 * 60 * 1000) feedbackCooldown.delete(aid);
    }
  }

  /**
   * ENFORCED COMPILATION: Uses BYOLLM via session.prompt()
   */
  async function runCompilation(sessionId: string): Promise<void> {
    if (isCompiling) return;
    isCompiling = true;

    try {
      const manifest = await fetchCompileManifest(config.token);
      if (!manifest) {
        isCompiling = false;
        return;
      }

      const { clusterId, compilationProfile } = manifest.submitParams;
      const { topic, sources, relatedArticles, compilationProfile: profile } = manifest.manifest;

      const sourcesText = sources
        .map((s) => `### ${s.title}\n[source:${s.sourceId}]\n${s.content}`)
        .join("\n\n---\n\n");

      const relatedText =
        relatedArticles.length > 0
          ? `Related articles (use [[Title]] to link): ${relatedArticles.map((r) => r.title).join(", ")}`
          : "No related articles.";

      const compilationPrompt = `You are compiling knowledge sources into a structured article.

Topic: ${topic}
Profile: ${profile.type} (${profile.tone})
Sections to include: ${profile.sections.join(", ")}

${relatedText}

SOURCES TO SYNTHESIZE:
${sourcesText}

INSTRUCTIONS:
1. Write a comprehensive article following the sections: ${profile.sections.join(", ")}
2. Cite sources using [source:UUID] format
3. Link to related articles using [[Exact Title]] - ONLY use titles from the related articles list
4. Extract entities (technologies, patterns, concepts) mentioned
5. Extract relations between entities

OUTPUT FORMAT (JSON):
{
  "title": "Article title",
  "content": "Full markdown article content",
  "entities": [{"name": "EntityName", "type": "technology|pattern|concept|decision"}],
  "relations": [{"from": "Entity1", "to": "Entity2", "type": "uses|depends_on|similar_to"}]
}`;

      // child session — compile prompt is invisible to user.
      const parsed = await runInChildSession<{
        title: string;
        content: string;
        entities?: Array<{ name: string; type: string }>;
        relations?: Array<{ from: string; to: string; type: string }>;
      }>(sessionId, "compile", compilationPrompt, (text) => {
        const m = text.match(/\{[\s\S]*"title"[\s\S]*"content"[\s\S]*\}/);
        if (!m) return null;
        try {
          const p = JSON.parse(m[0]);
          if (typeof p?.title === "string" && typeof p?.content === "string") return p;
        } catch {}
        return null;
      });

      if (parsed) {
        try {
          await submitCompiledArticle(
            config.token,
            parsed.title,
            parsed.content,
            clusterId,
            compilationProfile,
            parsed.entities ?? [],
            parsed.relations ?? [],
          );
        } catch {}
      }

      lastCompileTime = Date.now();
    } finally {
      isCompiling = false;
    }
  }

  /**
   * ENFORCED HIVE CONTRIBUTION: Transform scraped content via BYOLLM
   * Only runs if user opted-in (hiveContributionEnabled) and items are pending
   */
  let isContributingToHive = false;
  let lastHiveContributionTime = 0;

  async function runHiveContribution(sessionId: string): Promise<void> {
    if (isContributingToHive) return;

    const now = Date.now();
    if (now - lastHiveContributionTime < HIVE_COOLDOWN_MS) return;

    isContributingToHive = true;

    try {
      const pendingItems = await fetchPendingHiveItems(config.token);
      if (pendingItems.length === 0) {
        return;
      }

      // Process one item at a time to avoid overloading
      const item = pendingItems[0];

      const transformPrompt = `Transform this community-sourced content into a structured Hive article.

SOURCE:
Title: ${item.title}
URL: ${item.sourceUrl}
Source: ${item.source}
Upvotes: ${item.upvotes}
Tags: ${item.tags.join(", ")}

Content:
${item.body}

${item.answerBody ? `Answer/Solution:\n${item.answerBody}` : ""}

INSTRUCTIONS:
1. Write a clear title: "[Technology]: Clear description of the gotcha/pattern"
2. Structure the content with sections:
   - ## The Gotcha / The Pattern (what's unexpected or useful)
   - ## Why It Matters (explanation + bad code example if applicable)
   - ## The Fix / Best Practice (solution + good code example)
   - ## Real-World Impact (consequences or benefits)
3. Extract technologies mentioned (lowercase array)
4. Classify patternType: "gotcha" | "best_practice" | "anti_pattern" | "integration_tip"
5. Assign severity: "low" | "medium" | "high" | "critical"

OUTPUT FORMAT (JSON):
{
  "title": "Clear descriptive title",
  "content": "Full markdown article",
  "technologies": ["tech1", "tech2"],
  "patternType": "gotcha|best_practice|anti_pattern|integration_tip",
  "severity": "low|medium|high|critical"
}`;

      // child session — hive transform prompt is invisible to user.
      const parsed = await runInChildSession<{
        title: string;
        content: string;
        technologies: string[];
        patternType: string;
        severity?: string;
      }>(sessionId, "hive", transformPrompt, (text) => {
        const m = text.match(/\{[\s\S]*"title"[\s\S]*"content"[\s\S]*\}/);
        if (!m) return null;
        try {
          const p = JSON.parse(m[0]);
          if (
            typeof p?.title === "string" &&
            typeof p?.content === "string" &&
            Array.isArray(p?.technologies) &&
            typeof p?.patternType === "string"
          ) {
            return p;
          }
        } catch {}
        return null;
      });

      if (parsed) {
        try {
          await submitHiveArticle(
            config.token,
            item.id,
            parsed.title,
            parsed.content,
            parsed.technologies,
            parsed.patternType,
            parsed.severity ?? "medium",
          );
        } catch {}
      }

      lastHiveContributionTime = Date.now();
    } finally {
      isContributingToHive = false;
    }
  }

  /**
   * Queue diff for batch analysis on session.idle
   * This avoids noisy prompts during active editing
   */
  const pendingDiffs: Array<{ filePath: string; diff: string; projectOrigin: string }> = [];

  function queueDiffForAnalysis(filePath: string, diff: string, projectOrigin: string): void {
    const lines = diff.split("\n").length;
    if (lines < INGEST_ANALYSIS_MIN_LINES) return;

    // Dedupe by filePath - keep latest diff
    const existingIdx = pendingDiffs.findIndex((d) => d.filePath === filePath);
    if (existingIdx >= 0) {
      pendingDiffs[existingIdx] = { filePath, diff, projectOrigin };
    } else {
      pendingDiffs.push({ filePath, diff, projectOrigin });
    }
  }

  /**
   * Process queued diffs on session.idle - runs BYOLLM analysis silently
   */
  async function _processQueuedDiffs(sessionId: string): Promise<void> {
    if (pendingDiffs.length === 0) return;

    // Take up to 3 diffs to process
    const toProcess = pendingDiffs.splice(0, 3);

    for (const { filePath, diff, projectOrigin } of toProcess) {
      try {
        const analysisPrompt = `Analyze this code change. Output ONLY valid JSON, no explanation.

File: ${filePath}
Project: ${projectOrigin}

CHANGE:
${diff.slice(0, 3000)}

Reusable: bug fixes with root cause, design decisions, patterns, gotchas, integration insights.
NOT reusable: refactoring, renaming, formatting, project-specific logic.

{"shouldIngest":true/false,"reason":"...","title":"...","content":"...","sourceType":"bug_fix|pattern|decision|learning","tags":[]}`;

        // child session — diff analysis prompt is invisible.
        const parsed = await runInChildSession<{
          shouldIngest: boolean;
          title?: string;
          content?: string;
          sourceType?: string;
          tags?: string[];
        }>(sessionId, "compile", analysisPrompt, (text) => {
          const m = text.match(/\{[\s\S]*"shouldIngest"[\s\S]*\}/);
          if (!m) return null;
          try {
            const p = JSON.parse(m[0]);
            return typeof p?.shouldIngest === "boolean" ? p : null;
          } catch {
            return null;
          }
        });

        if (parsed?.shouldIngest && parsed.title && parsed.content) {
          await submitIngest(
            config.token,
            parsed.title,
            parsed.content,
            parsed.sourceType ?? "learning",
            projectOrigin,
            parsed.tags ?? [],
          );
        }
      } catch {}
    }
  }

  /**
   * Check if compilation should run (time-based trigger)
   */
  async function maybeRunCompilation(sessionId: string): Promise<void> {
    const now = Date.now();
    if (now - lastCompileTime < COMPILE_INTERVAL_MS) return;
    if (now - lastCompileCheck < COMPILE_COOLDOWN_MS) return;

    lastCompileCheck = now;

    const stats = await fetchKBStats(config.token);
    if (stats && stats.pendingClusters > 0) {
      runCompilation(sessionId).catch(() => {});
    }
  }

  // -------------------------------------------------------------------------
  // Plugin hooks
  // -------------------------------------------------------------------------

  return {
    tool: { pekg_connect: buildConnectTool(ctx.$) },

    // -----------------------------------------------------------------------
    // chat.message: ENFORCE context injection + BYOLLM blocker verification
    // -----------------------------------------------------------------------
    "chat.message": async (input, output) => {
      const sessionID = input?.sessionID;

      // skip our own child sessions to break the BYOLLM-verifier loop class.
      if (await isPekgManagedSession(sessionID)) return;

      // Bug #1 fix: read text from output.parts (UserMessage has no .content field).
      const textParts = (output.parts ?? [])
        .filter((p: MessagePart) => p.type === "text")
        .map((p: MessagePart) => p.text ?? "")
        .join("\n");
      const promptText = textParts;

      // Time-based compilation trigger
      if (sessionID) {
        maybeRunCompilation(sessionID).catch(() => {});
      }

      if (!promptText || promptText.length < 10) return;

      // stable projectOrigin via git rev-parse (worktree-correct).
      const projectOrigin = getProjectOrigin();

      // C1 cross-session memory: rehydrate persisted state if any.
      // session.created handles -c continuation, but rehydrate here too as a
      // safety net for paths where session.created didn't fire (e.g. plugin
      // reload mid-session).
      if (sessionID) rehydrateBlockerState(sessionID);

      // -----------------------------------------------------------------------
      // FLASH COMPACTION: Capture task from user messages.
      // M5 fix: only set currentTask when it's empty. Previous code overwrote
      // it on every imperative-shaped follow-up ("test the connection",
      // "check the logs"), so post-compaction the agent saw the most recent
      // imperative phrase rather than the actual task.
      // -----------------------------------------------------------------------
      if (sessionID && promptText.length > 30) {
        const taskState = getOrCreateSessionTaskState(sessionID);
        if (!taskState.currentTask) {
          taskState.currentTask = promptText.slice(0, 200);
        }
      }

      // first-message-only full injection. After turn 1, fetch only
      // blockers + guaranteed; the model has the relevant warnings/info cached.
      const isFirstMessage = sessionID ? !firstMessageInjected.get(sessionID) : true;

      // Cross-session resume injection: on the first message of a session that
      // was rehydrated from a prior persistence (e.g. `opencode -c`), surface
      // the prior task + recent files so the agent can continue rather than
      // claiming it doesn't remember anything.
      let resumedSessionBlock = "";
      if (isFirstMessage && sessionID) {
        const rehydratedTask = sessionTaskState.get(sessionID);
        // Only treat as "resumed" if state existed BEFORE this turn's user
        // message touched it. The chat.message hook only sets currentTask
        // (above), so a non-empty filesModified or filesRead at this point
        // necessarily came from prior-session persistence.
        const hasResumeFiles =
          (rehydratedTask?.activeFiles.filesModified.size ?? 0) > 0 ||
          (rehydratedTask?.activeFiles.filesRead.size ?? 0) > 0;
        if (hasResumeFiles) {
          const lines: string[] = ["RESUMED SESSION (from prior persisted state):"];
          if (rehydratedTask?.currentTask) lines.push(`  Task: ${rehydratedTask.currentTask}`);
          const filesArr = [...(rehydratedTask?.activeFiles.filesModified ?? [])];
          if (filesArr.length > 0) {
            lines.push("  Recently modified:");
            for (const f of filesArr.slice(-5)) lines.push(`    - ${f}`);
          }
          if ((rehydratedTask?.failedApproaches.length ?? 0) > 0) {
            lines.push("  Approaches already tried (avoid repeating):");
            for (const a of rehydratedTask!.failedApproaches.slice(-3)) lines.push(`    - ${a}`);
          }
          resumedSessionBlock = `${lines.join("\n")}\n\n`;
        }
      }

      // Fetch guaranteed blocks (project_config, user_preferences) in parallel with context
      const [result, guaranteedBlocks] = await Promise.all([
        fetchContext(config.token, projectOrigin, promptText.slice(0, 500)),
        fetchGuaranteedBlocks(config.token, projectOrigin),
      ]);

      // A48 revised: fail-open on network error. Don't install a NETWORK_BLOCKER
      // that gates edits — just skip context enrichment this turn.
      // The agent loses KB context but can keep working. Override with PEKG_OFFLINE=1
      // to suppress all PeKG features proactively.
      // (Old fail-closed behavior removed: it caused deadlocks when API unreachable)

      // when the fetch succeeds, drop any stale network blocker.
      if (result.status === "ok" && sessionID) {
        const existing = activeBlockers.get(sessionID);
        if (existing?.blockers.some((b) => b.articleId === NETWORK_BLOCKER_ID)) {
          const remaining = existing.blockers.filter((b) => b.articleId !== NETWORK_BLOCKER_ID);
          if (remaining.length === 0) {
            activeBlockers.delete(sessionID);
          } else {
            existing.blockers = remaining;
          }
          persistBlockerState(sessionID);
        }
      }

      // when the fetch succeeds with NO blockers returned, clear any prior real
      // blockers — the parentplan ("blocker cleared only when next context returns
      // zero blockers" instead of "after one edit"). Replaces the deleted activeBlockers.delete
      // in tool.execute.after.
      if (result.status === "empty" && sessionID) {
        const existing = activeBlockers.get(sessionID);
        if (existing?.blockers.every((b) => b.articleId !== NETWORK_BLOCKER_ID)) {
          activeBlockers.delete(sessionID);
          persistBlockerState(sessionID);
        }
      }

      if (result.status !== "ok" || (!result.context && guaranteedBlocks.length === 0)) return;

      // on subsequent messages, inject blockers + guaranteed only.
      // Full context (including warnings/info) is rendered only on the first turn.
      const renderedContext =
        isFirstMessage || INJECT_FULL_CONTEXT_ON_FIRST_ONLY === false
          ? result.context
          : renderBlockersOnly(result.blockers);

      const ctxHash = hashContext(renderedContext + (guaranteedBlocks.length ? "+g" : ""));
      // Per-session dedup so compacting session A doesn't wipe session B's hashes.
      const sessionHashes = sessionID
        ? (seenContextHashesBySession.get(sessionID) ?? new Set<string>())
        : new Set<string>();
      if (sessionHashes.has(ctxHash)) return;
      sessionHashes.add(ctxHash);
      if (sessionID) seenContextHashesBySession.set(sessionID, sessionHashes);

      const messageID = input?.messageID;
      if (!sessionID || !messageID) return;

      recordShownArticles(sessionID, result.articles);

      shownContextForVerification.set(sessionID, {
        articles: result.articles,
        contextText: renderedContext,
        timestamp: Date.now(),
      });

      if (result.blockers.length > 0) {
        // Issue 7: preserve ackedAt across context refreshes — when the same
        // blocker articleId is re-emitted, the prior ack timestamp keeps
        // cooldown active. Drop entries for blockers that no longer appear
        // in the new context to bound memory; prune anything past prune-MS.
        const existing = activeBlockers.get(sessionID);
        const newIds = new Set(result.blockers.map((b) => b.articleId));
        const carriedAcks: Record<string, number> = {};
        if (existing?.ackedAt) {
          for (const id of Object.keys(existing.ackedAt)) {
            if (newIds.has(id)) carriedAcks[id] = existing.ackedAt[id];
          }
          pekgPruneAckedAt(carriedAcks, Date.now(), BLOCKER_ACK_PRUNE_MS);
        }
        activeBlockers.set(sessionID, {
          blockers: result.blockers,
          acknowledged: false,
          verificationPending: false,
          ackedAt: Object.keys(carriedAcks).length > 0 ? carriedAcks : undefined,
        });
        persistBlockerState(sessionID);
      }

      const hasBlockers = result.blockers.length > 0;
      const hasPendingDiffs = pendingDiffs.length > 0;

      // Build guaranteed blocks section (project_config, user_preferences)
      // These are always shown regardless of relevance - solves "agent forgets commands" problem
      let guaranteedSection = "";
      if (guaranteedBlocks.length > 0) {
        const lines: string[] = ["PROJECT KNOWLEDGE (always active):"];
        for (const g of guaranteedBlocks) {
          const content = (g.summary || g.snippet || "").replace(/\n/g, " ").slice(0, 300);
          lines.push(`  [${g.articleId.slice(0, 8)}] ${g.title}`);
          lines.push(`      ${content}`);
        }
        guaranteedSection = `${lines.join("\n")}\n\n`;
      }

      let injectionText: string;
      if (hasBlockers) {
        // Issue 10: compact banner. First line is the summary (~70 chars,
        // counts toward whatever the agent actually reads). Detail block
        // follows; agents that skim past long blocks still see the
        // headline. Long-form rules now in the verifier prompt only.
        const blockerCount = result.blockers.length;
        const summary = `pekg: ${blockerCount} active blocker(s) — ack format: quote title + concrete mitigation`;
        injectionText = `${summary}

${resumedSessionBlock}${guaranteedSection}${renderedContext}

(File-mutating tools — edit/write/multiedit/apply_patch/bash sed -i tee redirects — are gated until each blocker is acked by title with a concrete mitigation. Generic acks fail verification.)`;
      } else if (renderedContext || guaranteedSection || resumedSessionBlock) {
        injectionText = `PeKG Knowledge:

${resumedSessionBlock}${guaranteedSection}${renderedContext}`;
      } else {
        return; // nothing useful to inject this turn
      }

      // Auto-ingestion: if there are pending diffs, ask agent to assess
      if (hasPendingDiffs) {
        const diffFile = pendingDiffs[pendingDiffs.length - 1].filePath.split("/").pop();
        injectionText += `\n[PeKG] If your recent edit to ${diffFile} contains reusable knowledge (bug fix, pattern, gotcha), end your response with:
KB_INGEST: Title | type | brief description
Types: bug_fix, pattern, decision, learning, gotcha. Skip if it's just refactoring/formatting.`;
      }

      // Also append any queued proactive context from tool executions
      const queuedContext = pendingProactiveContext.get(sessionID);
      if (queuedContext && queuedContext.length > 0) {
        injectionText += `\n\n${queuedContext.join("\n\n")}`;
        pendingProactiveContext.delete(sessionID);
      }

      // FIX: Store context for system.transform instead of pushing to output.parts.
      // output.parts.unshift() with synthetic:true STILL bleeds into TUI input area.
      // output.system.push() in system.transform NEVER renders in TUI.
      pendingSystemContext = injectionText;

      // mark first-message-injected so subsequent turns skip warnings/info.
      firstMessageInjected.set(sessionID, true);
    },

    // tool.execute.before: gate file mutations, propagate blockers into
    // task-subagents, queue proactive context on file reads / pattern searches.
    "tool.execute.before": async (input, output) => {
      const toolName = input.tool?.toLowerCase() ?? "";
      const sessionId = input.sessionID;
      // skip our own child sessions (verifier/compile/hive).
      if (await isPekgManagedSession(sessionId)) return;
      const projectOrigin = getProjectOrigin();

      // PROACTIVE CONTEXT - Queue context for injection on file reads
      if (toolName === "read" && sessionId && output.args?.filePath) {
        const filePath = output.args.filePath;
        const now = Date.now();
        const lastShown = proactiveContextShown.get(sessionId) ?? 0;

        // Check cooldown to avoid spamming
        if (now - lastShown > PROACTIVE_CONTEXT_COOLDOWN_MS) {
          // Fetch context based on file path
          const fileBaseName = filePath.split("/").pop() || "";
          const result = await fetchContext(config.token, projectOrigin, `reading ${fileBaseName}`);

          if (result.status === "ok" && result.context) {
            const queue = pendingProactiveContext.get(sessionId) ?? [];
            queue.push(`PeKG context for ${fileBaseName}:\n${result.context}`);
            pendingProactiveContext.set(sessionId, queue);
            proactiveContextShown.set(sessionId, now);

            if (result.blockers.length > 0) {
              activeBlockers.set(sessionId, {
                blockers: result.blockers,
                acknowledged: false,
                verificationPending: false,
              });
              persistBlockerState(sessionId);
            }

            recordShownArticles(sessionId, result.articles);
            shownContextForVerification.set(sessionId, {
              articles: result.articles,
              contextText: result.context,
              timestamp: now,
            });
          }
        }
      }

      // PROACTIVE SEARCH - When agent searches for patterns, search PeKG too
      if ((toolName === "grep" || toolName === "glob") && sessionId && output.args?.pattern) {
        const pattern = output.args.pattern;
        const now = Date.now();
        const lastShown = proactiveContextShown.get(sessionId) ?? 0;

        if (now - lastShown > PROACTIVE_CONTEXT_COOLDOWN_MS) {
          // Search PeKG for the same pattern
          const articles = await searchKnowledge(config.token, pattern, 3);

          if (articles.length > 0) {
            const contextLines = articles.map((a) => {
              const summary = (a.summary || a.snippet || "").replace(/\n/g, " ").slice(0, 150);
              return `  [${a.articleId.slice(0, 8)}] ${a.title}: ${summary}`;
            });

            const queue = pendingProactiveContext.get(sessionId) ?? [];
            queue.push(`PeKG found knowledge related to "${pattern}":\n${contextLines.join("\n")}`);
            pendingProactiveContext.set(sessionId, queue);
            proactiveContextShown.set(sessionId, now);
            recordShownArticles(sessionId, articles);
          }
        }
      }

      // Inject context into Task prompts (for subagents) and propagate active blockers
      // so a subagent inherits the parent's enforcement state.
      if (toolName === "task" && output.args?.prompt) {
        const taskSummary = `${output.args.description ?? ""}: ${output.args.prompt}`.slice(0, 800);
        const result = await fetchContext(config.token, projectOrigin, taskSummary);
        const parentBlockerState = sessionId ? activeBlockers.get(sessionId) : undefined;

        const preambleParts: string[] = [];
        if (result.status === "ok" && result.context) {
          preambleParts.push(`<pekg-context>\n${result.context}\n</pekg-context>`);
        }
        if (parentBlockerState && !parentBlockerState.acknowledged && parentBlockerState.blockers.length > 0) {
          // Issue 9: filter inherited blockers by relevance to the subagent's
          // task prompt (token-overlap scoring + top-3 cap). Drops blockers
          // unrelated to the subagent's work — e.g. parent has a CSS blocker,
          // subagent is asked to write tests, the CSS blocker drops out.
          const subagentPrompt = `${output.args.description ?? ""}: ${output.args.prompt ?? ""}`;
          const { kept, filteredCount } = pekgFilterInheritedBlockers(parentBlockerState.blockers, subagentPrompt);
          if (kept.length > 0) {
            const titles = kept.map((b) => `- ${b.title}`).join("\n");
            const filteredHint =
              filteredCount > 0
                ? `\n(${filteredCount} more parent blocker(s) were filtered as not directly relevant; if your work spans those domains, call pekg_status to see the full set.)`
                : "";
            preambleParts.push(
              `<pekg-blockers-inherited>\nThe parent session has unacknowledged PeKG blockers relevant to your task. Acknowledge them in your first assistant message before any tool use:\n${titles}${filteredHint}\n</pekg-blockers-inherited>`,
            );
          } else if (filteredCount > 0) {
            // Nothing relevant to subagent's task — short hint that parent
            // has blockers, so subagent can opt to fetch its own context.
            preambleParts.push(
              `<pekg-blockers-inherited note="filtered: none directly relevant to subagent task">\nParent session has ${filteredCount} unacknowledged PeKG blocker(s), but none keyword-overlap your task. If your work touches the parent's domain, call pekg_status.\n</pekg-blockers-inherited>`,
            );
          }
        }
        if (preambleParts.length > 0) {
          output.args.prompt = `${preambleParts.join("\n\n")}\n\n${output.args.prompt}`;
        }
      }

      // ENFORCE: BLOCK file mutations across the full set of mutation tools.
      // was edit/write only — now covers multiedit, apply_patch, str_replace_editor, etc.
      // Acknowledgement is verified BY BYOLLM against the assistant's prior message in
      // event:message.updated (Bug #2 fix), so by the time we get here, blockerState.acknowledged
      // is the source of truth. No more checking user-message text in chat.message.
      if (FILE_MUTATING_TOOLS.has(toolName) && sessionId) {
        rehydrateBlockerState(sessionId);
        const blockerState = activeBlockers.get(sessionId);
        if (blockerState && blockerState.blockers.length > 0 && !blockerState.acknowledged) {
          // Issue 7: filter out blockers acked within the cooldown window.
          // Same blocker re-emitted by a context refresh doesn't re-fire the
          // gate immediately after the user just acked it.
          const cooledDown = pekgFilterAckedBlockers(
            blockerState.blockers,
            blockerState.ackedAt,
            Date.now(),
            BLOCKER_ACK_COOLDOWN_MS,
          );
          // Issue 8: markdown re-tier. If the target file is markdown,
          // demote code-domain blockers to warning so they don't gate doc
          // work. Security / privacy / compliance blockers stay at blocker
          // even on markdown.
          const targetFilePath: string | undefined = output.args?.filePath;
          const effectiveBlockers = pekgFilterBlockersForFile(cooledDown, targetFilePath);
          if (effectiveBlockers.length > 0) {
            const blockerTitles = effectiveBlockers.map((b) => b.title).join(", ");
            throw new Error(
              `PeKG BLOCKER: Cannot use ${toolName} until you acknowledge the blockers: ${blockerTitles}. In your next assistant message, quote each blocker by name and describe the concrete change you will make to avoid it. PeKG will verify the acknowledgment is specific (not "acknowledged" / "noted").`,
            );
          }
        }
      }

      // bash file-mutation gate: reject sed -i, tee, redirects, perl -pi, etc.
      // when blockers are unacknowledged. Closes theescape from OPENCODE_PLUGIN_BUGS.md.
      if (toolName === "bash" && sessionId && typeof output.args?.command === "string") {
        const cmd: string = output.args.command;
        if (isWorkspaceFileMutationCommand(cmd, ctx.directory)) {
          rehydrateBlockerState(sessionId);
          const blockerState = activeBlockers.get(sessionId);
          if (blockerState && blockerState.blockers.length > 0 && !blockerState.acknowledged) {
            // Issue 7: same per-blocker cooldown filter as Edit/Write.
            const cooledDown = pekgFilterAckedBlockers(
              blockerState.blockers,
              blockerState.ackedAt,
              Date.now(),
              BLOCKER_ACK_COOLDOWN_MS,
            );
            // Issue 8: if the bash command writes to a markdown file, apply
            // the same re-tier as Edit/Write. Pass a sentinel ".md" path to
            // the filter — we don't have the exact file but the rule only
            // looks at extension class.
            const isMarkdownWrite = pekgBashCmdTargetsMarkdown(cmd);
            const effectiveBlockers = isMarkdownWrite
              ? pekgFilterBlockersForFile(cooledDown, "<bash-target>.md")
              : cooledDown;
            if (effectiveBlockers.length > 0) {
              const titles = effectiveBlockers.map((b) => b.title).join(", ");
              throw new Error(
                `PeKG BLOCKER: This bash command writes to workspace files (sed -i / tee / redirect / perl -pi / etc.) but PeKG blockers are unacknowledged: ${titles}. Acknowledge each blocker by name with a concrete mitigation, then retry.`,
              );
            }
          }
        }
      }

      // Track file content before edit (for diff analysis + feedback verification)
      if (toolName === "edit" && output.args?.filePath && sessionId) {
        try {
          const fs = await import("node:fs");
          const oldContent = fs.existsSync(output.args.filePath) ? fs.readFileSync(output.args.filePath, "utf-8") : "";
          const edits = pendingEdits.get(sessionId) ?? [];
          edits.push({ filePath: output.args.filePath, oldContent, newContent: "" });
          pendingEdits.set(sessionId, edits);
        } catch {}
      }
    },

    // tool.execute.after: feedback verification, queued ingestion analysis,
    // technology detection on file reads, FLASH COMPACTION file/failure tracking.
    "tool.execute.after": async (input, output) => {
      const toolName = input.tool?.toLowerCase() ?? "";
      const sessionId = input.sessionID;
      // Skip our own child sessions — child verifiers don't pollute parent task state.
      if (await isPekgManagedSession(sessionId)) return;
      const projectOrigin = getProjectOrigin();

      // -----------------------------------------------------------------------
      // FLASH COMPACTION: Track file operations for compaction prompt.
      // Note: opencode's tool.execute.after passes output as { title, output, metadata }
      // (see packages/opencode/src/session/prompt.ts:432-436 + tool/tool.ts wrapper).
      // Earlier versions of this code read output.error / output.stderr / output.result /
      // output.content — none of those exist on the SDK type, so the features were
      // silently dead. Use output.output (string) for tool stdout-equivalent, and
      // output.metadata for structured fields.
      // -----------------------------------------------------------------------
      if (sessionId) {
        const taskState = getOrCreateSessionTaskState(sessionId);

        // Track read operations
        if (toolName === "read" && input.args?.filePath) {
          taskState.activeFiles.filesRead.add(input.args.filePath);
          taskState.activeFiles.fileOperations.push({
            type: "read",
            path: input.args.filePath,
            timestamp: Date.now(),
          });
        }

        // Track write/edit operations
        if ((toolName === "edit" || toolName === "write") && input.args?.filePath) {
          taskState.activeFiles.filesModified.add(input.args.filePath);
          taskState.activeFiles.fileOperations.push({
            type: "edited",
            path: input.args.filePath,
            timestamp: Date.now(),
          });
        }

        // Track glob results — opencode's glob tool returns its results in output.output
        // as a newline-separated list. v3.11.x read output.result which doesn't exist.
        if (toolName === "glob" && typeof (output as ToolOutputShape)?.output === "string") {
          const resultText = (output as ToolOutputShape).output as string;
          const files = resultText.split("\n").filter((f: string) => f.trim() && !f.startsWith("Found"));
          for (const f of files.slice(0, 10)) {
            taskState.activeFiles.filesDiscovered.add(f.trim());
          }
        }

        // Tool errors do NOT come through output.error/stderr — that's not in the SDK
        // type and opencode's runtime doesn't even fire tool.execute.after when execute()
        // throws (see packages/opencode/src/session/prompt.ts). Instead, opencode marks
        // the ToolPart as state.status === "error" and emits message.part.updated.
        // For now, we don't track failures via this hook; the field-name fix here
        // documents the intent without claiming the feature works. To capture errors,
        // subscribe to event:message.part.updated and inspect ToolPart.state.
      }

      // Detect technologies from file reads and trigger proactive searches.
      // The read tool returns file content via output.output (per the wrapper at
      // packages/opencode/src/tool/tool.ts). Earlier code read output.content /
      // output.result — neither exists, so detectTechnologies always saw "".
      if (toolName === "read" && sessionId) {
        const fileContent =
          typeof (output as ToolOutputShape)?.output === "string" ? ((output as ToolOutputShape).output as string) : "";
        if (typeof fileContent === "string" && fileContent.length > 0) {
          const techs = detectTechnologies(fileContent);

          if (techs.length > 0) {
            // Track detected technologies for this session
            const sessionTechs = detectedTechBySession.get(sessionId) ?? new Set();
            const newTechs = techs.filter((t) => !sessionTechs.has(t));

            if (newTechs.length > 0) {
              // Add to session tracking
              for (const t of newTechs) {
                sessionTechs.add(t);
              }
              detectedTechBySession.set(sessionId, sessionTechs);

              // Search for pitfalls related to newly detected technologies
              const searchTerms = getSearchTermsForTech(newTechs);
              if (searchTerms.length > 0) {
                const query = `${searchTerms.slice(0, 3).join(" ")} pitfalls gotchas`;
                const articles = await searchKnowledge(config.token, query, 3);

                if (articles.length > 0) {
                  const contextLines = articles.map((a) => {
                    const summary = (a.summary || a.snippet || "").replace(/\n/g, " ").slice(0, 150);
                    return `  [${a.articleId.slice(0, 8)}] ${a.title}: ${summary}`;
                  });

                  // Use TUI toast to show context immediately
                  try {
                    await ctx.client.tui.showToast({
                      body: {
                        message: `PeKG: Found ${articles.length} articles for ${newTechs.join(", ")}`,
                        variant: "info",
                      },
                    });
                  } catch {}

                  // Also queue for next message
                  const queue = pendingProactiveContext.get(sessionId) ?? [];
                  queue.push(
                    `PeKG detected ${newTechs.join(", ")} in code. Relevant knowledge:\n${contextLines.join("\n")}`,
                  );
                  pendingProactiveContext.set(sessionId, queue);
                  recordShownArticles(sessionId, articles);
                }
              }
            }
          }
        }
      }

      // After a successful file-mutating tool: BYOLLM verify feedback, analyze for ingestion.
      // blockers are NO LONGER auto-cleared here. They're cleared only when the next
      // chat.message context fetch returns zero blockers, so a single ack doesn't grant
      // unlimited follow-on edits.
      if (FILE_MUTATING_TOOLS.has(toolName) && sessionId) {
        // Get the diff for feedback verification and ingestion analysis
        if (toolName === "edit" && input.args?.filePath) {
          try {
            const fs = await import("node:fs");
            const newContent = fs.existsSync(input.args.filePath) ? fs.readFileSync(input.args.filePath, "utf-8") : "";

            const edits = pendingEdits.get(sessionId) ?? [];
            const pending = edits.find((e) => e.filePath === input.args.filePath);
            if (pending) {
              pending.newContent = newContent;
              const diff = `Old:\n${pending.oldContent.slice(0, 1000)}\n\nNew:\n${newContent.slice(0, 1000)}`;

              // BYOLLM: Verify feedback accuracy before submitting
              const shownCtx = shownContextForVerification.get(sessionId);
              if (shownCtx && shownCtx.articles.length > 0) {
                const verifiedSignal = await verifyFeedbackAccuracy(sessionId, shownCtx, input.args.filePath, diff);

                if (verifiedSignal && verifiedSignal !== "ignored") {
                  // Submit verified feedback
                  for (const article of shownCtx.articles) {
                    const signal = verifiedSignal === "avoided_bug" ? "avoided_bug" : "applied";
                    const success = await submitFeedback(config.token, article.articleId, signal, projectOrigin);
                    if (!success) {
                      await queueFeedback({
                        articleId: article.articleId,
                        signal,
                        projectOrigin,
                        timestamp: Date.now(),
                      });
                    }
                  }
                }
                // If "ignored", don't submit feedback - context wasn't used

                shownContextForVerification.delete(sessionId);
              } else {
                // No context was shown, use legacy implicit feedback
                submitImplicitFeedback(sessionId, projectOrigin).catch(() => {});
              }

              queueDiffForAnalysis(input.args.filePath, diff, projectOrigin);
            }
          } catch {}
        } else {
          // Write tool or edit without filePath - use legacy feedback
          submitImplicitFeedback(sessionId, projectOrigin).catch(() => {});
        }
      }
    },

    // -----------------------------------------------------------------------
    // event: Handle session.idle + message.updated + file.edited for auto-ingestion
    // -----------------------------------------------------------------------
    event: async ({ event }) => {
      const props = ((event as { properties?: EventProperties }).properties ?? {}) as EventProperties;

      // session.created: rehydrate persisted task + blocker state from a prior
      // session with the same ID (relevant for `opencode -c` continuation).
      // The plan's cross-session-memory feature was missing in v3.11.x because
      // the loader was never wired here.
      if (event.type === "session.created") {
        const sessionId = props.info?.id ?? props.sessionID;
        if (sessionId) {
          if (await isPekgManagedSession(sessionId)) return;
          rehydrateBlockerState(sessionId);
        }
        return;
      }

      // Handle file.edited - detect technologies from edited files + FLASH COMPACTION tracking
      if (event.type === "file.edited") {
        if (await isPekgManagedSession(props.sessionID)) return;
        const filePath = props.path ?? props.filePath;
        const sessionId = props.sessionID;

        if (filePath && sessionId) {
          // FLASH COMPACTION: Track file modifications
          const taskState = getOrCreateSessionTaskState(sessionId);
          taskState.activeFiles.filesModified.add(filePath);
          taskState.activeFiles.fileOperations.push({
            type: "edited",
            path: filePath,
            timestamp: Date.now(),
          });

          try {
            const fs = await import("node:fs");
            if (fs.existsSync(filePath)) {
              const content = fs.readFileSync(filePath, "utf-8");
              const techs = detectTechnologies(content);

              if (techs.length > 0) {
                const sessionTechs = detectedTechBySession.get(sessionId) ?? new Set();
                const newTechs = techs.filter((t) => !sessionTechs.has(t));

                if (newTechs.length > 0) {
                  for (const t of newTechs) {
                    sessionTechs.add(t);
                  }
                  detectedTechBySession.set(sessionId, sessionTechs);

                  // Queue context for next message
                  const searchTerms = getSearchTermsForTech(newTechs);
                  if (searchTerms.length > 0) {
                    const query = `${searchTerms.slice(0, 3).join(" ")} pitfalls`;
                    const articles = await searchKnowledge(config.token, query, 2);

                    if (articles.length > 0) {
                      const contextLines = articles.map((a) => {
                        const summary = (a.summary || a.snippet || "").replace(/\n/g, " ").slice(0, 100);
                        return `  [${a.articleId.slice(0, 8)}] ${a.title}: ${summary}`;
                      });

                      const queue = pendingProactiveContext.get(sessionId) ?? [];
                      queue.push(`PeKG: File uses ${newTechs.join(", ")}. Watch for:\n${contextLines.join("\n")}`);
                      pendingProactiveContext.set(sessionId, queue);
                      recordShownArticles(sessionId, articles);
                    }
                  }
                }
              }
            }
          } catch {}
        }
        return;
      }

      // Handle message.updated - check for KB_INGEST pattern in agent responses
      if (event.type === "message.updated") {
        const messageInfo = props.info;
        if (!messageInfo) return;

        // Skip user messages - we only want assistant responses
        if (messageInfo.role === "user") return;

        // Only process completed messages (has time.completed)
        if (!messageInfo.time?.completed) return;

        const sessionId = messageInfo.sessionID;
        const messageId = messageInfo.id;
        if (!sessionId || !messageId) return;

        // skip our own child sessions (verifier/compile/hive replies).
        if (await isPekgManagedSession(sessionId)) return;

        // Deduplicate: only process each message once
        if (processedIngestMessages.has(messageId)) return;
        processedIngestMessages.add(messageId);

        // Fetch the actual message content from the SDK
        // Note: SDK uses messageID (uppercase ID) per official types
        let content = "";
        try {
          const messageData = await ctx.client.session.message({
            path: { id: sessionId, messageID: messageId },
          });

          // SDK returns { data: { info, parts } } with responseStyle: 'fields'
          const parts = (messageData as MessageResponse)?.data?.parts ?? [];
          content = parts
            .filter((p: MessagePart) => p.type === "text")
            .map((p: MessagePart) => p.text ?? "")
            .join("\n");
        } catch {
          return;
        }

        if (!content) return;

        const projectOrigin = getProjectOrigin();

        // Ack detection uses a DETERMINISTIC text heuristic (not session.prompt
        // on the parent — that would render the verifier prompt in the TUI and
        // recurse on its own message.updated event). For high-signal cases the
        // child-session BYOLLM verifier in tool.execute.before will reconfirm.
        rehydrateBlockerState(sessionId);
        const blockerState = activeBlockers.get(sessionId);
        if (blockerState && !blockerState.acknowledged && blockerState.blockers.length > 0) {
          const onlyNetworkBlocker = blockerState.blockers.every((b) => b.articleId === NETWORK_BLOCKER_ID);
          if (!onlyNetworkBlocker) {
            // Issue 7: record per-blocker ack timestamps for blockers
            // explicitly addressed in the response. Even if the heuristic
            // doesn't reach majority threshold, the agent's intent toward
            // SPECIFIC blockers buys those a 10-minute cooldown window —
            // so a context refresh that re-emits them doesn't immediately
            // re-block the next file edit.
            const matched = getHeuristicallyAcknowledgedBlockers(content, blockerState.blockers);
            const now = Date.now();
            if (matched.length > 0) {
              blockerState.ackedAt = blockerState.ackedAt ?? {};
              for (const m of matched) {
                blockerState.ackedAt[m.articleId] = now;
              }
              pekgPruneAckedAt(blockerState.ackedAt, now, BLOCKER_ACK_PRUNE_MS);
            }
            // Full session-wide ack still requires majority match (existing
            // semantics). Once set, the gate skips entirely. ackedAt is the
            // "partial credit" path for blockers individually.
            const required = Math.max(1, Math.ceil(blockerState.blockers.length / 2));
            if (matched.length >= required) {
              blockerState.acknowledged = true;
              blockerState.verifiedAt = now;
              blockerState.lastAgentResponse = content;
            }
            activeBlockers.set(sessionId, blockerState);
            persistBlockerState(sessionId);
          }
        }

        // Look for KB_INGEST: title | type | description pattern
        const ingestMatch = content.match(/KB_INGEST:\s*([^|]+)\s*\|\s*([^|]+)\s*\|\s*(.+?)(?:\n|$)/i);
        if (ingestMatch) {
          const [, title, sourceType, description] = ingestMatch;
          const cleanTitle = title.trim();
          const cleanType = sourceType.trim().toLowerCase().replace(/\s+/g, "_");
          const cleanDesc = description.trim();

          // Validate source type
          const validTypes = ["bug_fix", "pattern", "decision", "learning", "gotcha", "architecture"];
          const finalType = validTypes.includes(cleanType) ? cleanType : "learning";

          // Build content from description + any pending diff context
          let fullContent = `## Problem\n\n${cleanDesc}\n`;

          // Add diff context if available
          if (pendingDiffs.length > 0) {
            const recentDiff = pendingDiffs[pendingDiffs.length - 1];
            fullContent += `\n## Solution\n\nApplied in \`${recentDiff.filePath}\`:\n\n\`\`\`\n${recentDiff.diff.slice(0, 1500)}\n\`\`\`\n`;
            pendingDiffs.length = 0; // Clear after use
          }

          // Submit to ingest API (fire-and-forget)
          submitIngest(config.token, cleanTitle, fullContent, finalType, projectOrigin, []).catch(() => {});
        }
        return;
      }

      // Handle session.idle for compilation and hive
      if (event.type !== "session.idle") return;

      const sessionId = props.sessionID;
      if (!sessionId) return;
      // Skip our own child sessions — runCompilation/runHive shouldn't fire on a verifier session.
      if (await isPekgManagedSession(sessionId)) return;

      // Persist task + blocker state on every idle so cross-session memory
      // works without requiring compaction or active blockers. This MUST fire
      // before the compile-cooldown gate below — idle is the only natural
      // turn-end signal we have, and selective-persistence inside the function
      // skips empty sessions anyway.
      persistBlockerState(sessionId);

      const now = Date.now();
      if (now - lastCompileCheck < COMPILE_COOLDOWN_MS) return;
      lastCompileCheck = now;

      const stats = await fetchKBStats(config.token);
      if (!stats) return;

      // Run compilation if pending clusters exist
      if (stats.pendingClusters > 0) {
        runCompilation(sessionId).catch(() => {});
      }

      // Run hive contribution if user opted-in and items are pending
      if (stats.hiveContributionEnabled && stats.hivePendingCount > 0) {
        runHiveContribution(sessionId).catch(() => {});
      }

      // Issue 5: surface orphan warning (once per session, only if above threshold)
      if (stats.orphanCount > stats.orphanWarnThreshold && !orphanWarningShownInSession.has(sessionId)) {
        orphanWarningShownInSession.add(sessionId);
        // Queue the warning for next message injection via pendingProactiveContext.
        // Single-line < 200 chars to not overwhelm the agent.
        const warning = `pekg: ${stats.orphanCount} orphan articles -- visit /admin/knowledge to clean up or run pekg_health(scope:full) for details`;
        const queue = pendingProactiveContext.get(sessionId) ?? [];
        queue.push(warning);
        pendingProactiveContext.set(sessionId, queue);
      }
    },

    // -----------------------------------------------------------------------
    // System prompt - Insert base prompt + dynamic context from chat.message
    // FIX: All context injection happens here (system.transform) instead of
    // chat.message (output.parts), because output.parts bleeds into TUI input
    // area even with synthetic:true, but output.system NEVER renders in TUI.
    // -----------------------------------------------------------------------
    "experimental.chat.system.transform": async (_input, output) => {
      // Insert base prompt at position 1 (after provider header) for salience
      const insertAt = output.system.length > 0 ? 1 : 0;
      output.system.splice(insertAt, 0, PEKG_SYSTEM_PROMPT);

      // Consume pending context from chat.message hook (if any).
      // This is the dynamic per-message context (blockers, warnings, guaranteed blocks).
      if (pendingSystemContext) {
        output.system.push(pendingSystemContext);
        pendingSystemContext = null; // consume once
      }

      if (registrationResult === "new" || registrationResult === "token_rotated") {
        output.system.push(PEKG_NEEDS_RESTART);
      }

      await runUpdateCheckOnce();
      if (updatedToVersion) {
        output.system.push(`PeKG plugin updated to v${updatedToVersion}. Restart opencode.`);
      }
    },

    // -----------------------------------------------------------------------
    // Note: an experimental.chat.messages.transform hook used to live here that
    // unshifted a synthetic { info: { role: "system" }, parts: [...] } message
    // to re-declare active blockers every Nth turn. The SDK Message type is
    // UserMessage | AssistantMessage only — there is no system role — so the
    // synthetic shape was rejected by opencode's effect chain and surfaced as
    // a Bun stack trace in the TUI ("at ~effect/Effect/successCont (...)").
    // The redundancy was unnecessary anyway: PEKG_SYSTEM_PROMPT in
    // experimental.chat.system.transform fires every call, and chat.message
    // injects blockers into output.parts on every user message.

    // -----------------------------------------------------------------------
    // permission.ask
    // Independent denial when a file-mutating permission is asked for while
    // unacknowledged blockers exist. Beats user-configured auto-allow because
    // permission.ask runs before the auto-allow logic.
    // -----------------------------------------------------------------------
    // command.execute.before
    // Block /clear /new /compact /reset while unacknowledged blockers exist.
    // Regex matches both "/clear" and "clear" (docs don't specify which OpenCode
    // passes — defensive match makes it moot).
    "command.execute.before": async (input, _output) => {
      const cmdRaw = String((input as HookInput)?.command ?? "").trim();
      if (!cmdRaw) return;
      if (!/^\/?(clear|new|compact|reset)\b/i.test(cmdRaw)) return;

      const sessionID = (input as HookInput)?.sessionID;
      if (!sessionID) return;
      if (await isPekgManagedSession(sessionID)) return;

      rehydrateBlockerState(sessionID);
      const blockerState = activeBlockers.get(sessionID);
      if (!blockerState || blockerState.acknowledged || blockerState.blockers.length === 0) return;

      const titles = blockerState.blockers.map((b) => b.title).join(", ");
      throw new Error(
        `PeKG BLOCKER: Cannot run "${cmdRaw}" while unacknowledged blockers exist: ${titles}. In your next assistant message, quote each blocker by name and describe a concrete mitigation. Or call the pekg_blockers MCP tool to inspect them.`,
      );
    },

    "permission.ask": async (input, output) => {
      const sessionId = (input as HookInput)?.sessionID;
      const tool = String((input as HookInput)?.tool ?? (input as HookInput)?.type ?? "").toLowerCase();
      if (!sessionId) return;
      // don't gate our own internal verification calls.
      if (await isPekgManagedSession(sessionId)) return;
      rehydrateBlockerState(sessionId);
      const blockerState = activeBlockers.get(sessionId);
      if (!blockerState || blockerState.acknowledged || blockerState.blockers.length === 0) return;

      const isMutating = FILE_MUTATING_TOOLS.has(tool) || tool === "bash" || tool === "shell" || tool === "task";
      if (!isMutating) return;

      output.status = "deny";
    },

    // -----------------------------------------------------------------------
    // tool.definition
    // Prepend PeKG enforcement notice to every file-mutating tool description so
    // the LLM sees the gating at tool-selection time, not just on rejection.
    // -----------------------------------------------------------------------
    "tool.definition": async (input, output) => {
      const id = String((input as HookInput)?.toolID ?? "").toLowerCase();
      const isMutating = FILE_MUTATING_TOOLS.has(id) || id === "bash" || id === "task";
      if (!isMutating) return;

      // cache-stable. Compute a hash over the current unacknowledged-blocker
      // article-id set. Skip mutation entirely when there are no active blockers (most common
      // case — don't pollute tool descriptions with enforcement notices when nothing's gated).
      // Re-emit the same description string every call until the blocker set changes.
      let blockerHash = "none";
      const activeBlockerIds: string[] = [];
      for (const [, state] of activeBlockers) {
        if (!state.acknowledged && state.blockers.length > 0) {
          for (const b of state.blockers) activeBlockerIds.push(b.articleId);
        }
      }
      if (activeBlockerIds.length > 0) {
        activeBlockerIds.sort();
        blockerHash = activeBlockerIds.join(",");
      } else {
        // No active blockers → tool description stays vanilla.
        return;
      }

      // Cache key encodes "this tool + this exact blocker set." If we've already
      // emitted the notice-prefixed description for this combination once, the
      // tool description we hand back this turn is byte-identical to last turn —
      // and the LLM's tool-list prompt-cache prefix stays warm. v3.11.x had an
      // empty-if-block here that documented intent but didn't act on it.
      const cacheKey = `${id}:${blockerHash}`;
      const lastEmitted = toolDefinitionLastHashBySession.get(cacheKey);

      const notice = `[PeKG enforcement] Calls to this tool are rejected when unacknowledged PeKG blockers exist for the current session. Address each <pekg-active-blockers> entry by name in your assistant message before calling this tool. ${
        id === "bash"
          ? "For bash, redirects to workspace files (>, >>, tee), sed -i, perl -pi, awk -i inplace, " +
            "python/node file writes, and git apply/restore are gated equivalently."
          : ""
      }`;
      output.description = `${notice}\n\n${output.description ?? ""}`.trim();

      // Record AFTER mutating output. If lastEmitted matched, the description we
      // produced is identical to the prior call — record nothing new. If lastEmitted
      // differed (or was undefined), record the new hash so future calls can short-
      // circuit when the set is unchanged.
      if (lastEmitted !== blockerHash) {
        toolDefinitionLastHashBySession.set(cacheKey, blockerHash);
      }
    },

    // -----------------------------------------------------------------------
    // FLASH COMPACTION: Replace LLM summarization with pre-computed state.
    // Two-hook strategy: set prompt here, clear messages in messages.transform.
    "experimental.session.compacting": async (input, output) => {
      const sessionID = (input as HookInput)?.sessionID;

      // 1. Invalidate per-session caches so post-compaction the first user
      //    message gets a fresh full-context injection.
      if (sessionID) {
        firstMessageInjected.delete(sessionID);
        // H4 fix: drop only this session's seen-context hashes, not all sessions'.
        seenContextHashesBySession.delete(sessionID);
        // Issue 5: allow orphan warning to re-surface after compaction
        orphanWarningShownInSession.delete(sessionID);
      }

      // 2. Collect tracked state for the structured flash-compaction prompt.
      const taskState = sessionID ? sessionTaskState.get(sessionID) : undefined;
      const blockerState = sessionID ? activeBlockers.get(sessionID) : undefined;
      const projectOrigin = getProjectOrigin();

      // ALWAYS take over compaction. Earlier (v3.12.0) we conditionally fell
      // back to opencode's default summarizer when state was empty, on the
      // theory that an empty `## Project / ## Instructions` skeleton was less
      // useful than a real LLM summary. The cost was 30–120s of LLM time on
      // every "empty" session compact — that's exactly the cost flash
      // compaction was supposed to eliminate. The structured prompt with just
      // Project + Instructions still outperforms a default 15K-token
      // summarization for the user's wall-clock time, even if the recovered
      // context is lighter. Always-on > smart-fallback here.
      output.prompt = buildFlashCompactionPrompt({
        task: taskState,
        blockers: blockerState,
        projectOrigin,
      });
      compactingDepth++;
      compactingDepthSetAt = Date.now();

      // 3. Persist state for crash recovery / -c continuation.
      //    Single-writer envelope (PersistedSessionState) so the dual-shape race
      //    from v3.11.x can't reappear.
      if (sessionID) {
        persistBlockerState(sessionID);
      }

      // 4. Lazy cleanup (non-blocking, max 1x/hour). Suppress its console output
      //    via the silent flag — TUI doesn't render plugin logs cleanly.
      maybeRunCleanup();
    },

    // -----------------------------------------------------------------------
    // FLASH COMPACTION (Hook 2): Clear message history during compaction
    // This is what makes compaction "flash" — LLM only sees our prompt, not 15K tokens of history
    // -----------------------------------------------------------------------
    "experimental.chat.messages.transform": async (_input, output) => {
      // Staleness guard: if compactingDepth was set more than COMPACTING_STALE_MS
      // ago and never decremented, treat it as a leaked flag from a prior
      // compaction whose post-prompt work threw. Reset and skip this turn.
      if (compactingDepth > 0 && Date.now() - compactingDepthSetAt > COMPACTING_STALE_MS) {
        compactingDepth = 0;
        return;
      }
      if (compactingDepth === 0) return;

      // Clear the conversation history — LLM will only see our structured prompt.
      // IMPORTANT: mutate in place. Do NOT unshift/push new message objects;
      // the SDK Message type is UserMessage | AssistantMessage only, and
      // injecting any other shape crashes opencode's effect-ts runtime.
      const originalLength = output.messages.length;
      output.messages.length = 0;

      // Release our claim on the counter (one-shot per compacting call).
      compactingDepth = Math.max(0, compactingDepth - 1);
      void originalLength; // suppress unused warning
    },
  };
};
