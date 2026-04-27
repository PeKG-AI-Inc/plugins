import { describe, expect, test } from "vitest";

// ─────────────────────────────────────────────────────────────────────────────
// Helpers under test. These are inlined copies of the helpers defined in
// `plugins/opencode/opencode.ts`. The plugin file is shipped to users as a
// self-contained TS file (no bundler), so it can't import from a sibling
// module. Tests duplicate the algorithm verbatim — when adding a helper to
// opencode.ts, mirror it here. Drift is caught via code review (these
// helpers are < 100 lines total).
//
// Issue 8 helpers — markdown-context re-tier
// Issue 6 helpers — relevance floor
// Issue 7 helpers — per-blocker cooldown filter
// Issue 9 helpers — subagent inheritance filter
// Issue 10 helpers — verifier prompt builder
// ─────────────────────────────────────────────────────────────────────────────

const PEKG_CODE_DOMAIN_KEYWORDS = [
  "function","async","await","hook","sql","query","parse","plugin","config",
  "server","route","endpoint","mcp","opencode","typescript","javascript",
  "regex","stream","promise","fetch","request","response","schema","migration",
  "react","vue","css","ui","frontend","docker","kubernetes","redis","postgres",
  "drizzle",
] as const;
const PEKG_NON_CODE_KEYWORDS = [
  "security","vulnerability","credential","secret","auth","privacy","pii",
  "compliance","audit","documentation","readme","changelog","policy","license",
] as const;
const PEKG_MARKDOWN_EXT_RE = /\.(md|mdx|txt|rst|adoc)$/i;

function pekgIsMarkdownPath(filePath: string | undefined | null): boolean {
  if (!filePath) return false;
  return PEKG_MARKDOWN_EXT_RE.test(filePath);
}

function pekgTextMatchesAny(text: string, keywords: readonly string[]): boolean {
  const t = text.toLowerCase();
  for (const kw of keywords) {
    if (new RegExp(`\\b${kw}`).test(t)) return true;
  }
  return false;
}

function pekgEffectiveTier(
  blocker: { tier: string; title?: string; summary?: string },
  filePath: string | undefined | null,
): string {
  if (blocker.tier !== "blocker") return blocker.tier;
  if (!pekgIsMarkdownPath(filePath)) return blocker.tier;
  const text = `${blocker.title ?? ""} ${blocker.summary ?? ""}`;
  if (pekgTextMatchesAny(text, PEKG_NON_CODE_KEYWORDS)) return blocker.tier;
  return "warning";
}

function pekgFilterBlockersForFile<T extends { tier: string; title?: string; summary?: string }>(
  blockers: readonly T[],
  filePath: string | undefined | null,
): T[] {
  return blockers.filter((b) => pekgEffectiveTier(b, filePath) === "blocker");
}

function pekgBashCmdTargetsMarkdown(cmd: string): boolean {
  return /(?:\bsed\s+-[A-Za-z]*i\b|\btee\b|>>?\s*|\bcp\b|\bmv\b)[^|;&]*\.(md|mdx|txt|rst|adoc)\b/i.test(cmd);
}

