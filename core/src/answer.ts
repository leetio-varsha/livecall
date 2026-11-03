import { spawn } from "node:child_process";
import os from "node:os";
import Anthropic from "@anthropic-ai/sdk";
import OpenAI from "openai";
import type { AnswerMode, Config, ModeParams } from "./config.ts";
import { readRateLimits, type RateLimitSnapshot, type TokenUsage } from "./pricing.ts";

interface Turn {
  role: "user" | "assistant";
  content: Content;
}

/** A user turn is plain text until a screenshot rides along with it. */
export type Content = string | Block[];
export type Block = TextBlock | ImageBlock;
export interface TextBlock {
  type: "text";
  text: string;
}
export interface ImageBlock {
  type: "image";
  source: { type: "base64"; media_type: "image/png"; data: string };
}

/**
 * Flatten a turn for a backend that cannot see images.
 *
 * The fallback chain ends at the Claude CLI, which takes text only. Silently
 * dropping the screenshot there would be the worst outcome available: the model
 * would answer confidently about a task it never saw, and that answer gets read
 * out loud. So the image is replaced by an instruction to admit the blindness.
 */
export function flattenContent(content: Content): string {
  if (typeof content === "string") return content;
  return content
    .map((b) =>
      b.type === "text"
        ? b.text
        : "[THE SCREENSHOT DID NOT REACH THIS MODEL — you do NOT see it. " +
          "Do not describe or guess what is on screen: say the capture did not " +
          "arrive and ask for the task in words.]",
    )
    .join("\n\n");
}

/** OpenAI takes the same idea in a different shape. */
function toOpenAIContent(content: Content): unknown {
  if (typeof content === "string") return content;
  return content.map((b) =>
    b.type === "text"
      ? { type: "text", text: b.text }
      : {
          type: "image_url",
          image_url: { url: `data:${b.source.media_type};base64,${b.source.data}` },
        },
  );
}

/** What a completed answer cost, alongside the text itself. */
export interface AnswerResult {
  text: string;
  /** Absent when the backend didn't report token counts. */
  usage?: TokenUsage;
  /** Quota headroom from the response headers of the winning attempt. */
  rateLimits?: RateLimitSnapshot;
}

/** Thrown when a backend died AFTER streaming tokens — do not retry elsewhere,
 * a second backend would re-answer from scratch on top of a partial answer. */
class MidStreamError extends Error {}

/**
 * Stream the answer through a fallback chain:
 *   anthropic api -> openai (if OPENAI_API_KEY) -> claude-cli
 * Each remote attempt is aborted if the server sends no event within
 * cfg.llm.firstEventTimeoutMs ("provider not responding").
 * `onToken` fires per text delta; first call = first visible token.
 */
export async function streamAnswer(
  cfg: Config,
  mode: AnswerMode,
  systemPrompt: string,
  messages: Turn[],
  onToken: (t: string) => void,
): Promise<AnswerResult> {
  const params = cfg.llm[mode];
  const chain: { name: string; run: () => Promise<AnswerResult> }[] =
    cfg.llm.backend === "api"
      ? [
          { name: `anthropic:${params.model}`, run: () => tryAnthropic(cfg, params, systemPrompt, messages, onToken) },
          ...(cfg.llm.openai.apiKey
            ? [{ name: `openai:${cfg.llm.openai.model}`, run: () => tryOpenAI(cfg, params, systemPrompt, messages, onToken) }]
            : []),
          { name: `claude-cli:${cfg.llm.cliModel}`, run: () => tryClaudeCli(cfg, systemPrompt, messages, onToken) },
        ]
      : [{ name: `claude-cli:${cfg.llm.cliModel}`, run: () => tryClaudeCli(cfg, systemPrompt, messages, onToken) }];

  let lastErr: Error = new Error("no LLM backend configured");
  for (let i = 0; i < chain.length; i++) {
    try {
      return await chain[i].run();
    } catch (e) {
      const err = e as Error;
      if (err instanceof MidStreamError) throw err;
      lastErr = err;
      const next = chain[i + 1];
      if (next) {
        console.error(`\n[fallback] ${chain[i].name} failed (${err.message.slice(0, 200)}) → trying ${next.name}`);
      }
    }
  }
  throw lastErr;
}

