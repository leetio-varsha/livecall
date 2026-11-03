// The call-assistant engine: PCM in, answers out. Everything between the audio
// source and the LLM lives here — whisper, pause-based segmentation, the
// speaker-tagged transcript, the Q&A session and the answer stream.
//
// It deliberately knows nothing about HOW audio arrives or WHERE answers go:
// the terminal front-end (live.ts) and the menu-bar app front-end (ipc.ts)
// both drive this same object and only differ in presentation.

import fs from "node:fs";
import path from "node:path";
import { performance } from "node:perf_hooks";
import Anthropic from "@anthropic-ai/sdk";
import type { AnswerMode, Config } from "./config.ts";
import { WhisperServer } from "./whisperServer.ts";
import { Segmenter, type AudioChunk } from "./segmenter.ts";
import { TranscriptBuffer, type Segment, type Speaker } from "./transcriptBuffer.ts";
import { collapseRepeatedPhrases } from "./textUtils.ts";
import { CallSession, buildSystemPrompt } from "./session.ts";
import { buildScoutPrompt, parseScoutReply, ScoutLedger } from "./scout.ts";
import { streamAnswer } from "./answer.ts";
import { loadShot } from "./shot.ts";
import { UsageTracker, type UsageSummary } from "./usage.ts";
import { AdminCostReporter } from "./adminCost.ts";
import { Telegram } from "./telegram.ts";
import { formatCost, type RateLimitSnapshot } from "./pricing.ts";
import { trackHealth, type AudioHealth } from "./audioHealth.ts";

export type { TrackHealth, AudioHealth } from "./audioHealth.ts";

export interface AskInfo {
  mode: AnswerMode;
  /** What asked: "hotkey", "enter", "/deep", … — shown to the user. */
  trigger: string;
  /** 1-based number of this Q&A within the session. */
  qaIndex: number;
  /** A screenshot of the user's screen rode along with this question. */
  withShot?: boolean;
  /** The question [Me] typed into the panel, when that is what asked. */
  typed?: string;
}

export interface AnswerDone extends AskInfo {
  answer: string;
  /** Time to the first token, including the audio flush. */
  firstMs: number;
  totalMs: number;
  /** What this answer cost and what it did to the day's total. */
  usage?: UsageSummary;
  rateLimits?: RateLimitSnapshot;
}

export interface EngineEvents {
  /** Human-readable status line ("call detected", "helper exited", …). */
  onNotice?: (text: string) => void;
  /** A capture track started or stopped delivering frames. Fires on CHANGE
   * only — this is what turns a silently dead microphone into a visible one. */
  onAudioHealth?: (health: AudioHealth) => void;
  onTranscript?: (segment: Segment) => void;
  onAskStart?: (info: AskInfo) => void;
  /** Fired once per answer, with the latency the whole product is judged on. */
  onFirstToken?: (ms: number, info: AskInfo) => void;
  onAnswerToken?: (token: string, info: AskInfo) => void;
  onAnswerDone?: (info: AnswerDone) => void;
  onAnswerError?: (message: string, info: AskInfo) => void;
  /** A hotkey arrived while the previous answer was still streaming. */
  onBusy?: (info: AskInfo) => void;
  /** A TYPED question arrived mid-stream and was queued to run right after. */
  onQueued?: (info: AskInfo) => void;
  /** A typed note was buffered for the next answer. */
  onNoteAdded?: (chars: number) => void;
  onSessionReset?: (reason: string) => void;
  /** Outcome of pushing the answer to Telegram, when it is configured. */
  onDelivered?: (target: string, ok: boolean, error?: string) => void;
  /** The scout pulled shelf files into the prompt mid-call. */
  onScoutPulled?: (files: string[], chars: number) => void;
}

export class Engine {
  readonly buffer = new TranscriptBuffer();
  readonly session = new CallSession();
  /** Per-chunk transcription latency, for the replay/bench summaries. */
  readonly chunkLatencies: number[] = [];

