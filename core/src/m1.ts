// File replay: whisper streaming transcription -> rolling buffer -> prompt
// assembly -> streamed LLM answer, all in the terminal, driven by a
// pre-recorded audio file. Enter = the future global hotkey.
//
// Usage:
//   node src/m1.ts <audio>            # audio = remote side ("them")
//   node src/m1.ts --me my.wav --them them.wav   # two-track mode
//   flags: --chunk N  --realtime  --context "text"
//
// REPL: <Enter> quick answer (FAST)          /deep thorough answer (DEEP)
//       /ctx <text> add context              /reset new session      /q quit

import readline from "node:readline";
import { performance } from "node:perf_hooks";
import { loadConfig, type AnswerMode } from "./config.ts";
import { WhisperServer } from "./whisperServer.ts";
import { toWav16k, sliceWav, type WavChunk } from "./chunker.ts";
import { TranscriptBuffer, type Speaker } from "./transcriptBuffer.ts";
import { collapseRepeatedPhrases } from "./textUtils.ts";
import { CallSession, buildSystemPrompt } from "./session.ts";
import { streamAnswer } from "./answer.ts";

interface Args {
  tracks: { speaker: Speaker; file: string }[];
  chunkSeconds?: number;
  realtime: boolean;
  context?: string;
}

function parseArgs(argv: string[]): Args {
  const a: Args = { tracks: [], realtime: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--me") a.tracks.push({ speaker: "me", file: argv[++i] });
    else if (arg === "--them") a.tracks.push({ speaker: "them", file: argv[++i] });
    else if (arg === "--chunk") a.chunkSeconds = Number(argv[++i]);
    else if (arg === "--realtime") a.realtime = true;
    else if (arg === "--context") a.context = argv[++i];
    else if (!arg.startsWith("--")) a.tracks.push({ speaker: "them", file: arg });
    else throw new Error(`Unknown flag: ${arg}`);
  }
  if (!a.tracks.length) {
    throw new Error(
      "Usage: node src/m1.ts <audio> [--me f] [--them f] [--chunk N] [--realtime] [--context text]",
    );
  }
  return a;
}

function fmtTime(ms: number): string {
  const s = Math.floor(ms / 1000);
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

const args = parseArgs(process.argv.slice(2));
const cfg = loadConfig();
if (args.chunkSeconds) cfg.chunkSeconds = args.chunkSeconds;

const systemPrompt = buildSystemPrompt(cfg);
const buffer = new TranscriptBuffer();
const session = new CallSession();
if (args.context) session.addContext(args.context);

console.log(`Livecall m1 — backend=${cfg.llm.backend} (${cfg.llm.backend === "api" ? cfg.llm.fast.model : cfg.llm.cliModel}), chunk=${cfg.chunkSeconds}s, whisper=${cfg.whisper.modelPath.split("/").pop()}`);
if (cfg.llm.backend === "claude-cli") {
  console.log("⚠ claude-cli fallback: works without an API key, but CLI startup adds seconds — the <2s budget needs LLM_BACKEND=api + credentials.");
}

const server = new WhisperServer(cfg.whisper);
process.stdout.write("Loading whisper model… ");
const tLoad = performance.now();
await server.start();
console.log(`ready in ${((performance.now() - tLoad) / 1000).toFixed(1)}s`);

// Prepare chunks for every track, then merge into one time-ordered feed.
interface FeedItem extends WavChunk { speaker: Speaker }
const feed: FeedItem[] = [];
for (const t of args.tracks) {
  const wav = await toWav16k(t.file);
  for (const c of sliceWav(wav, cfg.chunkSeconds)) feed.push({ ...c, speaker: t.speaker });
}
feed.sort((a, b) => a.startMs - b.startMs);
console.log(`Feeding ${feed.length} chunk(s)${args.realtime ? " at 1x speed" : ""}. Press Enter anytime to answer the latest question.\n`);

let asking = false;
let feeding = true;
const chunkLatencies: number[] = [];

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
rl.on("line", (line) => {
  const cmd = line.trim();
  if (cmd === "/q") return shutdown();
  if (cmd === "/reset") {
    session.reset();
    buffer.reset();
    console.log("— session reset (new call) —");
    return;
  }
  if (cmd.startsWith("/ctx ")) {
    session.addContext(cmd.slice(5));
    console.log("— context added —");
    return;
  }
  if (cmd === "/deep") void ask("deep");
  if (cmd === "") void ask("fast");
});

async function ask(mode: AnswerMode): Promise<void> {
  if (asking) return;
  asking = true;
  const t0 = performance.now();
  const messages = session.ask(buffer, cfg.windowMs, mode);
  console.log(`\n┌─ 🔥 hotkey → answering (Q&A #${session.qaCount + 1}, ${mode}) …`);
  let firstMs = 0;
  try {
    const answer = await streamAnswer(cfg, mode, systemPrompt, messages, (tok) => {
      if (!firstMs) {
        firstMs = performance.now() - t0;
        process.stdout.write(`│  ⚡ first token: ${Math.round(firstMs)}ms\n│  `);
      }
      process.stdout.write(tok.replaceAll("\n", "\n│  "));
    });
    session.recordAnswer(answer);
    console.log(`\n└─ total: ${Math.round(performance.now() - t0)}ms\n`);
  } catch (e) {
    console.error(`\n└─ answer failed: ${(e as Error).message}\n`);
  }
  asking = false;
}

async function feedChunks(): Promise<void> {
  const feedStart = performance.now();
  for (const item of feed) {
    if (args.realtime) {
      const wait = item.startMs - (performance.now() - feedStart);
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    }
    const t = performance.now();
    const raw = await server.transcribe(item.wav);
    chunkLatencies.push(performance.now() - t);
    const text = collapseRepeatedPhrases(raw);
    if (text) {
      buffer.add({ startMs: item.startMs, endMs: item.endMs, speaker: item.speaker, text });
      const label = item.speaker === "me" ? "Me  " : "Them";
      console.log(`[${fmtTime(item.startMs)}] [${label}] ${text}`);
    }
  }
  feeding = false;
  const avg = chunkLatencies.reduce((a, b) => a + b, 0) / Math.max(chunkLatencies.length, 1);
  console.log(
    `\n— feed done: ${buffer.segments.length} segment(s); avg chunk transcription ${Math.round(avg)}ms ` +
      `for ${cfg.chunkSeconds}s of audio (RTF ${(avg / 1000 / cfg.chunkSeconds).toFixed(2)}) —`,
  );
  console.log("Enter = quick answer, /deep = thorough answer, /ctx = add context, /q = quit.\n");
}

function shutdown(): void {
  rl.close();
  server.stop();
  process.exit(0);
}
// SIGHUP/SIGTERM too, or a closed terminal window leaks the 3GB whisper-server.
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(sig, shutdown);

void feedChunks();
