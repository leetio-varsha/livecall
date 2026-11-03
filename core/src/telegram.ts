// Answers to Telegram, via a bot you own.
//
// WHY A BOT and not the account session: a bot token can only post into chats
// the bot is already in. If it leaks, the damage is "someone can message you".
// A user-account session string would hand full account access to a process
// that is already holding the microphone and a keyboard tap — a much worse
// blast radius for the same feature.
//
// Delivery is best-effort by design: a Telegram outage, a revoked token or a
// flaky network must never break or delay the answer on screen.

import type { Config } from "./config.ts";
import { splitAnswer } from "./answerParts.ts";

const API = "https://api.telegram.org";
/** Telegram hard-caps a message at 4096 chars. */
const MAX_CHARS = 4000;
/** The spoken part is the point of the message, so it gets the room; the
 * not-out-loud note is capped harder rather than pushing the answer out. */
const SPOKEN_CHARS = 3000;
const NOTE_CHARS = 900;

export interface TelegramDelivery {
  ok: boolean;
  error?: string;
}

/** Escapes the five characters Telegram's HTML parse mode cares about. */
function escapeHtml(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export class Telegram {
  private readonly token: string;
  private readonly chatId: string;
  /** Set after the first auth failure so we stop retrying a dead token. */
  private disabled = false;

  constructor(cfg: Config["telegram"]) {
    this.token = cfg.botToken;
    this.chatId = cfg.chatId;
  }

  get configured(): boolean {
    return !!this.token && !!this.chatId && !this.disabled;
  }

  /**
   * Post one answer. Resolves with the outcome instead of throwing — callers
   * report it and move on.
   */
  async sendAnswer(opts: {
    answer: string;
    heard?: string;
    mode: string;
    firstMs?: number;
    totalMs?: number;
  }): Promise<TelegramDelivery> {
    if (!this.configured) return { ok: false, error: "not configured" };

    const head = `<b>${opts.mode.toUpperCase()}</b>`;
    const timing =
      opts.firstMs && opts.totalMs
        ? ` <i>${(opts.firstMs / 1000).toFixed(1)}s / ${(opts.totalMs / 1000).toFixed(1)}s</i>`
        : "";
    const question = opts.heard?.trim()
      ? `\n<blockquote>${escapeHtml(truncate(opts.heard.trim(), 300))}</blockquote>`
      : "";
    // Same split the panel draws: on a phone the glance is even faster, so the
    // note goes into a blockquote behind a shouted header instead of sitting
    // flush against the words that get spoken.
    const parts = splitAnswer(opts.answer.trim());
    // The model's own reading of the question, next to the raw transcript
    // quote: `heard` is what the mic caught, this is what the model chose to
    // answer — the mismatch between the two is the thing worth noticing.
    const reading = parts.reading
      ? `\n<i>→ ${escapeHtml(truncate(parts.reading, 200))}</i>`
      : "";

    // Budget the ESCAPED length, not the raw one: escaping turns one `&` into
    // five characters, so a long DEEP answer full of `<`/`&` can blow past the
    // hard cap and come back 400 — a silently undelivered answer. Assemble,
    // measure, and shed the expendable parts until it fits.
    const build = (spoken: string, note?: string): string => {
      const noteBlock = note
        ? `\n\n<blockquote>🔇 <b>DO NOT READ ALOUD · if they press</b>\n${escapeHtml(note)}</blockquote>`
        : "";
      return `${head}${timing}${question}${reading}\n\n${escapeHtml(spoken)}${noteBlock}`;
    };

    let text = build(truncate(parts.spoken, SPOKEN_CHARS), parts.note && truncate(parts.note, NOTE_CHARS));
    if (text.length > MAX_CHARS) {
      // The note is the first thing to go — it is the part he never says.
      text = build(truncate(parts.spoken, SPOKEN_CHARS));
    }
    while (text.length > MAX_CHARS) {
      // Still over: only a pathological escape ratio gets here. Halve and retry
      // rather than cut the assembled HTML and break parse_mode.
      const shorter = Math.floor(parts.spoken.length / 2);
      if (shorter < 80) return { ok: false, error: "answer too large for telegram" };
      parts.spoken = truncate(parts.spoken, shorter);
      text = build(parts.spoken);
    }

    return this.post("sendMessage", {
      chat_id: this.chatId,
      text,
      parse_mode: "HTML",
      link_preview_options: { is_disabled: true },
    });
  }

  /** Confirms the token and chat are usable, for the setup window. */
  async check(): Promise<TelegramDelivery> {
    if (!this.token || !this.chatId) return { ok: false, error: "not configured" };
    return this.post("sendMessage", {
      chat_id: this.chatId,
      text: "Livecall is connected. Answers will arrive here.",
    });
  }

  private async post(method: string, payload: unknown): Promise<TelegramDelivery> {
    try {
      const res = await fetch(`${API}/bot${this.token}/${method}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(10_000),
      });
      if (res.ok) return { ok: true };

      const detail = (await res.text()).slice(0, 300);
      // 401 = bad token, 403 = the user never started the bot or blocked it.
      // Neither fixes itself, so stop hammering the API every answer.
      if (res.status === 401 || res.status === 403) {
        this.disabled = true;
        return { ok: false, error: `${res.status} — disabled until restart: ${detail}` };
      }
      return { ok: false, error: `${res.status}: ${detail}` };
    } catch (e) {
      return { ok: false, error: (e as Error).message };
    }
  }
}

function truncate(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, max - 1) + "…";
}