  private cfg: Config;
  private events: EngineEvents;
  private systemPrompt: string;
  /** When each track last delivered a frame; 0 = never. */
  private lastFrameAt: Record<Speaker, number> = { me: 0, them: 0 };
  private health: AudioHealth = { me: "off", them: "off" };
  private watchdog?: NodeJS.Timeout;
  /** Context [Me] attached. Survives newCall(): briefing notes do not stop
   * being true because the mic was grabbed again and the transcript restarted. */
  private context: string[] = [];
  /** The active project's files, re-sent fresh by the app on each call start.
   * One slot, replaced whole — see setProjectContext. */
  private projectContext = "";
  /** The project's SHELF: files [Me] saved but did not brief. Not in any
   * prompt — the scout's corpus. Replace semantics, like the project slot. */
  private shelf: string[] = [];
  /** Shelf contents the scout pulled since the last press. They ride in the
   * NEXT user turn (see session.ask), not the system prompt: a system-prompt
   * edit rewrites the whole cached prefix at full price on every pull.
   * newCall() drops them: the pulls answered the old call's topics. */
  private pendingPulls: string[] = [];
  /** Basenames already pulled — a topic that keeps coming up must not pay to
   * re-pull the same file. */
  private scoutPulled: string[] = [];
  private scoutLedger: ScoutLedger;
  /** Segments the scout has already seen — its own delta pointer, separate
   * from the session's, because they advance on different clocks. */
  private scoutedSegments = 0;
  private scoutTimer?: NodeJS.Timeout;
  /** A tick is awaiting the API — the interval must never stack another. */
  private scoutBusy = false;
  /** Notes typed into the panel, waiting to ride along with the next ask.
   * Unlike context these are about THIS call, so newCall() drops them. */
  private pendingNotes: string[] = [];
  /** A typed question that arrived mid-stream, to run right after. Only typed
   * input queues: a queued HOTKEY press would re-answer the same transcript,
   * but a typed correction is usually ABOUT the answer being streamed. */
  private queuedTyped?: { mode: AnswerMode; trigger: string; typed: string };
  private server: WhisperServer;
  private segmenters: Record<Speaker, Segmenter>;
  // Whisper handles one request at a time — a single queue keeps segments in
  // order and lets ask() await "everything heard up to the key press".
  private queue: Promise<void> = Promise.resolve();
  private asking = false;
  private usageTracker = new UsageTracker();
  private telegram: Telegram;
  private adminCost: AdminCostReporter;

  constructor(cfg: Config, events: EngineEvents = {}) {
    this.cfg = cfg;
    this.events = events;
    this.systemPrompt = buildSystemPrompt(cfg);
    this.server = new WhisperServer(cfg.whisper);
    this.scoutLedger = new ScoutLedger(cfg.scout.maxChars, cfg.scout.minGapMs);
    this.telegram = new Telegram(cfg.telegram);
    this.adminCost = new AdminCostReporter(cfg.adminKey);
    this.segmenters = {
      me: new Segmenter(cfg.segment),
      them: new Segmenter(cfg.segment),
    };
  }

  get busy(): boolean {
    return this.asking;
  }

  /** Spend so far — for the menu bar readout. */
  usage(): UsageSummary {
    return this.usageTracker.summary();
  }

  /**
   * Same, plus Anthropic's billed figure when an admin key is configured and
   * the account can actually use the Admin API. Falls back silently to the
   * local number, which is always available.
   */
  async usageWithBilling(): Promise<UsageSummary & { billedToday?: number; billingError?: string }> {
    const local = this.usageTracker.summary();
    if (!this.adminCost.configured) return local;
    const billed = await this.adminCost.today();
    if (!billed) return local;
    if (billed.error) return { ...local, billingError: billed.error };
    return {
      ...local,
      billedToday: billed.usd,
      line: `${local.line} · billed ${formatCost(billed.usd)}`,
    };
  }

  get telegramReady(): boolean {
    return this.telegram.configured;
  }

  /** Setup-window check: confirms the bot token and chat actually work. */
  testTelegram(): Promise<{ ok: boolean; error?: string }> {
    return this.telegram.check();
  }

  /** Boots whisper. Returns how long the model took to become ready, in ms. */
  async start(): Promise<number> {
    const t = performance.now();
    await this.server.start();
    this.startAudioWatchdog();
    this.startScout();
    return performance.now() - t;
  }

  stop(): void {
    if (this.watchdog) clearInterval(this.watchdog);
    this.watchdog = undefined;
    if (this.scoutTimer) clearInterval(this.scoutTimer);
    this.scoutTimer = undefined;
    this.server.stop();
  }

