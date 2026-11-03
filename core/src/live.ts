// Terminal front-end for the engine. The Swift helper streams
// mic ("me") + system audio ("them") as PCM frames and turns the global hotkeys
// into control frames; everything after that is engine.ts. The menu-bar app
// drives the same engine through ipc.ts instead.
//
// Usage:
//   node src/live.ts                       # real capture via the Swift helper
//   node src/live.ts --replay <audio>      # simulate: feed a file as "them" at 1x
//   node src/live.ts --replay <audio> --rate 4   # ...at 4x speed
//   helper passthrough flags: --no-mic --no-system --no-detect --no-hotkey
//
// Hotkeys (work from any app): ⌥⌘A = FAST, ⌥⇧⌘A = DEEP (HOTKEY_* in .env).
// REPL fallback: <Enter> quick answer (FAST)   /deep thorough answer (DEEP)
//       /ctx <text> add context            /reset new session      /q quit

import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import readline from "node:readline";
import { loadConfig, type AnswerMode } from "./config.ts";
import { toWav16k, findDataChunk, BYTES_PER_SEC } from "./chunker.ts";
import { FrameParser, SOURCE, type ControlFrame, type HelperFrame } from "./frames.ts";
import { Engine } from "./engine.ts";

const argv = process.argv.slice(2);
const replayIdx = argv.indexOf("--replay");
const replayFile = replayIdx !== -1 ? argv[replayIdx + 1] : null;
const rateIdx = argv.indexOf("--rate");
const replayRate = rateIdx !== -1 ? Number(argv[rateIdx + 1]) : 1;

const cfg = loadConfig();

/** True between the first token and the end of the current answer. */
let streaming = false;