/** Primary: Anthropic API, streaming. */
async function tryAnthropic(
  cfg: Config,
  params: ModeParams,
  systemPrompt: string,
  messages: Turn[],
  onToken: (t: string) => void,
): Promise<AnswerResult> {
  const client = new Anthropic({ maxRetries: 1 }); // fail fast → fallback chain
  // Same TTL on both breakpoints: the API requires longer TTLs to come first,
  // and mixing them would put the conversation on the short one.
  const cache = { type: "ephemeral" as const, ttl: cfg.llm.cacheTtl };
  const stream = client.messages.stream({
    model: params.model,
    max_tokens: params.maxTokens,
    // Stable system prompt cached; conversation prefix gets cache-reads on
    // every subsequent hotkey press in this call (both modes share it).
    system: [{ type: "text", text: systemPrompt, cache_control: cache }],
    messages,
    // Cache the CONVERSATION too, not just the system prompt. Without this the
    // whole prefix — pasted call context, attached files, the growing
    // transcript and every previous answer — is re-billed at full price on
    // every hotkey press. Top-level cache_control auto-places the breakpoint on
    // the last cacheable block, so each press reads what the previous one
    // wrote. Measured on a 10k-char context: 5177 full-price tokens per press
    // became cache reads at a tenth of the cost.
    //
    // The TTL is the other half of that. The cache lived 5 minutes and a demo
    // call is two hours of questions minutes apart: on 2026-09-02, 1.45M of the
    // day's 2.4M input tokens were cache WRITES — the prefix re-billed at full
    // price after every pause — and that was $9 of a $9.91 day.
    cache_control: cache,
    ...(params.thinking === "disabled" ? { thinking: { type: "disabled" as const } } : {}),
    output_config: { effort: params.effort },
  } as Anthropic.MessageStreamParams);

  // Claim the stream's terminal promise up front. On abort the SDK does a bare
  // `Promise.reject(error)` unless something is already awaiting it — and that
  // unhandled rejection takes the whole process down. Which is exactly what
  // happened: the 6s watchdog fired, the chain moved to OpenAI, and the app
  // died mid-call instead of answering. The real result is still read below.
  void stream.done().catch(() => {});

  let emitted = false;
  stream.on("text", (t) => {
    emitted = true;
    onToken(t);
  });

  // Watchdog: message_start precedes any text, so this can't fire mid-answer.
  // In deep mode thinking may run for a while, but the SERVER answers within
  // ~a second — the timeout catches a dead/overloaded API, not slow thinking.
  await raceFirstSignal(
    new Promise<void>((resolve, reject) => {
      stream.on("streamEvent", () => resolve());
      stream.on("error", reject);
    }),
    cfg.llm.firstEventTimeoutMs,
    () => stream.abort(),
    "anthropic",
  );

  try {
    const final = await stream.finalMessage();
    // Headers carry quota headroom for the current window. There is no
    // balance endpoint — this is as close as the API gets.
    const rateLimits = readRateLimits(stream.response?.headers) ?? undefined;
    const usage: TokenUsage = {
      inputTokens: final.usage.input_tokens ?? 0,
      outputTokens: final.usage.output_tokens ?? 0,
      cacheReadTokens: final.usage.cache_read_input_tokens ?? 0,
      cacheWriteTokens: final.usage.cache_creation_input_tokens ?? 0,
      cacheWrite1hTokens: final.usage.cache_creation?.ephemeral_1h_input_tokens ?? 0,
      model: final.model || params.model,
      provider: "anthropic",
    };
    if (final.stop_reason === "refusal") {
      return { text: "(the model declined to answer this request)", usage, rateLimits };
    }
    const text = final.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("\n");
    return { text, usage, rateLimits };
  } catch (e) {
    if (emitted) throw new MidStreamError(`anthropic died mid-stream: ${(e as Error).message}`);
    throw e;
  }
}

/** Cross-provider fallback: OpenAI, streaming. Only runs when Anthropic failed. */
async function tryOpenAI(
  cfg: Config,
  params: ModeParams,
  systemPrompt: string,
  messages: Turn[],
  onToken: (t: string) => void,
): Promise<AnswerResult> {
  const client = new OpenAI({ apiKey: cfg.llm.openai.apiKey, maxRetries: 1 });
  const controller = new AbortController();

  const createReq = client.chat.completions.create(
    {
      model: cfg.llm.openai.model,
      stream: true,
      // Without this the streamed response carries no token counts at all.
      stream_options: { include_usage: true },
      max_completion_tokens: params.maxTokens,
      ...(cfg.llm.openai.reasoningEffort
        ? { reasoning_effort: cfg.llm.openai.reasoningEffort as never }
        : {}),
      messages: [
        { role: "system", content: systemPrompt },
        ...messages.map((m) => ({ role: m.role, content: toOpenAIContent(m.content) })),
      ] as never,
    },
    { signal: controller.signal },
  );

  // create() resolves when the server starts responding — that's our signal.
  const stream = await raceFirstSignal(
    createReq,
    cfg.llm.firstEventTimeoutMs,
    () => controller.abort(),
    "openai",
  );

  let text = "";
  let usage: TokenUsage | undefined;
  try {
    for await (const chunk of stream) {
      const delta = chunk.choices[0]?.delta?.content;
      if (delta) {
        text += delta;
        onToken(delta);
      }
      // The usage-bearing chunk arrives last and has no choices.
      if (chunk.usage) {
        usage = {
          inputTokens: chunk.usage.prompt_tokens ?? 0,
          outputTokens: chunk.usage.completion_tokens ?? 0,
          cacheReadTokens: chunk.usage.prompt_tokens_details?.cached_tokens ?? 0,
          cacheWriteTokens: 0,
          model: cfg.llm.openai.model,
          provider: "openai",
        };
      }
    }
  } catch (e) {
    if (text) throw new MidStreamError(`openai died mid-stream: ${(e as Error).message}`);
    throw e;
  }
  if (!text) throw new Error("openai returned no text");
  return { text, usage };
}