  /** Feed one PCM block (16kHz mono s16le) for a speaker. */
  feed(speaker: Speaker, pcm: Buffer): void {
    this.lastFrameAt[speaker] = Date.now();
    const chunk = this.segmenters[speaker].push(pcm);
    if (chunk) this.enqueue(speaker, chunk);
  }

  /** Current liveness of both tracks — the menu reads this before a call. */
  audioHealth(): AudioHealth {
    return { ...this.health };
  }

  /**
   * Watch for capture dying silently.
   *
   * AVAudioEngine and ScreenCaptureKit both stop delivering buffers after a
   * sleep/wake or an audio-device change WITHOUT throwing: the objects stay
   * alive, the app keeps believing capture is on, and the only symptom is that
   * every answer says "nothing was picked up". That cost a real call
   * after a 10-hour uptime. Frames are the ground truth, so watch the frames.
   */
  private startAudioWatchdog(): void {
    this.watchdog = setInterval(() => {
      const now = Date.now();
      const next: AudioHealth = {
        me: trackHealth(this.lastFrameAt.me, now, this.cfg.audioStallMs),
        them: trackHealth(this.lastFrameAt.them, now, this.cfg.audioStallMs),
      };
      if (next.me === this.health.me && next.them === this.health.them) return;
      this.health = next;
      this.events.onAudioHealth?.(next);
    }, 2000);
    // Never hold the process open just to watch for silence.
    this.watchdog.unref?.();
  }

  /**
   * The context scout (see scout.ts): on a timer, ask a small model whether
   * anything on the shelf answers a topic just raised, and fold what it picks
   * into the system prompt.
   *
   * Entirely off the answer path: ask() never waits on it, never checks it,
   * never even knows a tick ran. A scout failure is a skipped tick logged to
   * stderr — the next tick gets a fresh chance, and the un-pulled file was
   * never promised to anyone.
   */
  private startScout(): void {
    if (!this.cfg.scout.enabled) return;
    this.scoutTimer = setInterval(() => void this.scoutTick(), this.cfg.scout.intervalMs);
    this.scoutTimer.unref?.();
  }

  private async scoutTick(): Promise<void> {
    if (this.scoutBusy) return;
    if (this.cfg.llm.backend !== "api") return; // the scout needs an API key
    if (!this.shelf.length) return;
    // Never compete with an answer for the API or the event loop.
    if (this.asking) return;
    // Fresh transcript is the sign a call is actually happening — without it
    // the timer would poll the API all day over a silent room.
    if (this.buffer.segments.length <= this.scoutedSegments) return;
    if (!this.scoutLedger.canInject(Date.now()) || this.scoutLedger.remainingChars() <= 0) return;

    this.scoutBusy = true;
    try {
      // Topics live in the last few exchanges; a whole backlog would only
      // cost tokens and dilute the match.
      const delta = this.buffer.sinceIndex(this.scoutedSegments).slice(-4000);
      this.scoutedSegments = this.buffer.segments.length;
      const names = this.shelf.map((p) => path.basename(p));
      // Its own client: no retries and a hard timeout, so a slow tick dies
      // quietly instead of stacking behind the next one.
      const client = new Anthropic({ maxRetries: 0 });
      const res = await client.messages.create(
        {
          model: this.cfg.scout.model,
          max_tokens: 200,
          messages: [{ role: "user", content: buildScoutPrompt(delta, names, this.scoutPulled) }],
        },
        { signal: AbortSignal.timeout(10_000) },
      );
      // Scout calls are spend like any other — the day's total stays honest.
      this.usageTracker.record({
        inputTokens: res.usage.input_tokens ?? 0,
        outputTokens: res.usage.output_tokens ?? 0,
        cacheReadTokens: res.usage.cache_read_input_tokens ?? 0,
        cacheWriteTokens: res.usage.cache_creation_input_tokens ?? 0,
        model: this.cfg.scout.model,
        provider: "anthropic",
      }, "scout");
      const reply = res.content
        .filter((b): b is Anthropic.TextBlock => b.type === "text")
        .map((b) => b.text)
        .join("\n");
      const injected = this.injectPicked(parseScoutReply(reply, names));
      if (injected.files.length) {
        this.scoutLedger.recordInjection(Date.now(), injected.chars);
        this.events.onScoutPulled?.(injected.files, injected.chars);
      }
    } catch (e) {
      console.error(`[scout] tick failed: ${(e as Error).message}`);
    } finally {
      this.scoutBusy = false;
    }
  }

