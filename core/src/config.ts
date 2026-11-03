import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const CORE_ROOT = path.resolve(here, "..");

try {
  process.loadEnvFile(path.join(CORE_ROOT, ".env"));
} catch {
  // no .env yet — defaults below assume whisper.cpp under ~/whisper.cpp
}

function opt(name: string, fallback = ""): string {
  const v = process.env[name];
  return v && v.trim() ? v.trim() : fallback;
}

/** Expand a leading ~ so .env paths can be written the way people type them. */
function expandHome(p: string): string {
  return p.startsWith("~") ? path.join(os.homedir(), p.slice(1)) : p;
}

/** fast = quick crib on Enter; deep = thorough structured answer on /deep. */
export type AnswerMode = "fast" | "deep";

export interface ModeParams {
  model: string;
  effort: "low" | "medium" | "high";
  thinking: "disabled" | "adaptive";
  maxTokens: number;
}

export interface Config {
  whisper: {
    serverBin: string;
    modelPath: string;
    vadModel: string;
    port: number;
    lang: string;
    /** When set, m1 uses this URL and does not spawn its own server. */
    serverUrl: string;
  };
  llm: {
    backend: "api" | "claude-cli";
    cliModel: string;
    claudeCliPath: string;
    fast: ModeParams;
    deep: ModeParams;
    /** Cross-provider fallback, used only when the Anthropic attempt fails. */
    openai: { apiKey: string; model: string; reasoningEffort: string };
    /** Abort an attempt if the server hasn't sent ANY event within this time. */
    firstEventTimeoutMs: number;
    /**
     * Prompt-cache lifetime. "1h" writes cost 2x base input instead of 1.25x,
     * but survive the pauses a real call is made of — nobody presses the key
     * every five minutes, and every expiry re-billed the whole prefix. A short
     * dense session where the key is pressed every couple of minutes is a
     * little cheaper on "5m".
     */
    cacheTtl: "5m" | "1h";
  };
  answerLang: "auto" | "ru" | "uk" | "en";
  windowMs: number;
  chunkSeconds: number;
  /** Path to the Swift capture helper binary. */
  helperPath: string;
  /**
   * How long a capture track may deliver NO frames before it counts as dead.
   * Not a speech timeout — frames flow through silence too, so this only ever
   * fires when the capture itself stopped.
   */
  audioStallMs: number;
  /**
   * Global hotkeys, caught by the helper and sent back as
   * control frames. Specs are "mod+mod+key", e.g. "shift+opt+cmd+a".
   */
  hotkey: {
    enabled: boolean;
    fast: string;
    deep: string;
  };
  /** Answers to Telegram via a bot you own (see telegram.ts for why a bot). */
  telegram: {
    botToken: string;
    chatId: string;
    /** Send every answer, not just in silent mode. */
    always: boolean;
  };
  /** Silent: no panel, answers go to Telegram only. */
  silent: boolean;
  /**
   * Optional Admin API key (`sk-ant-admin01-…`) for authoritative billed cost.
   * Organization accounts only — the Admin API does not exist for individual
   * accounts, so the local counter stays the primary number either way.
   */
  adminKey: string;
  /**
   * Extra process names that must not count as a call (comma-separated).
   * Anything that holds the mic without being a call belongs here — otherwise
   * it looks like a new call and wipes the running Q&A session.
   */
  detectExclude: string;
  segment: {
    silenceMs: number;
    silenceRms: number;
    minSpeechMs: number;
    maxChunkMs: number;
  };
  /**
   * The mid-call context scout (see scout.ts): pulls files off the project's
   * shelf into the prompt when their topic comes up. Runs on its own timer,
   * entirely off the answer path.
   */
  scout: {
    enabled: boolean;
    intervalMs: number;
    /** A small model — it only matches topics to file NAMES. */
    model: string;
    /** Total chars injectable per call: the shelf is unbounded, the prompt is not. */
    maxChars: number;
    /** Floor between injections — each one rewrites the cached prompt prefix,
     * so back-to-back pulls would re-bill it at 1.25x press after press. */
    minGapMs: number;
  };
}

