// Ad-hoc answer-quality / latency bench: run one question through the real
// prompt path (session + system prompt + backend) without whisper.
// Usage: node src/bench.ts "the question, as it was said on the call" [--deep]
// Env overrides work as usual (LLM_BACKEND, LLM_EFFORT, DEEP_EFFORT, ...).

import { performance } from "node:perf_hooks";
import { loadConfig, type AnswerMode } from "./config.ts";
import { TranscriptBuffer } from "./transcriptBuffer.ts";
import { CallSession, buildSystemPrompt } from "./session.ts";
import { streamAnswer } from "./answer.ts";

const argv = process.argv.slice(2);
const mode: AnswerMode = argv.includes("--deep") ? "deep" : "fast";
const question = argv.find((a) => !a.startsWith("--"));
if (!question) {
  console.error('Usage: node src/bench.ts "question text" [--deep]');
  process.exit(1);
}

const cfg = loadConfig();
const p = cfg.llm[mode];
console.log(
  `bench — mode=${mode} backend=${cfg.llm.backend} model=${cfg.llm.backend === "api" ? p.model : cfg.llm.cliModel} ` +
    `effort=${p.effort} thinking=${p.thinking} max_tokens=${p.maxTokens}` +
    `${cfg.llm.openai.apiKey ? ` openai-fallback=${cfg.llm.openai.model}` : ""}\n`,
);

const buffer = new TranscriptBuffer();
buffer.add({ startMs: 0, endMs: 4000, speaker: "them", text: "Okay, let's move on to the architecture part." });
buffer.add({ startMs: 4000, endMs: 60_000, speaker: "them", text: question });

const session = new CallSession();
const messages = session.ask(buffer, cfg.windowMs, mode);

const t0 = performance.now();
let firstMs = 0;
const answer = await streamAnswer(cfg, mode, buildSystemPrompt(cfg), messages, (tok) => {
  if (!firstMs) {
    firstMs = performance.now() - t0;
    process.stdout.write(`⚡ first token: ${Math.round(firstMs)}ms\n\n`);
  }
  process.stdout.write(tok);
});
const total = Math.round(performance.now() - t0);
const words = answer.split(/\s+/).filter(Boolean).length;
console.log(`\n\n— total ${total}ms, ~${words} words —`);