  /** Read the picked shelf files into pendingPulls, within the char budget. */
  private injectPicked(picked: string[]): { files: string[]; chars: number } {
    const files: string[] = [];
    let chars = 0;
    for (const name of picked) {
      if (this.scoutPulled.includes(name)) continue;
      const filePath = this.shelf.find((p) => path.basename(p) === name);
      if (!filePath) continue;
      // Text only: the Swift side can extract PDFs, this side cannot, and a
      // pulled PDF would inject binary garbage into the prompt.
      if (![".md", ".txt", ".text"].includes(path.extname(filePath).toLowerCase())) continue;
      const remaining = this.scoutLedger.remainingChars() - chars;
      if (remaining <= 0) break;
      try {
        // A file this size was never call material — skip it whole rather
        // than inject a truncated head of something enormous.
        if (fs.statSync(filePath).size > 512 * 1024) continue;
        const content = fs.readFileSync(filePath, "utf8").trim().slice(0, remaining);
        if (!content) continue;
        this.pendingPulls.push(`=== FILE: ${name} (scout-pulled mid-call) ===\n${content}`);
        this.scoutPulled.push(name);
        files.push(name);
        chars += content.length;
      } catch (e) {
        console.error(`[scout] could not read ${name}: ${(e as Error).message}`);
      }
    }
    return { files, chars };
  }

  /** Force out the in-flight chunks so the freshest words reach the prompt. */
  flush(): void {
    for (const speaker of ["me", "them"] as Speaker[]) {
      const chunk = this.segmenters[speaker].flush();
      if (chunk) this.enqueue(speaker, chunk);
    }
  }

  /** Resolves once everything fed so far has been transcribed. */
  async drain(): Promise<void> {
    await this.queue;
  }

  /** Attach pre-call or mid-call context, and fold it into the system prompt. */
  addContext(text: string): void {
    if (!text.trim()) return;
    this.context.push(text.trim());
    this.rebuildPrompt();
  }

  /**
   * The active project's context — REPLACE semantics, unlike addContext.
   *
   * The app re-reads the project's files and re-sends this on every call
   * start, because packs are edited up to minutes before the call. Append
   * semantics would duplicate the whole block per call and grow the system
   * prompt without bound; replacing costs the same one cache rewrite that
   * attaching context always did. Empty text clears the slot.
   */
  setProjectContext(text: string): void {
    this.projectContext = text.trim();
    this.rebuildPrompt();
  }

  /** The project's shelf — replace semantics, sent alongside the project
   * context. Only the PATHS live here; contents stay on disk until the scout
   * decides a file has earned its place in the prompt. */
  setProjectShelf(paths: string[]): void {
    this.shelf = paths;
  }

  private rebuildPrompt(): void {
    // The project block joins the same CALL CONTEXT section as ad-hoc
    // context, first: the prompt's honesty rules key off that section name.
    // Scout pulls are NOT here — they go out in the next turn (pendingPulls).
    const blocks = [
      ...(this.projectContext ? [this.projectContext] : []),
      ...this.context,
    ];
    this.systemPrompt = buildSystemPrompt(this.cfg, blocks);
  }

  /** Characters of attached context — the app shows this so "did it get my
   * prompt?" has an answer that isn't a guess. */
  get contextChars(): number {
    return this.context.reduce((n, c) => n + c.length, 0);
  }

  /** Buffer a typed note; it rides along with the next ask as part of that
   * user turn (see session.ask — turns keep the prompt cache append-only). */
  addNote(text: string): void {
    const trimmed = text.trim();
    if (!trimmed) return;
    this.pendingNotes.push(trimmed);
    this.events.onNoteAdded?.(trimmed.length);
  }

  /** New call: drop the transcript and the Q&A memory. */
  newCall(reason: string): void {
    this.pendingNotes = [];
    this.queuedTyped = undefined;
    // Scout pulls answered the OLD call's topics; the shelf itself survives,
    // same as the project slot — the files did not stop being available.
    this.scoutPulled = [];
    this.scoutedSegments = 0;
    this.scoutLedger.reset();
    this.pendingPulls = [];
    if (this.buffer.segments.length || this.session.messages.length) {
      this.session.reset();
      this.buffer.reset();
      this.events.onSessionReset?.(reason);
    } else {
      this.events.onNotice?.(reason);
    }
  }