export function loadConfig(): Config {
  const home = os.homedir();

  const backendPref = opt("LLM_BACKEND", "auto");
  const hasApiCreds = !!(process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN);
  const backend =
    backendPref === "auto" ? (hasApiCreds ? "api" : "claude-cli") : backendPref;
  if (backend !== "api" && backend !== "claude-cli") {
    throw new Error(`LLM_BACKEND must be auto|api|claude-cli, got "${backendPref}"`);
  }

  const answerLang = opt("ANSWER_LANG", "auto") as Config["answerLang"];
  if (!["auto", "ru", "uk", "en"].includes(answerLang)) {
    throw new Error(`ANSWER_LANG must be auto|ru|uk|en, got "${answerLang}"`);
  }

  const cacheTtl = opt("CACHE_TTL", "1h") as Config["llm"]["cacheTtl"];
  if (!["5m", "1h"].includes(cacheTtl)) {
    throw new Error(`CACHE_TTL must be 5m|1h, got "${cacheTtl}"`);
  }

  const model = opt("LLM_MODEL", "claude-opus-5");
  const readMode = (prefix: string, defaults: ModeParams): ModeParams => {
    const thinking = opt(`${prefix}_THINKING`, defaults.thinking) as ModeParams["thinking"];
    if (!["disabled", "adaptive"].includes(thinking)) {
      throw new Error(`${prefix}_THINKING must be disabled|adaptive, got "${thinking}"`);
    }
    return {
      model: opt(`${prefix}_MODEL`, defaults.model),
      effort: opt(`${prefix}_EFFORT`, defaults.effort) as ModeParams["effort"],
      thinking,
      maxTokens: Number(opt(`${prefix}_MAX_TOKENS`, String(defaults.maxTokens))),
    };
  };

  return {
    whisper: {
      serverBin: expandHome(
        opt("WHISPER_SERVER_BIN", path.join(home, "whisper.cpp/build/bin/whisper-server")),
      ),
      modelPath: expandHome(
        opt("WHISPER_MODEL", path.join(home, "whisper.cpp/models/ggml-large-v3.bin")),
      ),
      vadModel: expandHome(
        opt("WHISPER_VAD_MODEL", path.join(home, "whisper.cpp/models/ggml-silero-v5.1.2.bin")),
      ),
      port: Number(opt("WHISPER_PORT", "8178")),
      lang: opt("WHISPER_LANG", "auto"),
      serverUrl: opt("WHISPER_SERVER_URL"),
    },
    llm: {
      backend,
      cliModel: opt("LLM_CLI_MODEL", "sonnet"),
      claudeCliPath: opt("CLAUDE_CLI_PATH", "claude"),
      // fast: latency first — instant crib for short factual questions
      fast: readMode("LLM", { model, effort: "low", thinking: "disabled", maxTokens: 1024 }),
      // deep: quality first — design/open-ended questions can afford seconds
      deep: readMode("DEEP", { model, effort: "high", thinking: "adaptive", maxTokens: 4096 }),
      openai: {
        apiKey: opt("OPENAI_API_KEY"),
        model: opt("OPENAI_MODEL", "gpt-5.1"),
        reasoningEffort: opt("OPENAI_REASONING_EFFORT"),
      },
      firstEventTimeoutMs: Number(opt("LLM_FIRST_EVENT_TIMEOUT_MS", "6000")),
      cacheTtl,
    },
    answerLang,
    windowMs: Number(opt("ANSWER_WINDOW_MIN", "3")) * 60_000,
    chunkSeconds: Number(opt("CHUNK_SECONDS", "5")),
    helperPath: expandHome(
      opt("HELPER_PATH", path.resolve(CORE_ROOT, "../helper/build/livecall-helper")),
    ),
    audioStallMs: Number(opt("AUDIO_STALL_MS", "8000")),
    hotkey: {
      enabled: opt("HOTKEY_ENABLED", "1") !== "0",
      fast: opt("HOTKEY_FAST", "opt+cmd+a"),
      deep: opt("HOTKEY_DEEP", "shift+opt+cmd+a"),
    },
    telegram: {
      botToken: opt("TELEGRAM_BOT_TOKEN"),
      chatId: opt("TELEGRAM_CHAT_ID"),
      always: opt("TELEGRAM_ALWAYS", "1") !== "0",
    },
    silent: opt("SILENT_MODE", "0") === "1",
    adminKey: opt("ANTHROPIC_ADMIN_KEY"),
    detectExclude: opt("DETECT_EXCLUDE"),
    segment: {
      silenceMs: Number(opt("SEGMENT_SILENCE_MS", "600")),
      silenceRms: Number(opt("SEGMENT_SILENCE_RMS", "350")),
      minSpeechMs: Number(opt("SEGMENT_MIN_SPEECH_MS", "700")),
      maxChunkMs: Number(opt("SEGMENT_MAX_CHUNK_MS", "6000")),
    },
    scout: {
      enabled: opt("SCOUT_ENABLED", "1") !== "0",
      intervalMs: Number(opt("SCOUT_INTERVAL_MS", "40000")),
      model: opt("SCOUT_MODEL", "claude-haiku-4-5"),
      maxChars: Number(opt("SCOUT_MAX_CHARS", "30000")),
      minGapMs: Number(opt("SCOUT_MIN_GAP_MS", "120000")),
    },
  };
}
