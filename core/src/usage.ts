// Running spend, persisted so "today" survives restarts (the app gets
// relaunched a lot; a counter that resets with the process is useless).
//
// Two files, kept outside the repo in Application Support (machine state, not
// project source — it must never end up in a diff):
//
//   usage.json   the day's totals, what the menu shows
//   usage.jsonl  one line per API call, forever
//
// The ledger exists because the day total answers "how much" and nothing
// else. When a $10 day shows up on the bill two weeks later, the questions
// are which call, which model, and whether the prompt was read from cache or
// written to it again — and by then usage.json has been overwritten thirteen
// times. `npm run spend` reads the ledger back.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { price, formatCost, type Priced, type TokenUsage } from "./pricing.ts";

const DEFAULT_DIR = path.join(os.homedir(), "Library/Application Support/Livecall");

/** What kind of call a ledger line is: an answer [Me] asked for, or a scout
 * tick that ran on its own. The bill does not care; the reader does. */
export type UsageKind = "answer" | "scout";

/** One line of usage.jsonl. Token counts are as the API reported them;
 * `cost` is our own pricing of them, null when the model has no known rate. */
export interface LedgerEntry extends Priced {
  /** ISO timestamp, UTC — the same clock the billing console uses. */
  at: string;
  kind: UsageKind;
  /** "fast" | "deep" for answers; absent for scout ticks. */
  mode?: string;
}

interface DayTotals {
  date: string; // YYYY-MM-DD, local time
  calls: number;
  inputTokens: number;
  outputTokens: number;
  cost: number;
  /** True when at least one call had no known rate — the total is a floor. */
  partial: boolean;
}

export interface UsageSummary {
  /** The most recent single answer. */
  last: Priced | null;
  lastCost: number | null;
  today: DayTotals;
  /** Ready-to-render: "$0.0412 · today $1.87 (23 calls)". */
  line: string;
}

function today(now: Date): string {
  // Local date, not UTC: "today" should mean the user's day.
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

function emptyDay(date: string): DayTotals {
  return { date, calls: 0, inputTokens: 0, outputTokens: 0, cost: 0, partial: false };
}

export class UsageTracker {
  private day: DayTotals;
  private last: Priced | null = null;
  // Plain field, not a constructor parameter property: Node runs this project
  // in strip-only mode, where `constructor(private x)` is a syntax error.
  private now: () => Date;
  private store: string;
  private ledger: string;

  constructor(now: () => Date = () => new Date(), dir: string = DEFAULT_DIR) {
    this.now = now;
    this.store = path.join(dir, "usage.json");
    this.ledger = path.join(dir, "usage.jsonl");
    this.day = this.load();
  }

  /** Record one call. Never throws — a broken counter must not kill a call. */
  record(usage: TokenUsage, kind: UsageKind = "answer", mode?: string): Priced {
    const priced = price(usage);
    this.last = priced;
    this.append({ ...priced, at: this.now().toISOString(), kind, ...(mode ? { mode } : {}) });

    const date = today(this.now());
    if (this.day.date !== date) this.day = emptyDay(date);
    this.day.calls++;
    this.day.inputTokens += usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens;
    this.day.outputTokens += usage.outputTokens;
    if (priced.cost === null) this.day.partial = true;
    else this.day.cost += priced.cost;

    this.save();
    return priced;
  }

  summary(): UsageSummary {
    const date = today(this.now());
    const day = this.day.date === date ? this.day : emptyDay(date);
    const lastCost = this.last?.cost ?? null;

    const parts: string[] = [];
    if (this.last) {
      parts.push(
        lastCost === null
          ? `${this.last.outputTokens} tok out (no rate for ${this.last.model})`
          : formatCost(lastCost),
      );
    }
    parts.push(
      `today ${this.day.partial ? "≥" : ""}${formatCost(day.cost)} (${day.calls} ${
        day.calls === 1 ? "call" : "calls"
      })`,
    );
    return { last: this.last, lastCost, today: day, line: parts.join(" · ") };
  }

  private load(): DayTotals {
    const date = today(this.now());
    try {
      const raw = JSON.parse(fs.readFileSync(this.store, "utf8")) as DayTotals;
      if (raw && typeof raw.date === "string" && raw.date === date) {
        return {
          date,
          calls: Number(raw.calls) || 0,
          inputTokens: Number(raw.inputTokens) || 0,
          outputTokens: Number(raw.outputTokens) || 0,
          cost: Number(raw.cost) || 0,
          partial: !!raw.partial,
        };
      }
    } catch {
      // no store yet, or it's corrupt — either way, start the day fresh
    }
    return emptyDay(date);
  }

  private save(): void {
    try {
      fs.mkdirSync(path.dirname(this.store), { recursive: true });
      fs.writeFileSync(this.store, JSON.stringify(this.day));
    } catch (e) {
      console.error(`usage store write failed: ${(e as Error).message}`);
    }
  }

  /** Append-only: a line per call, never rewritten, never rotated — a year of
   * heavy use is a few megabytes. */
  private append(entry: LedgerEntry): void {
    try {
      fs.mkdirSync(path.dirname(this.ledger), { recursive: true });
      fs.appendFileSync(this.ledger, JSON.stringify(entry) + "\n");
    } catch (e) {
      console.error(`usage ledger write failed: ${(e as Error).message}`);
    }
  }
}

/** Read the ledger back. Lines that fail to parse are skipped, not fatal — a
 * crash mid-append leaves a torn last line and must not hide the rest. */
export function readLedger(dir: string = DEFAULT_DIR): LedgerEntry[] {
  let raw: string;
  try {
    raw = fs.readFileSync(path.join(dir, "usage.jsonl"), "utf8");
  } catch {
    return [];
  }
  const out: LedgerEntry[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      const e = JSON.parse(line) as LedgerEntry;
      if (typeof e.at === "string" && typeof e.model === "string") out.push(e);
    } catch {
      // torn or foreign line — skip
    }
  }
  return out;
}
