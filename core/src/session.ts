import fs from "node:fs";
import path from "node:path";
import { CORE_ROOT, type AnswerMode, type Config } from "./config.ts";
import type { TranscriptBuffer } from "./transcriptBuffer.ts";
import type { Turn } from "./answer.ts";
import type { Shot } from "./shot.ts";

const LANGUAGE_INSTRUCTIONS: Record<string, string> = {
  auto: "Answer in the language the question was asked in.",
  ru: "Always answer in Russian, regardless of the question's language.",
  uk: "Always answer in Ukrainian, regardless of the question's language.",
  en: "Always answer in English, regardless of the question's language.",
};

/**
 * The system prompt, plus whatever context [Me] attached.
 *
 * Context belongs HERE, not in the first user turn. It used to ride along as
 * the opening block of message #1, which put a briefing-sized document — the
 * one naming what the user has NOT done — underneath a growing transcript, as
 * ordinary conversation text competing with the real instructions. It read
 * like background, and the model treated it that way: asked about Spark, which
 * the context explicitly lists as "no production experience", it answered with
 * confident executor-tuning detail. As a system section the boundaries are an
 * instruction, which is what they always were.
 *
 * Cost is unchanged: the system block is the cache breakpoint either way.
 * Attaching context mid-call rewrites the prefix and costs one cache write —
 * rare, and worth it.
 */
export function buildSystemPrompt(cfg: Config, context: string[] = []): string {
  const template = fs.readFileSync(path.join(CORE_ROOT, "prompts", "answer.md"), "utf8");
  const base = template.replace(
    "{{LANGUAGE_INSTRUCTION}}",
    LANGUAGE_INSTRUCTIONS[cfg.answerLang] ?? LANGUAGE_INSTRUCTIONS.auto,
  );
  if (!context.length) return base;
  return (
    `${base}\n\n## CALL CONTEXT\n\n` +
    `Provided by [Me] before the call. Authoritative about who they are, what ` +
    `they have done, and — where it says so — what they have NOT done.\n\n` +
    context.join("\n\n")
  );
}

/**
 * One call = one session. Q&A pairs are real conversation turns, so
 * follow-up questions build on previous answers natively, and the growing
 * message prefix stays byte-stable for prompt caching. Each hotkey press
 * appends ONLY the transcript delta since the previous press.
 */
export class CallSession {
  messages: Turn[] = [];
  private sentSegments = 0;

  get qaCount(): number {
    return this.messages.filter((m) => m.role === "assistant").length;
  }

  /**
   * Build and append the user turn for a hotkey press (or a typed question).
   * Returns the messages array ready to send.
   *
   * Typed input rides IN the turn, never in the system prompt: editing the
   * system prompt rewrites the cached prefix on every note, while turns are
   * append-only and cost nothing extra. Notes are folded into the next turn
   * (rather than pushed as their own user message) for the same reason the
   * transcript is — one user turn per press keeps the roles alternating and
   * the prefix byte-stable.
   */
  ask(
    buffer: TranscriptBuffer,
    windowMs: number,
    mode: AnswerMode = "fast",
    shot?: Shot,
    opts: { typed?: string; notes?: string[]; pulled?: string[] } = {},
  ): Turn[] {
    const first = this.messages.length === 0;
    const delta = buffer.sinceIndex(this.sentSegments);
    this.sentSegments = buffer.segments.length;

    const parts: string[] = [];
    if (first) {
      parts.push(`CALL TRANSCRIPT SO FAR:\n${delta || "(no speech transcribed yet)"}`);
    } else {
      parts.push(
        `TRANSCRIPT SINCE MY LAST QUESTION:\n${delta || "(nothing new was said)"}`,
      );
    }

    if (opts.pulled?.length) {
      // Shelf files the scout picked for a topic just raised. They ride in
      // the turn for the same reason notes do: folding them into the system
      // prompt rewrote the whole cached prefix — pack, transcript, every
      // answer — at full price on each pull. The prompt's CALL CONTEXT rules
      // are told to cover this heading too.
      parts.push(
        `PACK MATERIAL PULLED MID-CALL — [Me]'s own files, from the same pack as CALL ` +
          `CONTEXT. Treat it as CALL CONTEXT: ground truth, same rules, for the rest ` +
          `of the call:\n\n` +
          opts.pulled.join("\n\n"),
      );
    }

    if (opts.notes?.length) {
      // Typed by [Me] into the panel, so unlike the transcript it carries no
      // recognition errors — where the two disagree, the note wins.
      parts.push(
        `NOTES TYPED BY [Me] since the last answer — typed straight into the panel, ` +
          `NOT said on the call. Authoritative over the transcript where they disagree:\n` +
          opts.notes.map((n) => `- ${n}`).join("\n"),
      );
    }

    const windowMin = Math.round(windowMs / 60_000);
    if (opts.typed) {
      parts.push(
        `^^^ [Me] just TYPED this to you (not said on the call): «${opts.typed}»\n` +
          `Answer THIS — it overrides whatever the recent transcript suggests. If it ` +
          `corrects or redirects your previous answer, give the corrected answer, not ` +
          `an apology. ` +
          (mode === "deep"
            ? `Give the thorough, structured DEEP-mode answer now.`
            : `Answer now as a quick FAST-mode crib.`),
      );
    } else {
      parts.push(
        `^^^ The hotkey was just pressed — ${mode.toUpperCase()} mode. Find the most recent ` +
          `question addressed to [Me] (look at roughly the last ${windowMin} minutes) and ` +
          (mode === "deep"
            ? `give the thorough, structured DEEP-mode answer now.`
            : `answer it now as a quick FAST-mode crib.`),
      );
    }

    if (shot) {
      parts.push(
        "^^^ The screenshot above is MY SCREEN right now — usually the task or " +
          "code the other side is sharing. Read it and answer about what is " +
          "actually in it. If it is unreadable, say so instead of guessing.",
      );
    }
    const text = parts.join("\n\n");

    // Image first, question second: that is the order the models are happiest
    // reading, and the text refers back to it.
    this.messages.push(
      shot
        ? {
            role: "user",
            content: [
              { type: "image", source: { type: "base64", media_type: shot.mediaType, data: shot.base64 } },
              { type: "text", text },
            ],
          }
        : { role: "user", content: text },
    );
    return this.messages;
  }

  recordAnswer(text: string): void {
    this.messages.push({ role: "assistant", content: text });
    this.forgetShots();
  }

  /**
   * Drop screenshots from history the moment their answer is done.
   *
   * A screenshot left in the conversation is not just weight — it is wrong. It
   * would sit in front of the model for the rest of the call, describing a
   * screen that has since scrolled, closed or moved on, and quietly colour
   * every later answer.
   *
   * This does cost the prompt cache: the prefix changes, so the next press
   * rewrites it once at 1.25x instead of reading it at 0.1x. One cache rewrite
   * per screen question is the cheaper mistake.
   */
  private forgetShots(): void {
    for (const m of this.messages) {
      if (typeof m.content === "string") continue;
      m.content = m.content.map((b) =>
        b.type === "image"
          ? { type: "text" as const, text: "[SCREENSHOT attached to that question — no longer current]" }
          : b,
      );
    }
  }

  /** New call → new session. Attached context is NOT part of this: it lives in
   * the system prompt and outlives the transcript it was pasted for. */
  reset(): void {
    this.messages = [];
    this.sentSegments = 0;
  }
}