  /**
   * Answer the question that was just asked. Flushes audio first, so the
   * question itself is always part of the prompt. `typed` is a question [Me]
   * typed into the panel — it replaces "find the question in the transcript".
   */
  async ask(mode: AnswerMode, trigger: string, shotPath?: string, typed?: string): Promise<void> {
    const info: AskInfo = { mode, trigger, qaIndex: this.session.qaCount + 1 };
    if (typed) info.typed = typed;
    if (this.asking) {
      if (typed) {
        // A typed correction usually refers to the answer STILL STREAMING, so
        // dropping it (the hotkey behavior) would lose exactly the input that
        // matters most. Queue it; the finally below runs it next. Last typed
        // wins — two corrections in flight mean the first one was superseded.
        this.queuedTyped = { mode, trigger, typed };
        this.events.onQueued?.(info);
      } else {
        this.events.onBusy?.(info);
      }
      return;
    }
    this.asking = true;
    const t0 = performance.now();
    try {
      this.flush();
      await this.queue;
      // A screenshot that did not arrive must be said out loud, not skipped:
      // the answer would otherwise look like a normal one while being about
      // nothing the user can see.
      const shot = shotPath ? await loadShot(shotPath) : null;
      if (shotPath && !shot) {
        this.events.onNotice?.("screenshot did not arrive — answering without it");
      }
      info.withShot = !!shot;
      // Pending notes ride along and are consumed HERE, not earlier: a note
      // typed during a stream must land in the NEXT turn, not a finished one.
      const notes = this.pendingNotes;
      this.pendingNotes = [];
      const pulled = this.pendingPulls;
      this.pendingPulls = [];
      const messages = this.session.ask(
        this.buffer, this.cfg.windowMs, mode, shot ?? undefined, { typed, notes, pulled });
      this.events.onAskStart?.(info);

      let firstMs = 0;
      const result = await streamAnswer(this.cfg, mode, this.systemPrompt, messages, (token) => {
        if (!firstMs) {
          firstMs = performance.now() - t0;
          this.events.onFirstToken?.(Math.round(firstMs), info);
        }
        this.events.onAnswerToken?.(token, info);
      });
      const answer = result.text;
      this.session.recordAnswer(answer);

      if (result.usage) this.usageTracker.record(result.usage, "answer", mode);
      const done: AnswerDone = {
        ...info,
        answer,
        firstMs: Math.round(firstMs),
        totalMs: Math.round(performance.now() - t0),
        usage: this.usageTracker.summary(),
        rateLimits: result.rateLimits,
      };
      this.events.onAnswerDone?.(done);

      // Fire-and-forget: the answer is already delivered on screen, and a
      // Telegram failure must not surface as an answer failure.
      if (this.telegram.configured && (this.cfg.telegram.always || this.cfg.silent)) {
        void this.telegram
          .sendAnswer({
            answer,
            // For a typed ask the typed text IS the question — the last
            // transcript segment is whatever the room happened to be saying.
            heard: typed ?? this.buffer.segments.at(-1)?.text,
            mode,
            firstMs: done.firstMs,
            totalMs: done.totalMs,
          })
          .then((r) => this.events.onDelivered?.("telegram", r.ok, r.error));
      }
    } catch (e) {
      this.events.onAnswerError?.((e as Error).message, info);
    } finally {
      this.asking = false;
      const queued = this.queuedTyped;
      if (queued) {
        this.queuedTyped = undefined;
        void this.ask(queued.mode, queued.trigger, undefined, queued.typed);
      }
    }
  }

  private enqueue(speaker: Speaker, chunk: AudioChunk): void {
    this.queue = this.queue.then(async () => {
      const t = performance.now();
      const raw = await this.server.transcribe(chunk.wav);
      this.chunkLatencies.push(performance.now() - t);
      const text = collapseRepeatedPhrases(raw);
      if (!text) return;
      const segment: Segment = {
        startMs: chunk.startMs,
        endMs: chunk.endMs,
        speaker,
        text,
      };
      this.buffer.add(segment);
      this.events.onTranscript?.(segment);
    });
  }
}
