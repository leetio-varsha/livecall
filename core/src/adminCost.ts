// Authoritative spend, straight from Anthropic's billing — optional.
//
// What this is NOT: a balance check. No Anthropic or OpenAI endpoint reports
// remaining credit on a key; that number simply isn't exposed. The closest
// thing is this cost report, which says what has been BILLED so far.
//
// Requires a separate Admin API key (`sk-ant-admin01-…`), which:
//   • is not the same as the key used for inference,
//   • can only be created by an organization admin, and
//   • does not exist for individual accounts — Anthropic's docs are explicit
//     that the Admin API is unavailable to them.
// So this is best-effort garnish on top of the local counter, which stays the
// primary number precisely because it always works.
//
// Docs: /docs/en/manage-claude/usage-cost-api

const API = "https://api.anthropic.com/v1/organizations/cost_report";
/** The docs allow polling once a minute; a menu can open far more often. */
const CACHE_MS = 60_000;

export interface AdminCost {
  /** USD billed in the window. */
  usd: number;
  /** Why it's unavailable, when it is. */
  error?: string;
  fetchedAt: number;
}

export class AdminCostReporter {
  private key: string;
  private cache: AdminCost | null = null;
  /** Set on a permanent failure (no admin key, individual account, revoked). */
  private givenUp: string | null = null;

  constructor(adminKey: string) {
    this.key = adminKey;
  }

  get configured(): boolean {
    return !!this.key && !this.givenUp;
  }

  /** Billed cost since local midnight, or null when unavailable. */
  async today(): Promise<AdminCost | null> {
    if (!this.key || this.givenUp) return null;
    if (this.cache && Date.now() - this.cache.fetchedAt < CACHE_MS) return this.cache;

    const start = new Date();
    start.setHours(0, 0, 0, 0);
    const params = new URLSearchParams({
      starting_at: start.toISOString(),
      ending_at: new Date().toISOString(),
    });

    try {
      const res = await fetch(`${API}?${params}`, {
        headers: {
          "x-api-key": this.key,
          "anthropic-version": "2023-06-01",
          "user-agent": "Livecall/0.5 (call copilot)",
        },
        signal: AbortSignal.timeout(8_000),
      });

      if (!res.ok) {
        const detail = (await res.text()).slice(0, 200);
        // 401/403 = wrong key type, not an admin, or an individual account.
        // None of those change while the app runs, so stop asking.
        if (res.status === 401 || res.status === 403 || res.status === 404) {
          this.givenUp = `${res.status}: ${detail}`;
          return { usd: 0, error: this.givenUp, fetchedAt: Date.now() };
        }
        return { usd: 0, error: `${res.status}: ${detail}`, fetchedAt: Date.now() };
      }

      const body = (await res.json()) as { data?: { results?: { amount?: unknown }[] }[] };
      // Amounts are decimal strings in the currency's lowest unit — cents.
      let cents = 0;
      for (const bucket of body.data ?? []) {
        for (const row of bucket.results ?? []) {
          const n = Number(row.amount);
          if (Number.isFinite(n)) cents += n;
        }
      }
      this.cache = { usd: cents / 100, fetchedAt: Date.now() };
      return this.cache;
    } catch (e) {
      return { usd: 0, error: (e as Error).message, fetchedAt: Date.now() };
    }
  }
}