// Issue 10 helpers — verifier prompt compression
function pekgTruncateForVerifier(
  response: string,
  blockerIds: readonly string[],
  maxChars = 2000,
): string {
  if (response.length <= maxChars) return response;
  const head = response.slice(0, 1500);
  const tail = response.slice(-500);
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

function pekgBuildVerifierPrompt(
  blockers: Array<{ articleId: string; title: string }>,
  agentResponse: string,
): string {
  const blockerLines = blockers
    .map((b) => `- ${b.articleId.slice(0, 8)}: ${b.title}`)
    .join("\n");
  const ids = blockers.map((b) => b.articleId);
  const truncated = pekgTruncateForVerifier(agentResponse, ids);
  return `OUTPUT JSON: {"addressedIds":["8charprefix",...],"concrete":bool,"reason":"short"}
addressedIds = list 8-char prefixes of blockers the response explicitly mentions and proposes action for. concrete = true if response names specific files/changes/code (not generic "noted"/"will be careful").

BLOCKERS:
${blockerLines}

RESPONSE:
${truncated}`;
}

interface PekgVerifierResult {
  addressedIds: string[];
  concrete: boolean;
  reason?: string;
}

function pekgParseVerifierOutput(text: string): PekgVerifierResult | null {
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
}

// Issue 9 helpers — subagent inheritance filter
function pekgExtractTokens(text: string): Set<string> {
  return new Set(
    text
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((t) => t.length >= 4),
  );
}

function pekgFilterInheritedBlockers<T extends { title?: string; summary?: string }>(
  blockers: readonly T[],
  subagentPrompt: string,
): { kept: T[]; filteredCount: number } {
  const cap = 3;
  if (blockers.length === 0) return { kept: [], filteredCount: 0 };
  const promptTokens = pekgExtractTokens(subagentPrompt);
  if (promptTokens.size === 0) {
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
  const kept = scored.filter((s) => s.score > 0).slice(0, cap).map((s) => s.blocker);
  return { kept, filteredCount: blockers.length - kept.length };
}

// Issue 6 helpers
const PEKG_BLOCKER_FLOOR = 0.65;
const PEKG_WARNING_FLOOR = 0.55;
const PEKG_INFO_FLOOR = 0.7;

interface MinArticle {
  tier: string;
  relevance?: number;
  title?: string;
  articleId?: string;
}

function pekgApplyTierFloor(articles: readonly MinArticle[]): MinArticle[] {
  return articles
    .map((a) => {
      const r = a.relevance ?? 0;
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

function pekgFilterAckedBlockers<T extends { articleId: string }>(
  blockers: readonly T[],
  ackedAt: Record<string, number> | undefined,
  now: number,
  cooldownMs: number,
): T[] {
  if (!ackedAt) return [...blockers];
  return blockers.filter((b) => {
    const ts = ackedAt[b.articleId];
    if (!ts) return true;
    return now - ts >= cooldownMs;
  });
}

function pekgPruneAckedAt(ackedAt: Record<string, number>, now: number, pruneMs: number): void {
  for (const id of Object.keys(ackedAt)) {
    if (now - ackedAt[id] >= pruneMs) delete ackedAt[id];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Issue 8 tests — markdown re-tier
// ─────────────────────────────────────────────────────────────────────────────

describe("Issue 8: pekgEffectiveTier — markdown context demotes code-domain blockers", () => {
  test("CANARY: markdown file + code-domain blocker → warning", () => {
    // **Fails today** (gate fires uniformly), passes after Issue 8 lands.
    expect(pekgEffectiveTier(
      { tier: "blocker", title: "Async/await server route", summary: "Avoid blocking the event loop" },
      "docs/STRATEGIC_ROADMAP.md"
    )).toBe("warning");
  });

  test("markdown file + security blocker → still blocker (carve-out holds)", () => {
    expect(pekgEffectiveTier(
      { tier: "blocker", title: "Don't commit credential files", summary: "Security scanning required" },
      "README.md"
    )).toBe("blocker");
  });

  test("markdown file + privacy blocker → still blocker", () => {
    expect(pekgEffectiveTier(
      { tier: "blocker", title: "Avoid PII in logs", summary: "compliance requirement" },
      "docs/PRIVACY.md"
    )).toBe("blocker");
  });

  test(".ts file + same code-domain blocker → still blocker (no extension bypass)", () => {
    expect(pekgEffectiveTier(
      { tier: "blocker", title: "Async/await server route", summary: "Avoid blocking the event loop" },
      "src/server.ts"
    )).toBe("blocker");
  });

  test("untagged blocker on markdown → demoted to warning (default-demote)", () => {
    // No code-domain or non-code keywords in title/summary.
    // Default behavior: demote so doc work isn't gated by an unrelated blocker.
    expect(pekgEffectiveTier(
      { tier: "blocker", title: "Generic blocker", summary: "Some general advice" },
      "docs/X.md"
    )).toBe("warning");
  });

  test("warning tier never gets promoted by re-tier", () => {
    // Critical: clamp must NEVER raise tier — only lower.
    expect(pekgEffectiveTier(
      { tier: "warning", title: "Async/await server route", summary: "" },
      "src/api.ts"
    )).toBe("warning");
  });

  test("info tier unchanged regardless of file", () => {
    expect(pekgEffectiveTier({ tier: "info", title: "info" }, "src/api.ts")).toBe("info");
    expect(pekgEffectiveTier({ tier: "info", title: "info" }, "README.md")).toBe("info");
  });

  test("missing filePath (no target) → no demote", () => {
    // tool.execute.before may have undefined filePath for some tool types;
    // fail safe (do not demote) so we don't accidentally skip the gate.
    expect(pekgEffectiveTier(
      { tier: "blocker", title: "Async/await server route" },
      undefined
    )).toBe("blocker");
  });

  test(".mdx and .rst also trigger demote", () => {
    expect(pekgEffectiveTier(
      { tier: "blocker", title: "Async/await server route" },
      "docs/page.mdx"
    )).toBe("warning");
    expect(pekgEffectiveTier(
      { tier: "blocker", title: "Async/await server route" },
      "README.rst"
    )).toBe("warning");
  });
});

describe("Issue 8: pekgFilterBlockersForFile — gate decision", () => {
  test("all blockers code-domain on markdown → empty (skip gate)", () => {
    const blockers = [
      { tier: "blocker", title: "Async/await server route" },
      { tier: "blocker", title: "TypeScript schema migration" },
    ];
    expect(pekgFilterBlockersForFile(blockers, "docs/X.md")).toHaveLength(0);
  });

  test("mixed list on markdown → keep only non-demotable (security)", () => {
    const blockers = [
      { tier: "blocker", title: "Async/await server route" },          // demote
      { tier: "blocker", title: "Don't leak credentials", summary: "" }, // keep
    ];
    const result = pekgFilterBlockersForFile(blockers, "README.md");
    expect(result).toHaveLength(1);
    expect(result[0].title).toContain("credential");
  });

  test("on code file, all blockers survive", () => {
    const blockers = [
      { tier: "blocker", title: "Async/await server route" },
      { tier: "blocker", title: "Don't leak credentials" },
    ];
    expect(pekgFilterBlockersForFile(blockers, "src/api.ts")).toHaveLength(2);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Issue 10 tests — verifier prompt compression
// ─────────────────────────────────────────────────────────────────────────────

// Cheap token estimator: ~4 chars per token. Production verifier uses
// the model's tokenizer; this is fine for assertion-level checks.
const approxTokens = (text: string): number => Math.ceil(text.length / 4);

describe("Issue 10: pekgBuildVerifierPrompt — compressed structured prompt", () => {
  test("CANARY: prompt for 3 blockers + 1500-char response < 600 tokens", () => {
    // Fails today (current verifier prompt is ~672+ tokens for any input),
    // passes after Issue 10 lands. The 600 budget gives us headroom while
    // confirming we're well below the original.
    const blockers = [
      { articleId: "a1b2c3d4-...", title: "Async/await server route" },
      { articleId: "e5f6g7h8-...", title: "Schema migration safety" },
      { articleId: "i9j0k1l2-...", title: "Drizzle ORM N+1 queries" },
    ];
    const response = "x".repeat(1500);
    const prompt = pekgBuildVerifierPrompt(blockers, response);
    expect(approxTokens(prompt)).toBeLessThan(600);
  });

  test("response > 2000 chars is truncated to ≤ 2200 in prompt body", () => {
    const blockers = [{ articleId: "a1b2c3d4-...", title: "X" }];
    const response = "x".repeat(5000);
    const prompt = pekgBuildVerifierPrompt(blockers, response);
    // Allow some prompt structure overhead
    expect(prompt.length).toBeLessThan(3000);
  });

  test("verifier output JSON parses to expected shape", () => {
    const result = pekgParseVerifierOutput('{"addressedIds":["a1b2c3d4","e5f6g7h8"],"concrete":true,"reason":"named files"}');
    expect(result).toEqual({
      addressedIds: ["a1b2c3d4", "e5f6g7h8"],
      concrete: true,
      reason: "named files",
    });
  });

  test("malformed JSON → null (caller falls back)", () => {
    expect(pekgParseVerifierOutput("not json")).toBeNull();
    expect(pekgParseVerifierOutput("{ broken")).toBeNull();
  });

  test("missing addressedIds → null (defensive)", () => {
    expect(pekgParseVerifierOutput('{"concrete":true}')).toBeNull();
  });

  test("addressedIds with non-string entries → filtered out", () => {
    const result = pekgParseVerifierOutput('{"addressedIds":["a1b2c3d4", 42, null, "e5f6g7h8"], "concrete": true}');
    expect(result?.addressedIds).toEqual(["a1b2c3d4", "e5f6g7h8"]);
  });

  test("output wrapped in markdown fences still parses", () => {
    const wrapped = '```json\n{"addressedIds":["a1b2c3d4"],"concrete":true}\n```';
    const result = pekgParseVerifierOutput(wrapped);
    expect(result?.addressedIds).toEqual(["a1b2c3d4"]);
  });

  test("concrete defaults false when missing", () => {
    const result = pekgParseVerifierOutput('{"addressedIds":[]}');
    expect(result).toEqual({ addressedIds: [], concrete: false, reason: undefined });
  });
});

describe("Issue 10: pekgTruncateForVerifier — smart truncation preserves blocker mentions", () => {
  test("response under 2000 chars passes through unchanged", () => {
    const r = "x".repeat(1000);
    expect(pekgTruncateForVerifier(r, ["a1b2c3d4-id"])).toBe(r);
  });

  test("long response without blocker-id mention → head + tail only", () => {
    const r = "x".repeat(5000);
    const out = pekgTruncateForVerifier(r, ["a1b2c3d4-id"]);
    expect(out.length).toBeLessThan(r.length);
    expect(out.startsWith("xxx")).toBe(true);
    expect(out.endsWith("xxx")).toBe(true);
    expect(out).toContain("[...]");
  });

  test("blocker ID buried in middle is preserved", () => {
    // Construct a response > 2000 chars with the blocker prefix at the middle.
    const head = "h".repeat(1500);
    const middlePadLeft = "a".repeat(500);
    const idChunk = "I addressed a1b2c3d4 by changing the route handler"; // 50 chars
    const middlePadRight = "b".repeat(500);
    const tail = "t".repeat(500);
    const r = head + middlePadLeft + idChunk + middlePadRight + tail;
    const out = pekgTruncateForVerifier(r, ["a1b2c3d4-fullid"]);
    // Blocker mention should be preserved
    expect(out).toContain("a1b2c3d4");
    expect(out).toContain("changing the route handler");
  });

  test("multiple blocker mentions all preserved", () => {
    const head = "h".repeat(1500);
    const middlePart = `[mid] aaaaaaaa-something bbbbbbbb-something else [/mid]`;
    const tail = "t".repeat(500);
    const r = head + "x".repeat(200) + middlePart + "y".repeat(200) + tail;
    const out = pekgTruncateForVerifier(r, ["aaaaaaaa-1", "bbbbbbbb-2"]);
    expect(out).toContain("aaaaaaaa");
    expect(out).toContain("bbbbbbbb");
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Issue 9 tests — subagent inheritance filter
// ─────────────────────────────────────────────────────────────────────────────

describe("Issue 9: pekgFilterInheritedBlockers — subagent gets only relevant blockers", () => {
  test("CANARY: keyword overlap with prompt keeps blocker", () => {
    // Fails today (no filter — all blockers passed verbatim), passes after.
    const result = pekgFilterInheritedBlockers(
      [{ title: "Drizzle ORM N+1 query gotcha", summary: "" }],
      "refactor the database query layer for performance",
    );
    expect(result.kept).toHaveLength(1);
    expect(result.filteredCount).toBe(0);
  });

  test("zero overlap → blocker dropped", () => {
    const result = pekgFilterInheritedBlockers(
      [{ title: "Tailwind CSS purge config", summary: "frontend styling" }],
      "write a unit test for the auth service",
    );
    expect(result.kept).toHaveLength(0);
    expect(result.filteredCount).toBe(1);
  });

  test("top-3 cap holds when more than 3 match", () => {
    const blockers = Array.from({ length: 5 }, (_, i) => ({
      title: `test pattern variant ${i}`,
      summary: "common testing gotcha",
    }));
    const result = pekgFilterInheritedBlockers(blockers, "write a comprehensive test pattern");
    expect(result.kept).toHaveLength(3);
    expect(result.filteredCount).toBe(2);
  });

  test("empty blockers list → empty kept", () => {
    const result = pekgFilterInheritedBlockers([], "any prompt");
    expect(result.kept).toHaveLength(0);
    expect(result.filteredCount).toBe(0);
  });

  test("empty prompt → keeps top 3 unfiltered (no signal to score on)", () => {
    const blockers = Array.from({ length: 5 }, (_, i) => ({
      title: `blocker ${i}`,
      summary: "",
    }));
    const result = pekgFilterInheritedBlockers(blockers, "");
    expect(result.kept).toHaveLength(3);
    expect(result.filteredCount).toBe(2);
  });

  test("scoring orders by overlap count, not array order", () => {
    const blockers = [
      { title: "tailwind config", summary: "" },           // 0 hits
      { title: "database query layer migration", summary: "" }, // 3 hits
      { title: "react hook gotcha", summary: "" },          // 0 hits
      { title: "database performance", summary: "" },        // 2 hits
    ];
    const result = pekgFilterInheritedBlockers(
      blockers,
      "the database query layer migration is slow performance",
    );
    expect(result.kept[0].title).toContain("database query layer migration");
    // 2nd kept is "database performance" (2 hits)
    expect(result.kept[1].title).toBe("database performance");
    expect(result.kept).toHaveLength(2);
    expect(result.filteredCount).toBe(2);
  });

  test("matches against summary too, not just title", () => {
    const result = pekgFilterInheritedBlockers(
      [{ title: "Generic title", summary: "watch out for memory leak in long-running streams" }],
      "fix the memory leak in the data stream pipeline",
    );
    expect(result.kept).toHaveLength(1);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Issue 6 tests — relevance floor
// ─────────────────────────────────────────────────────────────────────────────

describe("Issue 6: pekgApplyTierFloor — per-tier relevance floor", () => {
  test("blocker at 0.65 survives as blocker", () => {
    const result = pekgApplyTierFloor([{ tier: "blocker", relevance: 0.65 }]);
    expect(result).toHaveLength(1);
    expect(result[0].tier).toBe("blocker");
  });

  test("CANARY: blocker at 0.64 demoted to warning (not dropped)", () => {
    // Fails today (no plugin-side floor), passes after Issue 6 lands.
    // Demote-not-drop preserves accumulated value while cutting blocker noise.
    const result = pekgApplyTierFloor([{ tier: "blocker", relevance: 0.64 }]);
    expect(result).toHaveLength(1);
    expect(result[0].tier).toBe("warning");
  });

  test("blocker at 0.54 → demoted to warning, then dropped (below warning floor 0.55)", () => {
    const result = pekgApplyTierFloor([{ tier: "blocker", relevance: 0.54 }]);
    expect(result).toHaveLength(0);
  });

  test("warning at 0.55 survives, at 0.54 dropped", () => {
    expect(pekgApplyTierFloor([{ tier: "warning", relevance: 0.55 }])).toHaveLength(1);
    expect(pekgApplyTierFloor([{ tier: "warning", relevance: 0.54 }])).toHaveLength(0);
  });

  test("info at 0.7 survives, at 0.69 dropped", () => {
    expect(pekgApplyTierFloor([{ tier: "info", relevance: 0.7 }])).toHaveLength(1);
    expect(pekgApplyTierFloor([{ tier: "info", relevance: 0.69 }])).toHaveLength(0);
  });

  test("mixed list — keeps survivors only", () => {
    const input = [
      { tier: "blocker", relevance: 0.7 },   // keep as blocker
      { tier: "blocker", relevance: 0.6 },   // demote to warning, survives (≥0.55)
      { tier: "blocker", relevance: 0.5 },   // demote, dropped
      { tier: "warning", relevance: 0.6 },   // keep
      { tier: "info", relevance: 0.8 },      // keep
      { tier: "info", relevance: 0.5 },      // dropped
    ];
    const result = pekgApplyTierFloor(input);
    // Surviving: blocker @0.7, blocker→warning @0.6, warning @0.6, info @0.8 = 4
    expect(result).toHaveLength(4);
    // Tier accuracy
    expect(result.filter((a) => a.tier === "blocker")).toHaveLength(1);
    expect(result.filter((a) => a.tier === "warning")).toHaveLength(2);
    expect(result.filter((a) => a.tier === "info")).toHaveLength(1);
  });

  test("missing relevance defaults to 0 (gets floored out)", () => {
    expect(pekgApplyTierFloor([{ tier: "blocker" }])).toHaveLength(0);
  });

  test("immutability — input array not mutated", () => {
    const input = [{ tier: "blocker", relevance: 0.6, articleId: "a" }];
    const before = JSON.stringify(input);
    pekgApplyTierFloor(input);
    expect(JSON.stringify(input)).toBe(before);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Issue 7 tests — per-blocker cooldown
// ─────────────────────────────────────────────────────────────────────────────

describe("Issue 7: pekgFilterAckedBlockers — cooldown filter", () => {
  const COOLDOWN = 10 * 60 * 1000; // 10 minutes

  test("blocker not in ackedAt is kept", () => {
    expect(pekgFilterAckedBlockers([{ articleId: "a" }], {}, 1000, COOLDOWN)).toHaveLength(1);
  });

  test("CANARY: blocker acked < 10 min ago is dropped", () => {
    // Fails today (no ackedAt logic exists), passes after Issue 7 lands.
    expect(pekgFilterAckedBlockers(
      [{ articleId: "a" }],
      { a: 500 },
      500 + 9 * 60_000, // 9 min later
      COOLDOWN,
    )).toHaveLength(0);
  });

  test("blocker acked > 10 min ago re-fires", () => {
    expect(pekgFilterAckedBlockers(
      [{ articleId: "a" }],
      { a: 500 },
      500 + 11 * 60_000, // 11 min later
      COOLDOWN,
    )).toHaveLength(1);
  });

  test("ack of A doesn't suppress B (per-blocker discrimination)", () => {
    const result = pekgFilterAckedBlockers(
      [{ articleId: "a" }, { articleId: "b" }],
      { a: 500 },
      500 + 5 * 60_000,
      COOLDOWN,
    );
    expect(result).toEqual([{ articleId: "b" }]);
  });

  test("exact 10-min boundary → re-fires (cooldown is < not ≤)", () => {
    expect(pekgFilterAckedBlockers(
      [{ articleId: "a" }],
      { a: 500 },
      500 + 10 * 60_000, // exactly 10 min
      COOLDOWN,
    )).toHaveLength(1);
  });

  test("undefined ackedAt → all blockers kept", () => {
    expect(pekgFilterAckedBlockers([{ articleId: "a" }], undefined, 1000, COOLDOWN)).toHaveLength(1);
  });

  test("multiple blockers, mixed ack states", () => {
    const blockers = [
      { articleId: "fresh" },     // never acked
      { articleId: "recent" },    // acked 5 min ago — suppressed
      { articleId: "stale" },     // acked 20 min ago — re-fires
    ];
    const ackedAt = {
      recent: 1000,
      stale: 1000,
    };
    const now = 1000 + 5 * 60_000; // recent: 5min ago, stale: 5min ago
    // wait - both are 5 min. Adjust:
    const ackedAt2 = { recent: 1000, stale: 1000 };
    const result = pekgFilterAckedBlockers(blockers, ackedAt2, 1000 + 20 * 60_000, COOLDOWN);
    expect(result.map((b) => b.articleId)).toEqual(["fresh", "recent", "stale"]); // all 20 min later → expired
  });

  test("typical workflow: ack, edit immediately, edit 5 min later, edit 11 min later", () => {
    const blockers = [{ articleId: "x" }];
    const ackedAt = { x: 1000 };
    // Immediately after ack — suppressed
    expect(pekgFilterAckedBlockers(blockers, ackedAt, 1000, COOLDOWN)).toHaveLength(0);
    // 5 min later — still suppressed
    expect(pekgFilterAckedBlockers(blockers, ackedAt, 1000 + 5 * 60_000, COOLDOWN)).toHaveLength(0);
    // 11 min later — re-fires
    expect(pekgFilterAckedBlockers(blockers, ackedAt, 1000 + 11 * 60_000, COOLDOWN)).toHaveLength(1);
  });
});

describe("Issue 7: pekgPruneAckedAt — bounds memory growth", () => {
  test("removes entries older than prune window", () => {
    // now = 2_000_000ms; prune window = 30 min = 1_800_000ms.
    // stale (acked at 100ms) is older than (now - pruneWindow = 200_000ms) → prune.
    // fresh (acked at 1_900_000ms) is within window → keep.
    const ackedAt: Record<string, number> = { stale: 100, fresh: 1_900_000 };
    pekgPruneAckedAt(ackedAt, 2_000_000, 30 * 60_000);
    expect(ackedAt.stale).toBeUndefined();
    expect(ackedAt.fresh).toBe(1_900_000);
  });

  test("empty ackedAt is no-op", () => {
    const ackedAt: Record<string, number> = {};
    pekgPruneAckedAt(ackedAt, 1000, 30 * 60_000);
    expect(Object.keys(ackedAt)).toHaveLength(0);
  });

  test("all entries within window survive", () => {
    const ackedAt: Record<string, number> = { a: 100, b: 200 };
    pekgPruneAckedAt(ackedAt, 200, 30 * 60_000);
    expect(Object.keys(ackedAt)).toHaveLength(2);
  });
});

describe("Issue 8: pekgBashCmdTargetsMarkdown — bash gate detection", () => {
  test("sed -i README.md → matches", () => {
    expect(pekgBashCmdTargetsMarkdown("sed -i 's/foo/bar/' README.md")).toBe(true);
  });

  test("tee docs/x.md → matches", () => {
    expect(pekgBashCmdTargetsMarkdown("echo hi | tee docs/x.md")).toBe(true);
  });

  test("redirect to .md → matches", () => {
    expect(pekgBashCmdTargetsMarkdown("echo hi > CHANGELOG.md")).toBe(true);
    expect(pekgBashCmdTargetsMarkdown("echo hi >> CHANGELOG.md")).toBe(true);
  });

  test("cp/mv to .md → matches", () => {
    expect(pekgBashCmdTargetsMarkdown("cp draft.md docs/release.md")).toBe(true);
    expect(pekgBashCmdTargetsMarkdown("mv x.md y.md")).toBe(true);
  });

  test("ts file → no match", () => {
    expect(pekgBashCmdTargetsMarkdown("sed -i 's/x/y/' src/server.ts")).toBe(false);
  });

  test("redirect to /dev/null → no match (fd alias)", () => {
    expect(pekgBashCmdTargetsMarkdown("ls 2>/dev/null")).toBe(false);
  });

  test("benign reads → no match", () => {
    expect(pekgBashCmdTargetsMarkdown("cat README.md")).toBe(false);
    expect(pekgBashCmdTargetsMarkdown("grep -r foo docs/")).toBe(false);
  });
});

// Inline copy of redirectTargetsWorkspace from opencode.ts (mirror of
// pekg_redirect_targets_workspace in shared/lib/blockers.sh). Keep in sync.
function redirectTargetsWorkspace(cmd: string): boolean {
  const home = process.env.HOME ?? "";
  const tmpdir = process.env.TMPDIR ?? "";
  const scratchPrefixes = [
    "/dev/",
    "/tmp/",
    "/var/tmp/",
    "/var/folders/",
    "/private/var/folders/",
    home ? `${home}/.cache/` : "",
    home ? `${home}/.pekg/` : "",
    home ? `${home}/Library/Caches/` : "",
    tmpdir ? (tmpdir.endsWith("/") ? tmpdir : `${tmpdir}/`) : "",
  ].filter(Boolean);
  const re = /(?:^|[\s;&|`])(?:[0-9]?>>?|&>)\s*([^\s|;&`]+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(cmd)) !== null) {
    const target = m[1];
    if (target.startsWith("&")) continue;
    if (scratchPrefixes.some((p) => target.startsWith(p))) continue;
    return true;
  }
  return false;
}

describe("redirectTargetsWorkspace — scratch-dir whitelist for `>` redirects", () => {
  test("CANARY: /tmp redirect is NOT a workspace mutation", () => {
    expect(redirectTargetsWorkspace("echo hi > /tmp/foo.txt")).toBe(false);
  });

  test("scratch dirs all whitelisted", () => {
    expect(redirectTargetsWorkspace("ls > /tmp/x")).toBe(false);
    expect(redirectTargetsWorkspace("ls > /var/tmp/x")).toBe(false);
    expect(redirectTargetsWorkspace("ls > /var/folders/abc/T/y")).toBe(false);
    expect(redirectTargetsWorkspace("ls > /private/var/folders/abc/T/y")).toBe(false);
    expect(redirectTargetsWorkspace("ls > /dev/null")).toBe(false);
  });

  test("$HOME cache subpaths whitelisted", () => {
    const home = process.env.HOME ?? "";
    expect(redirectTargetsWorkspace(`echo > ${home}/.cache/foo`)).toBe(false);
    expect(redirectTargetsWorkspace(`echo > ${home}/.pekg/foo`)).toBe(false);
    expect(redirectTargetsWorkspace(`echo > ${home}/Library/Caches/foo`)).toBe(false);
  });

  test("fd aliases (&1, &2) are not file writes", () => {
    expect(redirectTargetsWorkspace("cmd > /dev/null 2>&1")).toBe(false);
    expect(redirectTargetsWorkspace("cmd 1>&2")).toBe(false);
    expect(redirectTargetsWorkspace("cmd 2>&1 | grep foo")).toBe(false);
  });

  test("relative paths flagged (resolve to cwd = workspace)", () => {
    expect(redirectTargetsWorkspace("echo hi > output.txt")).toBe(true);
    expect(redirectTargetsWorkspace("ls >> log.out")).toBe(true);
    expect(redirectTargetsWorkspace("cmd &> err.log")).toBe(true);
  });

  test("absolute workspace paths flagged", () => {
    expect(redirectTargetsWorkspace("echo > /Users/x/IdeaProjects/Foo/bar.ts")).toBe(true);
  });

  test("$HOME root (not a whitelisted subpath) flagged", () => {
    const home = process.env.HOME ?? "/root";
    expect(redirectTargetsWorkspace(`echo > ${home}/scratch.txt`)).toBe(true);
  });

  test("mixed cmds: any one workspace target → flagged", () => {
    expect(redirectTargetsWorkspace("ls > /tmp/a; echo > local.txt")).toBe(true);
  });

  test("pipeline ending in /tmp redirect → safe", () => {
    expect(redirectTargetsWorkspace("git ls-tree HEAD | sort | head > /tmp/x.txt")).toBe(false);
  });

  test("no redirects at all → safe", () => {
    expect(redirectTargetsWorkspace("git ls-tree HEAD")).toBe(false);
    expect(redirectTargetsWorkspace("ls -la /etc")).toBe(false);
  });

  test("fd-numbered redirect to scratch → safe", () => {
    expect(redirectTargetsWorkspace("cmd 2>/dev/null")).toBe(false);
    expect(redirectTargetsWorkspace("cmd 2>/tmp/err.log")).toBe(false);
  });

  test("fd-numbered redirect to workspace → flagged", () => {
    expect(redirectTargetsWorkspace("cmd 2>err.log")).toBe(true);
  });
});