const engine = new Engine(cfg, {
  onNotice: (text) => console.log(`— ${text} —`),
  onSessionReset: (reason) => console.log(`— ${reason}: new session —`),
  onTranscript: (seg) => {
    const s = Math.floor(seg.startMs / 1000);
    const stamp = `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
    console.log(`[${stamp}] [${seg.speaker === "me" ? "Me  " : "Them"}] ${seg.text}`);
  },
  onBusy: (i) => console.log(`— busy answering; ${i.trigger} (${i.mode}) ignored —`),
  onAskStart: (i) => console.log(`\n┌─ 🔥 ${i.trigger} → answering (Q&A #${i.qaIndex}, ${i.mode}) …`),
  onFirstToken: (ms) => {
    streaming = true;
    process.stdout.write(`│  ⚡ first token: ${ms}ms (incl. flush)\n│  `);
  },
  onAnswerToken: (token) => process.stdout.write(token.replaceAll("\n", "\n│  ")),
  onAnswerDone: (i) => {
    streaming = false;
    const spend = i.usage?.line ? ` · ${i.usage.line}` : "";
    console.log(`\n└─ total: ${i.totalMs}ms${spend}\n`);
  },
  onDelivered: (target, ok, error) =>
    console.log(ok ? `— sent to ${target} —` : `— ${target} failed: ${error} —`),
  onAnswerError: (msg) => {
    console.error(`${streaming ? "\n" : ""}└─ answer failed: ${msg}\n`);
    streaming = false;
  },
});

console.log(
  `Livecall live — backend=${cfg.llm.backend}` +
    `${cfg.llm.backend === "api" ? ` (${cfg.llm.fast.model})` : ` (${cfg.llm.cliModel})`}` +
    `${replayFile ? `, replay=${replayFile} @${replayRate}x` : ", live capture"}`,
);

process.stdout.write("Loading whisper model… ");
console.log(`ready in ${((await engine.start()) / 1000).toFixed(1)}s`);

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
rl.on("line", (line) => {
  const cmd = line.trim();
  if (cmd === "/q") return shutdown(0);
  if (cmd === "/reset") return engine.newCall("manual reset");
  if (cmd.startsWith("/ctx ")) {
    engine.addContext(cmd.slice(5));
    console.log("— context added —");
    return;
  }
  if (cmd === "/deep") void engine.ask("deep", "/deep");
  if (cmd === "") void engine.ask("fast", "enter");
});

// ---- audio source: Swift helper (default) or file replay ----
let helper: ChildProcess | null = null;

if (replayFile) {
  void replay(replayFile, replayRate);
} else {
  helper = startHelper();
}

function startHelper(): ChildProcess {
  if (!fs.existsSync(cfg.helperPath)) {
    console.error(`helper binary not found at ${cfg.helperPath} — run helper/build.sh first`);
    process.exit(1);
  }
  const passthrough = argv.filter((a) =>
    ["--no-mic", "--no-system", "--no-detect", "--no-hotkey"].includes(a),
  );
  const hotkeysOn = cfg.hotkey.enabled && !passthrough.includes("--no-hotkey");
  const hotkeyArgs = hotkeysOn
    ? ["--hotkey-fast", cfg.hotkey.fast, "--hotkey-deep", cfg.hotkey.deep]
    : ["--no-hotkey"];
  const excludeArgs = cfg.detectExclude ? ["--exclude-proc", cfg.detectExclude] : [];
  const child = spawn(cfg.helperPath, [...passthrough, ...hotkeyArgs, ...excludeArgs], {
    stdio: ["ignore", "pipe", "pipe"],
  });

  const parser = new FrameParser();
  child.stdout.on("data", (d: Buffer) => {
    let frames: HelperFrame[];
    try {
      frames = parser.push(d);
    } catch (e) {
      console.error(`helper stream broken: ${(e as Error).message} — stopping the helper`);
      child.kill("SIGTERM");
      return;
    }
    for (const f of frames) {
      if (f.kind === "audio") engine.feed(f.source === SOURCE.me ? "me" : "them", f.pcm);
      else onControl(f);
    }
  });
  child.stderr.on("data", (d: Buffer) => process.stderr.write(d));
  child.on("exit", (code) => {
    console.error(`helper exited (${code}) — no more audio${hotkeysOn ? " and no hotkeys" : ""}; /q to quit`);
  });
  console.log(
    hotkeysOn
      ? `Live capture running. Hotkeys: ${cfg.hotkey.fast} = quick, ${cfg.hotkey.deep} = thorough` +
          " (they work from any app once armed — see the [helper] line below).\n" +
          "Terminal fallback: Enter = quick, /deep = thorough, /ctx = context, /q = quit.\n"
      : "Live capture running (hotkeys off). Enter = quick answer, /deep = thorough, /ctx = context, /q = quit.\n",
  );
  return child;
}

/** Control frames from the helper: call auto-detect and the global hotkeys. */
function onControl(frame: ControlFrame): void {
  switch (frame.event) {
    case "call_start":
      engine.newCall("📞 call detected");
      break;
    case "call_end":
      console.log("— 📞 call ended (press /reset before the next one, or it resets on next call_start) —");
      break;
    case "hotkey": {
      const mode: AnswerMode = frame.mode === "deep" ? "deep" : "fast";
      void engine.ask(mode, "hotkey");
      break;
    }
    default:
      break; // forward-compatible: unknown events are not errors
  }
}

/** Feed a file through the exact live path, paced at `rate`x realtime. */
async function replay(file: string, rate: number): Promise<void> {
  const wavPath = await toWav16k(file);
  const wav = fs.readFileSync(wavPath);
  const { offset, size } = findDataChunk(wav);
  const blockBytes = (BYTES_PER_SEC / 10) & ~1; // 100ms blocks
  console.log(`Replaying ${(size / BYTES_PER_SEC).toFixed(1)}s of audio at ${rate}x. Enter/(deep) anytime.\n`);
  for (let pos = 0; pos < size; pos += blockBytes) {
    engine.feed("them", wav.subarray(offset + pos, offset + Math.min(pos + blockBytes, size)));
    await new Promise((r) => setTimeout(r, 100 / rate));
  }
  engine.flush();
  await engine.drain();
  const lat = engine.chunkLatencies;
  const avg = lat.reduce((a, b) => a + b, 0) / Math.max(lat.length, 1);
  console.log(
    `\n— replay done: ${engine.buffer.segments.length} segment(s), avg chunk transcription ${Math.round(avg)}ms —`,
  );
  console.log("Enter = quick answer, /deep = thorough, /ctx = context, /q = quit.\n");
}

let shuttingDown = false;

function shutdown(code: number): void {
  if (shuttingDown) return;
  shuttingDown = true;
  rl.close();
  helper?.kill("SIGTERM");
  engine.stop();
  process.exit(code);
}

// Not just Ctrl-C: closing the terminal window (SIGHUP) or `kill` (SIGTERM)
// used to leave a 3GB whisper-server AND the helper — still holding the mic
// and the keyboard tap — reparented to launchd.
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
  process.on(sig, () => shutdown(0));
}