async function raceFirstSignal<T>(
  signal: Promise<T>,
  timeoutMs: number,
  onTimeout: () => void,
  who: string,
): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      onTimeout();
      reject(new Error(`${who}: no response within ${timeoutMs}ms`));
    }, timeoutMs);
  });
  // The loser of this race keeps living: aborting a provider rejects its
  // promise long after we stopped awaiting it. Mark it handled now, or that
  // late rejection is unhandled — which crashes the process.
  void signal.catch(() => {});
  try {
    return await Promise.race([signal, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Last resort: local `claude` CLI (Claude Code subscription — no API key).
 * Single-prompt, so the conversation is flattened; CLI
 * startup adds seconds. ANTHROPIC_API_KEY is stripped so the CLI can't
 * silently bill the API.
 */
function tryClaudeCli(
  cfg: Config,
  systemPrompt: string,
  messages: Turn[],
  onToken: (t: string) => void,
): Promise<AnswerResult> {
  const prompt =
    `${systemPrompt}\n\n=== CONVERSATION ===\n` +
    messages
      .map(
        (m) =>
          `${m.role === "user" ? "USER" : "ASSISTANT (your previous answer)"}:\n` +
          flattenContent(m.content),
      )
      .join("\n\n") +
    `\n\nRespond with the assistant answer only.`;

  return new Promise<AnswerResult>((resolve, reject) => {
    const args = [
      "-p",
      "--output-format", "stream-json",
      "--include-partial-messages",
      "--verbose",
      "--model", cfg.llm.cliModel,
    ];
    const env = { ...process.env };
    delete env.ANTHROPIC_API_KEY;

    const child = spawn(cfg.llm.claudeCliPath, args, {
      cwd: os.tmpdir(),
      env,
      stdio: ["pipe", "pipe", "pipe"],
    });

    let streamed = "";
    let resultText = "";
    let stderr = "";
    let lineBuf = "";

    child.stdout.on("data", (d: Buffer) => {
      lineBuf += d.toString();
      let nl: number;
      while ((nl = lineBuf.indexOf("\n")) !== -1) {
        const line = lineBuf.slice(0, nl).trim();
        lineBuf = lineBuf.slice(nl + 1);
        if (!line) continue;
        try {
          const obj = JSON.parse(line);
          if (
            obj.type === "stream_event" &&
            obj.event?.type === "content_block_delta" &&
            obj.event.delta?.type === "text_delta"
          ) {
            streamed += obj.event.delta.text;
            onToken(obj.event.delta.text);
          } else if (obj.type === "result") {
            resultText = typeof obj.result === "string" ? obj.result : "";
          }
        } catch {
          // non-JSON noise on stdout — ignore
        }
      }
    });
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("error", (e) =>
      reject(
        new Error(
          `Failed to launch Claude CLI ("${cfg.llm.claudeCliPath}"): ${e.message}. ` +
            `Install & log in to Claude Code, or set ANTHROPIC_API_KEY for the api backend.`,
        ),
      ),
    );
    child.on("close", (code) => {
      if (code !== 0) {
        return reject(new Error(`Claude CLI exited ${code}: ${stderr.trim().slice(-1000)}`));
      }
      const text = resultText || streamed;
      if (!text) return reject(new Error("Claude CLI returned no text"));
      // If partial streaming wasn't emitted, deliver the whole result at once.
      if (!streamed && resultText) onToken(resultText);
      // Runs on the Claude Code subscription — no metered API charge, so the
      // usage tracker prices this at zero rather than guessing.
      resolve({
        text,
        usage: {
          inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
          model: cfg.llm.cliModel, provider: "claude-cli",
        },
      });
    });

    child.stdin.on("error", () => {}); // ignore EPIPE
    child.stdin.write(prompt);
    child.stdin.end();
  });
}
