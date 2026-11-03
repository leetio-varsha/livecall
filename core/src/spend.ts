// What a day cost, and why. Reads usage.jsonl (see usage.ts) back:
//
//   npm run spend                 every day on record, one line each
//   npm run spend -- 2026-09-02   that day's calls one by one
//
// Days are LOCAL dates, like the menu's "today". The billing console counts
// in UTC; a late-evening call lands on the next day there.
//
// The per-call view marks two things the day total hides. `cache` is what
// share of the prompt came back as cache reads — near 100% is the design,
// a low number means the prefix was written again at full price. `gap` is
// the minutes since the previous call: past five, the cache had expired
// before this call started, so a rewrite here was the TTL, not a bug.

import { readLedger, type LedgerEntry } from "./usage.ts";
import { formatCost } from "./pricing.ts";

const CACHE_TTL_MIN = 5;

const day = process.argv[2];
const entries = readLedger();
if (!entries.length) {
  console.log("no usage on record yet — the ledger starts with the next answer");
  process.exit(0);
}

const pad = (n: number) => String(n).padStart(2, "0");
const localDate = (iso: string): string => {
  const d = new Date(iso);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
};
const localTime = (iso: string): string => {
  const d = new Date(iso);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
};
const k = (n: number): string => (n >= 10_000 ? `${Math.round(n / 1000)}k` : String(n));
const cost = (c: number | null): string => (c === null ? "?" : formatCost(c));

interface Totals {
  calls: number;
  scouts: number;
  input: number;
  cacheWrite: number;
  cacheRead: number;
  output: number;
  cost: number;
  partial: boolean;
}
const empty = (): Totals => ({
  calls: 0, scouts: 0, input: 0, cacheWrite: 0, cacheRead: 0, output: 0, cost: 0, partial: false,
});
const add = (t: Totals, e: LedgerEntry): void => {
  if (e.kind === "scout") t.scouts++;
  else t.calls++;
  t.input += e.inputTokens;
  t.cacheWrite += e.cacheWriteTokens;
  t.cacheRead += e.cacheReadTokens;
  t.output += e.outputTokens;
  if (e.cost === null) t.partial = true;
  else t.cost += e.cost;
};
const row = (label: string, t: Totals): string =>
  [
    label.padEnd(10),
    `${t.calls} ans`.padStart(8),
    `${t.scouts} scout`.padStart(9),
    `in ${k(t.input)}`.padStart(9),
    `write ${k(t.cacheWrite)}`.padStart(12),
    `read ${k(t.cacheRead)}`.padStart(11),
    `out ${k(t.output)}`.padStart(10),
    `${t.partial ? "≥" : ""}${cost(t.cost)}`.padStart(9),
  ].join("  ");

if (!day) {
  const byDay = new Map<string, Totals>();
  for (const e of entries) {
    const d = localDate(e.at);
    if (!byDay.has(d)) byDay.set(d, empty());
    add(byDay.get(d)!, e);
  }
  const all = empty();
  for (const e of entries) add(all, e);
  for (const [d, t] of [...byDay.entries()].sort()) console.log(row(d, t));
  console.log(row("total", all));
  process.exit(0);
}

const picked = entries.filter((e) => localDate(e.at) === day);
if (!picked.length) {
  console.log(`nothing on ${day} — days on record: ${[...new Set(entries.map((e) => localDate(e.at)))].sort().join(", ")}`);
  process.exit(1);
}

let prevAt: number | null = null;
const t = empty();
for (const e of picked) {
  add(t, e);
  const at = new Date(e.at).getTime();
  const gapMin = prevAt === null ? null : (at - prevAt) / 60_000;
  prevAt = at;
  const prompt = e.inputTokens + e.cacheReadTokens + e.cacheWriteTokens;
  const cacheShare = prompt ? Math.round((e.cacheReadTokens / prompt) * 100) : 0;
  const gap =
    gapMin === null ? "" : gapMin > CACHE_TTL_MIN ? `gap ${Math.round(gapMin)}m (cache expired)` : `gap ${gapMin.toFixed(1)}m`;
  console.log(
    [
      localTime(e.at),
      (e.kind === "scout" ? "scout" : (e.mode ?? "answer").toUpperCase()).padEnd(6),
      e.model.padEnd(16),
      `prompt ${k(prompt)}`.padStart(13),
      `cache ${cacheShare}%`.padStart(10),
      `out ${k(e.outputTokens)}`.padStart(9),
      cost(e.cost).padStart(8),
      gap,
    ].join("  "),
  );
}
console.log(row(day, t));
