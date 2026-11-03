// What an answer cost. There is no "remaining balance" endpoint on either
// provider — no API returns how much credit is left on a key — so the only
// honest number we can show is what WE actually spent: real token counts from
// the API responses, multiplied by the published per-model rates.
//
// Rates are USD per 1M tokens, Anthropic first-party list prices. Cache reads
// bill at 0.1x input; cache writes at 1.25x for the 5-minute TTL and 2x for
// the 1-hour one (the API reports the split in usage.cache_creation).
// Override or extend from .env with PRICE_<MODEL>_IN / _OUT (dollars per 1M).

export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  /** All cache writes, whichever TTL. */
  cacheWriteTokens: number;
  /** The part of cacheWriteTokens written with the 1-hour TTL (2x price). */
  cacheWrite1hTokens?: number;
  model: string;
  /** "anthropic" | "openai" | "claude-cli" */
  provider: string;
}

export interface Priced extends TokenUsage {
  /** USD, or null when we have no authoritative rate for this model. */
  cost: number | null;
}

const CACHE_READ_MULTIPLIER = 0.1;
const CACHE_WRITE_5M_MULTIPLIER = 1.25;
const CACHE_WRITE_1H_MULTIPLIER = 2;

/** USD per 1M tokens, [input, output]. */
const RATES: Record<string, [number, number]> = {
  "claude-opus-5": [5, 25],
  "claude-opus-4-8": [5, 25],
  "claude-opus-4-7": [5, 25],
  "claude-opus-4-6": [5, 25],
  "claude-sonnet-5": [3, 15],
  "claude-sonnet-4-6": [3, 15],
  "claude-haiku-4-5": [1, 5],
  "claude-fable-5": [10, 50],
};

/**
 * Rate for a model, or null if we don't know it. Deliberately returns null
 * rather than guessing: a made-up number on a spend readout is worse than an
 * honest "tokens only". OpenAI models land here unless priced from .env —
 * add `PRICE_GPT_5_1_IN` / `_OUT` to include them.
 */
function rate(model: string, env: NodeJS.ProcessEnv): [number, number] | null {
  const key = model.toUpperCase().replaceAll(/[.\-]/g, "_");
  const from = Number(env[`PRICE_${key}_IN`]);
  const to = Number(env[`PRICE_${key}_OUT`]);
  if (Number.isFinite(from) && Number.isFinite(to) && from >= 0 && to >= 0) {
    return [from, to];
  }
  return RATES[model] ?? null;
}

export function price(usage: TokenUsage, env: NodeJS.ProcessEnv = process.env): Priced {
  // The local CLI runs on a Claude Code subscription — no metered API charge.
  if (usage.provider === "claude-cli") return { ...usage, cost: 0 };

  const r = rate(usage.model, env);
  if (!r) return { ...usage, cost: null };

  const [inPer1M, outPer1M] = r;
  const write1h = Math.min(usage.cacheWrite1hTokens ?? 0, usage.cacheWriteTokens);
  const write5m = usage.cacheWriteTokens - write1h;
  const billableInput =
    usage.inputTokens +
    usage.cacheReadTokens * CACHE_READ_MULTIPLIER +
    write5m * CACHE_WRITE_5M_MULTIPLIER +
    write1h * CACHE_WRITE_1H_MULTIPLIER;
  const cost = (billableInput * inPer1M + usage.outputTokens * outPer1M) / 1_000_000;
  return { ...usage, cost };
}

/** "$0.0412" / "$0.11" — small amounts need the extra digits to be readable. */
export function formatCost(usd: number): string {
  if (usd === 0) return "$0";
  if (usd < 0.01) return `$${usd.toFixed(4)}`;
  if (usd < 1) return `$${usd.toFixed(3)}`;
  return `$${usd.toFixed(2)}`;
}

/** Rate-limit headroom, read from the response headers of the last call. */
export interface RateLimitSnapshot {
  inputTokensRemaining?: number;
  outputTokensRemaining?: number;
  requestsRemaining?: number;
  /** ISO timestamp when the tightest bucket resets. */
  resetsAt?: string;
}

/**
 * Anthropic reports quota in `anthropic-ratelimit-*` response headers. This is
 * headroom in the current window, NOT account balance — the closest thing the
 * API will tell us about limits.
 */
export function readRateLimits(headers: Headers | undefined): RateLimitSnapshot | null {
  if (!headers) return null;
  const num = (name: string): number | undefined => {
    const raw = headers.get(name);
    if (raw === null) return undefined;
    const n = Number(raw);
    return Number.isFinite(n) ? n : undefined;
  };
  const snap: RateLimitSnapshot = {
    inputTokensRemaining: num("anthropic-ratelimit-input-tokens-remaining"),
    outputTokensRemaining: num("anthropic-ratelimit-output-tokens-remaining"),
    requestsRemaining: num("anthropic-ratelimit-requests-remaining"),
    resetsAt:
      headers.get("anthropic-ratelimit-input-tokens-reset") ??
      headers.get("anthropic-ratelimit-requests-reset") ??
      undefined,
  };
  const known = Object.values(snap).some((v) => v !== undefined);
  return known ? snap : null;
}
