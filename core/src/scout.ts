// The context scout: mid-call, a small model watches the transcript and picks
// files off the project's SHELF — the files [Me] deliberately did not brief —
// when a topic they likely answer comes up. The engine owns the timer, the
// API call and the file reads; everything decidable without I/O lives here,
// where npm test can reach it.

/**
 * One tick's question to the picker model. It sees names only — the whole
 * point of the shelf is that the contents are NOT in any prompt yet.
 */
export function buildScoutPrompt(
  transcriptDelta: string,
  shelfNames: string[],
  alreadyPulled: string[],
): string {
  const pulled = alreadyPulled.length
    ? `\nAlready loaded earlier (never name these again): ${alreadyPulled.join(", ")}`
    : "";
  return (
    `You are a background file scout for a live-call assistant. Below is what ` +
    `was JUST SAID on the call, and the files that are available but not ` +
    `loaded into the assistant's context.\n\n` +
    `JUST SAID:\n${transcriptDelta}\n\n` +
    `AVAILABLE FILES:\n${shelfNames.map((n) => `- ${n}`).join("\n")}${pulled}\n\n` +
    `Name ONLY files whose content likely answers a topic just raised in the ` +
    `speech above. You cannot see the contents — judge by the name alone. On ` +
    `most ticks nothing fits: an empty list is the normal answer. Never ` +
    `invent a name that is not on the list.\n\n` +
    `Reply with STRICT JSON and nothing else: {"files": ["name.md"]} or {"files": []}`
  );
}

/**
 * Extract the picked names from the model's reply. The prompt demands bare
 * JSON, but a small model under a token cap still wraps it in prose or fences
 * often enough that trusting the format would waste real ticks. Anything
 * unparseable, and any name not actually on the shelf, reads as "picked
 * nothing" — the scout has no error path by design.
 */
export function parseScoutReply(text: string, shelfNames: string[]): string[] {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start === -1 || end <= start) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(text.slice(start, end + 1));
  } catch {
    return [];
  }
  const files = (parsed as { files?: unknown }).files;
  if (!Array.isArray(files)) return [];
  const shelf = new Set(shelfNames);
  return [...new Set(files.filter((f): f is string => typeof f === "string" && shelf.has(f)))];
}

/**
 * Bookkeeping for what the scout may still inject this call. Two limits,
 * because they fail differently: the char budget keeps the prompt from
 * growing without bound, and the gap keeps injections from rewriting the
 * cached prompt prefix back-to-back — every rewrite re-bills the prefix at
 * 1.25x on the next press. Timestamps are passed in, never read here, so the
 * throttling is testable without waiting two minutes.
 */
export class ScoutLedger {
  // Plain fields, not constructor parameter properties: Node runs this
  // project in strip-only mode, where `constructor(private x)` is a syntax
  // error.
  private maxChars: number;
  private minGapMs: number;
  private usedChars = 0;
  /** 0 = never injected this call. */
  private lastInjectionAt = 0;

  constructor(maxChars: number, minGapMs: number) {
    this.maxChars = maxChars;
    this.minGapMs = minGapMs;
  }

  canInject(now: number): boolean {
    return this.lastInjectionAt === 0 || now - this.lastInjectionAt >= this.minGapMs;
  }

  recordInjection(now: number, chars: number): void {
    this.lastInjectionAt = now;
    this.usedChars += chars;
  }

  remainingChars(): number {
    return Math.max(0, this.maxChars - this.usedChars);
  }

  reset(): void {
    this.usedChars = 0;
    this.lastInjectionAt = 0;
  }
}
