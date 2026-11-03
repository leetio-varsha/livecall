// Pure-logic self-tests (no whisper binary, no network). Run: npm test
import { collapseRepeatedPhrases } from "./textUtils.ts";
import { TranscriptBuffer } from "./transcriptBuffer.ts";
import { findDataChunk, sliceWav } from "./chunker.ts";
import { Segmenter, rms } from "./segmenter.ts";
import { CallSession, buildSystemPrompt } from "./session.ts";
import { splitAnswer } from "./answerParts.ts";
import { trackHealth } from "./audioHealth.ts";
import { loadConfig } from "./config.ts";
import { FrameParser, SOURCE, type HelperFrame } from "./frames.ts";
import { parseScoutReply, ScoutLedger } from "./scout.ts";
import { price, formatCost, readRateLimits } from "./pricing.ts";
import { UsageTracker, readLedger } from "./usage.ts";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

let ok = true;
const eq = (cond: boolean, msg: string) => {
  if (!cond) {
    ok = false;
    console.error("FAIL:", msg);
  } else console.log("ok:", msg);
};

// --- collapseRepeatedPhrases ---
const loop = "I think that's a great point. ".repeat(200).trim();
eq(
  collapseRepeatedPhrases(loop) === "I think that's a great point. I think that's a great point.",
  "collapses a 200x sentence loop to 2 copies",
);
eq(collapseRepeatedPhrases("Köln ".repeat(12).trim()) === "Köln Köln", "unicode 12x word -> 2");
eq(collapseRepeatedPhrases("yeah yeah") === "yeah yeah", "genuine doubled word untouched");
eq(collapseRepeatedPhrases("da da da") === "da da", "3x run capped to 2");

// --- TranscriptBuffer ---
{
  const b = new TranscriptBuffer();
  b.add({ startMs: 0, endMs: 5000, speaker: "them", text: "Hi, how is the search going?" });
  b.add({ startMs: 5000, endMs: 9000, speaker: "them", text: "We need an update." });
  b.add({ startMs: 2000, endMs: 4000, speaker: "me", text: "One second." }); // out-of-order insert
  eq(
    b.fullText() ===
      "[Them] Hi, how is the search going?\n[Me] One second.\n[Them] We need an update.",
    "fullText interleaves by time and groups by speaker",
  );
  eq(b.windowText(5000).includes("We need an update."), "windowText keeps recent segments");
  eq(!b.windowText(3000).includes("Hi, how"), "windowText drops old segments");
  eq(b.lastEndMs === 9000, "lastEndMs tracks the newest audio");
}

// --- WAV slicing ---
{
  const dataBytes = 32_000 * 7; // 7s of 16kHz mono s16le
  const h = Buffer.alloc(44);
  h.write("RIFF", 0);
  h.writeUInt32LE(36 + dataBytes, 4);
  h.write("WAVE", 8);
  h.write("fmt ", 12);
  h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20);
  h.writeUInt16LE(1, 22);
  h.writeUInt32LE(16_000, 24);
  h.writeUInt32LE(32_000, 28);
  h.writeUInt16LE(2, 32);
  h.writeUInt16LE(16, 34);
  h.write("data", 36);
  h.writeUInt32LE(dataBytes, 40);
  const wav = Buffer.concat([h, Buffer.alloc(dataBytes, 1)]);
  const p = path.join(os.tmpdir(), "livecall-selftest.wav");
  fs.writeFileSync(p, wav);

  const dc = findDataChunk(wav);
  eq(dc.offset === 44 && dc.size === dataBytes, "findDataChunk locates the data chunk");

  const chunks = sliceWav(p, 5);
  eq(chunks.length === 2, "7s audio -> 2 chunks at 5s");
  eq(chunks[0].startMs === 0 && chunks[0].endMs === 5000, "chunk 0 spans 0..5s");
  eq(chunks[1].startMs === 5000 && chunks[1].endMs === 7000, "chunk 1 spans 5..7s");
  eq(chunks[1].wav.toString("ascii", 0, 4) === "RIFF", "each chunk is a standalone WAV");
  fs.unlinkSync(p);
}

// --- CallSession deltas ---
{
  const b = new TranscriptBuffer();
  const s = new CallSession();
  b.add({ startMs: 0, endMs: 5000, speaker: "them", text: "When will the cache be ready?" });

  const m1 = s.ask(b, 180_000);
  eq(m1.length === 1 && m1[0].role === "user", "first ask -> single user turn");
  eq(m1[0].content.includes("TRANSCRIPT SO FAR"), "first turn carries the full transcript");
  s.recordAnswer("The cache will be ready on Friday.");

  b.add({ startMs: 6000, endMs: 9000, speaker: "them", text: "And what are the risks?" });
  const m2 = s.ask(b, 180_000, "deep");
  eq(m2.length === 3, "second ask -> user/assistant/user");
  eq(m2[2].content.includes("SINCE MY LAST QUESTION"), "later turns send only the delta");
  eq(m2[2].content.includes("And what are the risks?"), "delta contains the new speech");
  eq(!m2[2].content.includes("When will the cache be ready?"), "delta excludes already-sent speech");
  eq(m2[2].content.includes("DEEP mode"), "deep ask carries the DEEP marker");
  eq(m1[0].content.includes("FAST mode"), "default ask carries the FAST marker");
  eq(s.qaCount === 1, "qaCount counts recorded answers");

  s.reset();
  eq(s.messages.length === 0 && s.qaCount === 0, "reset clears the session");
}

// --- Typed input: questions and notes ride in the turn, not the system prompt ---
{
  const b = new TranscriptBuffer();
  const s = new CallSession();
  b.add({ startMs: 0, endMs: 5000, speaker: "them", text: "Tell me about the queues." });

  const typed = s.ask(b, 180_000, "fast", undefined, { typed: "not the queues, the cache" });
  const turn = typed[0].content as string;
  eq(turn.includes("«not the queues, the cache»"), "typed question lands in the turn verbatim");
  eq(turn.includes("TYPED"), "typed question is marked as typed, not transcribed");
  eq(!turn.includes("The hotkey was just pressed"), "typed ask replaces the find-the-question instruction");
  eq(turn.includes("Tell me about the queues."), "typed ask still carries the transcript delta");
  s.recordAnswer("About the cache: ...");

  const noted = s.ask(b, 180_000, "fast", undefined, { notes: ["this is about project X", "do not suggest a rewrite"] });
  const turn2 = noted[2].content as string;
  eq(turn2.includes("- this is about project X") && turn2.includes("- do not suggest a rewrite"),
     "notes are folded into the next turn");
  eq(turn2.includes("NOTES TYPED BY [Me]"), "notes are marked authoritative typed input");
  eq(turn2.includes("The hotkey was just pressed"), "a note does not replace the hotkey instruction");

  const bare = s.ask(b, 180_000);
  eq(!(bare.at(-1)!.content as string).includes("NOTES TYPED"), "no notes -> no notes block");
  s.recordAnswer("...");

  // Scout pulls ride in the turn too — never in the system prompt.
  const pulled = s.ask(b, 180_000, "fast", undefined, {
    pulled: ["=== FILE: pricing.md (scout-pulled mid-call) ===\nPrice: 12k"],
  });
  const turn3 = pulled.at(-1)!.content as string;
  eq(turn3.includes("PACK MATERIAL PULLED MID-CALL") && turn3.includes("Price: 12k"),
     "pulled shelf file lands in the turn under the pack-material heading");
  eq(turn3.includes("Treat it as CALL CONTEXT"), "pulled material is tied to the CALL CONTEXT rules");
  eq(turn3.includes("The hotkey was just pressed"), "a pull does not replace the hotkey instruction");
  s.recordAnswer("...");
  const after = s.ask(b, 180_000);
  eq(!(after.at(-1)!.content as string).includes("PACK MATERIAL"), "a pull is sent once, not repeated");
}

// --- Capture watchdog: frames are the ground truth, silence is not ---
{
  const NOW = 1_000_000;
  const STALL = 8_000;
  eq(trackHealth(0, NOW, STALL) === "off", "never a frame -> off");
  eq(trackHealth(NOW, NOW, STALL) === "live", "frame just now -> live");
  // A pause in the conversation still produces frames, so 7s of quiet audio
  // must NOT read as a dead capture.
  eq(trackHealth(NOW - 7_000, NOW, STALL) === "live", "quiet but flowing -> still live");
  eq(trackHealth(NOW - 8_001, NOW, STALL) === "stalled", "frames stopped -> stalled");
  eq(trackHealth(NOW - 600_000, NOW, STALL) === "stalled", "long dead -> stalled");
}

// --- Splitting an answer into "say this" and "never say this" ---
{
  const plain = splitAnswer("I would not rename the column in place.");
  eq(plain.spoken.startsWith("I would not"), "no marker -> everything is spoken");
  eq(plain.note === undefined, "no marker -> no note");

  const deeper = splitAnswer("Three steps.\n\nDeeper (if they press): the migration works with both versions.");
  eq(deeper.spoken === "Three steps.", "«Deeper» ends the spoken part");
  eq(deeper.note === "the migration works with both versions.", "text trailing the marker is kept");
  eq(!deeper.note?.includes("Deeper"), "the marker line itself is dropped");

  const nextLine = splitAnswer("Spoken.\n\nDeeper:\nfirst line\nsecond line");
  eq(nextLine.note === "first line\nsecond line", "note continues onto later lines");

  const foot = splitAnswer("Spoken.\n\n---\nraw zone — the data as it came in");
  eq(foot.spoken === "Spoken.", "`---` ends the spoken part");
  eq(foot.note === "raw zone — the data as it came in", "footnotes land in the note");

  eq(splitAnswer("Spoken.\n\nDEEPER: X").note === "X", "marker match is case-insensitive");
  // A stray "deeper" mid-sentence must not eat the answer.
  eq(splitAnswer("I would dig deeper: check the logs.").note === undefined, "inline «deeper» is not a marker");

  // The `→` line: the model restating which question it picked.
  const read = splitAnswer("→ migrating the schema with no downtime\n\nThree steps.\n\nDeeper: X");
  eq(read.reading === "migrating the schema with no downtime", "arrow line lands in reading");
  eq(read.spoken === "Three steps.", "spoken starts after the arrow line");
  eq(read.note === "X", "note still splits after a reading");
  eq(plain.reading === undefined, "no arrow -> no reading");
  // Mid-stream the arrow line may be all that has arrived so far.
  const partial = splitAnswer("→ about the indexes in");
  eq(partial.reading === "about the indexes in" && partial.spoken === "", "arrow-only stream -> nothing spoken yet");
  // An arrow anywhere but line one is content, not a marker.
  eq(splitAnswer("See: A → B.").reading === undefined, "inline arrow is not a marker");
}

// --- Attached context lands in the SYSTEM prompt ---
// It used to ride in the first user turn, where a "here is what I have NOT
// done" section read as background and got bluffed straight over.
{
  const cfg = loadConfig();
  const bare = buildSystemPrompt(cfg);
  eq(!bare.includes("## CALL CONTEXT"), "no context -> no CALL CONTEXT section");

  const withCtx = buildSystemPrompt(cfg, ["No production experience: Spark.", "Second block."]);
  eq(withCtx.includes("## CALL CONTEXT"), "context -> CALL CONTEXT section");
  eq(withCtx.includes("No production experience: Spark."), "context text is verbatim");
  eq(withCtx.includes("Second block."), "every attached block is included");
  eq(withCtx.startsWith(bare), "context is appended, the base prompt is intact");
}

// --- Segmenter (pause-based cutting) ---
{
  const BYTES_PER_MS = 32;
  const speech = (ms: number) => {
    const b = Buffer.alloc(ms * BYTES_PER_MS);
    for (let i = 0; i < b.length / 2; i++) {
      b.writeInt16LE(Math.round(3000 * Math.sin(i / 3)), i * 2);
    }
    return b;
  };
  const silence = (ms: number) => Buffer.alloc(ms * BYTES_PER_MS);

  eq(rms(speech(100)) > 1000 && rms(silence(100)) === 0, "rms separates speech from silence");

  const opts = { silenceMs: 600, silenceRms: 350, minSpeechMs: 700, maxChunkMs: 6000 };

  // Cut at a natural pause
  const s1 = new Segmenter(opts);
  let cut = null;
  for (let i = 0; i < 10 && !cut; i++) cut = s1.push(speech(100)); // 1s speech
  eq(cut === null, "no cut while speech continues");
  for (let i = 0; i < 6 && !cut; i++) cut = s1.push(silence(100)); // 600ms pause
  eq(cut !== null && cut!.startMs === 0 && cut!.endMs === 1600, "cuts at a natural pause (1s speech + 0.6s silence)");
  eq(cut!.wav.toString("ascii", 0, 4) === "RIFF", "emitted chunk is a standalone WAV");

  // Hard cap mid-speech
  const s2 = new Segmenter(opts);
  cut = null;
  let pushes = 0;
  while (!cut && pushes < 100) {
    cut = s2.push(speech(100));
    pushes++;
  }
  eq(cut !== null && cut!.endMs === 6000, "hard cap cuts at maxChunkMs mid-speech");

  // Leading silence is skipped, timeline stays correct
  const s3 = new Segmenter(opts);
  for (let i = 0; i < 20; i++) s3.push(silence(100)); // 2s dead air
  for (let i = 0; i < 10; i++) s3.push(speech(100));
  const f = s3.flush();
  eq(f !== null && f!.startMs === 2000 && f!.endMs === 3000, "leading silence skipped; chunk timed at 2..3s");

  // Flush with nothing meaningful buffered
  const s4 = new Segmenter(opts);
  s4.push(silence(100));
  eq(s4.flush() === null, "flush on silence-only buffer emits nothing");
}

// --- FrameParser (helper stdout protocol) ---
{
  const frame = (source: number, payload: Buffer | string): Buffer => {
    const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, "utf8");
    const header = Buffer.alloc(8);
    header[0] = source;
    header.writeUInt32LE(body.length, 4);
    return Buffer.concat([header, body]);
  };
  const pcm = (byte: number, len: number) => Buffer.alloc(len, byte);

  // Several frames in one read
  {
    const p = new FrameParser();
    const out = p.push(
      Buffer.concat([
        frame(SOURCE.me, pcm(1, 64)),
        frame(SOURCE.them, pcm(2, 32)),
        frame(SOURCE.control, '{"event":"call_start"}'),
      ]),
    );
    eq(out.length === 3, "parses three frames from one read");
    eq(out[0].kind === "audio" && out[0].source === SOURCE.me && out[0].pcm.length === 64, "first frame is 64B of mic PCM");
    eq(out[1].kind === "audio" && out[1].source === SOURCE.them, "second frame is system audio");
    eq(out[2].kind === "control" && out[2].event === "call_start", "third frame is the call_start control event");
  }

  // A frame split across reads — including a split header
  {
    const p = new FrameParser();
    const whole = frame(SOURCE.them, pcm(7, 100));
    eq(p.push(whole.subarray(0, 3)).length === 0, "partial header yields nothing yet");
    eq(p.push(whole.subarray(3, 20)).length === 0, "partial payload yields nothing yet");
    const out = p.push(whole.subarray(20));
    eq(out.length === 1 && out[0].kind === "audio" && out[0].pcm.length === 100, "frame reassembled across three reads");
    eq(out[0].kind === "audio" && out[0].pcm.every((b) => b === 7), "reassembled payload bytes are intact");
  }

  // Hotkey control frames carry the mode
  {
    const p = new FrameParser();
    const out = p.push(
      Buffer.concat([
        frame(SOURCE.control, '{"event":"hotkey","mode":"fast"}'),
        frame(SOURCE.control, '{"event":"hotkey","mode":"deep"}'),
      ]),
    );
    const modes = out.map((f) => (f.kind === "control" ? f.mode : null));
    eq(modes.join(",") === "fast,deep", "hotkey frames carry fast/deep modes");
  }

  // Robustness: malformed control JSON and unknown sources must not stall audio
  {
    const p = new FrameParser();
    const out = p.push(
      Buffer.concat([
        frame(SOURCE.control, "{not json"),
        frame(9, pcm(3, 16)), // unknown source
        frame(SOURCE.me, pcm(4, 48)),
      ]),
    );
    eq(out.length === 1 && out[0].kind === "audio" && out[0].pcm.length === 48, "malformed control + unknown source skipped, audio still delivered");
  }

  // A bogus length field must fail loudly instead of buffering forever
  {
    const p = new FrameParser();
    const bogus = Buffer.alloc(8);
    bogus[0] = SOURCE.me;
    bogus.writeUInt32LE(0x7fff_ffff, 4);
    let threw = false;
    try {
      p.push(bogus);
    } catch {
      threw = true;
    }
    eq(threw, "implausible payload length throws instead of growing the buffer");
    const after: HelperFrame[] = p.push(frame(SOURCE.me, pcm(5, 16)));
    eq(after.length === 1, "parser keeps working on fresh frames after a desync");
  }

  // The shelf on project_context frames: JSON-encoded by the Swift side,
  // which can only send string fields
  {
    const p = new FrameParser();
    const out = p.push(
      Buffer.concat([
        frame(SOURCE.control, '{"event":"project_context","text":"ctx","shelf":"[\\"/a.md\\",\\"/b.txt\\"]"}'),
        frame(SOURCE.control, '{"event":"project_context","shelf":["/c.md"]}'),
        frame(SOURCE.control, '{"event":"project_context","shelf":"{not json"}'),
        frame(SOURCE.control, '{"event":"project_context","shelf":"[1,2]"}'),
      ]),
    );
    const shelves = out.map((f) => (f.kind === "control" ? f.shelf : undefined));
    eq(shelves[0]?.join(",") === "/a.md,/b.txt", "JSON-encoded shelf string decodes to paths");
    eq(shelves[1]?.join(",") === "/c.md", "a raw shelf array is accepted too");
    eq(out.length === 4 && shelves[2] === undefined && shelves[3] === undefined,
       "malformed shelf reads as absent without dropping the frame");
  }
}

// --- Scout: parsing the picker model's reply ---
{
  const shelf = ["pricing.md", "architecture.md", "faq.txt"];
  eq(parseScoutReply('{"files": ["pricing.md"]}', shelf).join(",") === "pricing.md",
     "clean JSON reply -> the picked file");
  eq(parseScoutReply('Sure!\n```json\n{"files": ["faq.txt", "architecture.md"]}\n```', shelf).join(",")
       === "faq.txt,architecture.md",
     "fenced JSON wrapped in prose still parses");
  eq(parseScoutReply("no json here at all", shelf).length === 0, "garbage -> empty, never a throw");
  eq(parseScoutReply('{"files": "pricing.md"}', shelf).length === 0, "non-array files field -> empty");
  eq(parseScoutReply('{"files": ["invented.md", "pricing.md"]}', shelf).join(",") === "pricing.md",
     "an invented name is filtered, the real one survives");
  eq(parseScoutReply('{"files": []}', shelf).length === 0, "empty pick list -> empty");
  eq(parseScoutReply('{"files": ["pricing.md", "pricing.md"]}', shelf).join(",") === "pricing.md",
     "duplicate picks collapse to one");
}

// --- Scout: the injection ledger ---
{
  const led = new ScoutLedger(1000, 120_000);
  const T = 1_000_000;
  eq(led.canInject(T), "fresh ledger allows the first injection");
  eq(led.remainingChars() === 1000, "fresh ledger holds the full budget");
  led.recordInjection(T, 400);
  eq(!led.canInject(T + 60_000), "injection inside the gap is blocked");
  eq(led.canInject(T + 120_000), "gap elapsed -> allowed again");
  eq(led.remainingChars() === 600, "budget shrinks by the injected chars");
  led.recordInjection(T + 120_000, 700);
  eq(led.remainingChars() === 0, "an overrun clamps remaining to zero, never negative");
  led.reset();
  eq(led.canInject(T + 120_001) && led.remainingChars() === 1000,
     "reset restores both the gap and the budget");
}

// --- pricing ---
{
  const base = { cacheReadTokens: 0, cacheWriteTokens: 0, provider: "anthropic" };

  // 1M in + 1M out on Opus 5 = $5 + $25
  const full = price({ ...base, inputTokens: 1_000_000, outputTokens: 1_000_000, model: "claude-opus-5" });
  eq(full.cost === 30, `1M in + 1M out on opus-5 costs $30 (got ${full.cost})`);

  // Cache reads bill at a tenth of input: 1M cache-reads = $0.50
  const cached = price({ ...base, inputTokens: 0, outputTokens: 0, cacheReadTokens: 1_000_000, model: "claude-opus-5" });
  eq(Math.abs((cached.cost ?? 0) - 0.5) < 1e-9, `1M cache-reads cost $0.50 (got ${cached.cost})`);

  // Cache writes bill at 1.25x input: 1M writes = $6.25
  const written = price({ ...base, inputTokens: 0, outputTokens: 0, cacheWriteTokens: 1_000_000, model: "claude-opus-5" });
  eq(Math.abs((written.cost ?? 0) - 6.25) < 1e-9, `1M cache-writes cost $6.25 (got ${written.cost})`);

  // 1-hour cache writes bill at 2x input: 1M 1h-writes = $10, and a mixed
  // report prices each part at its own rate.
  const hour = price({ ...base, inputTokens: 0, outputTokens: 0, cacheWriteTokens: 1_000_000, cacheWrite1hTokens: 1_000_000, model: "claude-opus-5" });
  eq(Math.abs((hour.cost ?? 0) - 10) < 1e-9, `1M 1h cache-writes cost $10 (got ${hour.cost})`);
  const mixed = price({ ...base, inputTokens: 0, outputTokens: 0, cacheWriteTokens: 1_000_000, cacheWrite1hTokens: 400_000, model: "claude-opus-5" });
  eq(Math.abs((mixed.cost ?? 0) - (0.6 * 6.25 + 0.4 * 10)) < 1e-9, `mixed 5m/1h writes price per part (got ${mixed.cost})`);

  // An unknown model must return null, never a guessed number
  const unknown = price({ ...base, inputTokens: 1000, outputTokens: 1000, model: "some-future-model" });
  eq(unknown.cost === null, "unknown model prices to null instead of guessing");

  // ...unless the rate is supplied via env
  const priced = price(
    { ...base, inputTokens: 1_000_000, outputTokens: 0, model: "gpt-5.1", provider: "openai" },
    { PRICE_GPT_5_1_IN: "2", PRICE_GPT_5_1_OUT: "10" } as NodeJS.ProcessEnv,
  );
  eq(priced.cost === 2, `env-supplied rate is used (got ${priced.cost})`);

  // The local CLI runs on a subscription — no metered charge
  const cli = price({ ...base, inputTokens: 9999, outputTokens: 9999, model: "sonnet", provider: "claude-cli" });
  eq(cli.cost === 0, "claude-cli prices to zero (subscription, not metered)");

  eq(formatCost(0) === "$0", "formatCost: zero");
  eq(formatCost(0.00412) === "$0.0041", `formatCost: sub-cent keeps 4 dp (got ${formatCost(0.00412)})`);
  eq(formatCost(1.5) === "$1.50", `formatCost: dollars keep 2 dp (got ${formatCost(1.5)})`);
}

// --- usage tracker: day totals + the per-call ledger ---
{
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "livecall-usage-"));
  const T = new Date("2026-09-02T14:00:00Z");
  const clock = { t: T.getTime() };
  const now = () => new Date(clock.t);
  const base = { cacheReadTokens: 0, cacheWriteTokens: 0, provider: "anthropic" };

  const a = new UsageTracker(now, dir);
  a.record({ ...base, inputTokens: 1000, outputTokens: 100, model: "claude-opus-5" }, "answer", "fast");
  clock.t += 40_000;
  a.record({ ...base, inputTokens: 500, outputTokens: 10, model: "claude-haiku-4-5" }, "scout");
  eq(a.summary().today.calls === 2, "day total counts answers and scout ticks alike");

  const led = readLedger(dir);
  eq(led.length === 2, `ledger has one line per call (got ${led.length})`);
  eq(led[0].kind === "answer" && led[0].mode === "fast" && led[0].at === "2026-09-02T14:00:00.000Z",
     "answer line carries kind, mode and a UTC timestamp");
  eq(led[1].kind === "scout" && led[1].mode === undefined && led[1].model === "claude-haiku-4-5",
     "scout line carries kind and model, no mode");
  eq(Math.abs((led[0].cost ?? 0) - 0.0075) < 1e-9, `ledger line is priced (got ${led[0].cost})`);

  // A relaunch the same day picks the totals up; the ledger keeps growing.
  const b = new UsageTracker(now, dir);
  eq(b.summary().today.calls === 2, "day totals survive a restart");
  b.record({ ...base, inputTokens: 1, outputTokens: 1, model: "claude-opus-5" });
  eq(readLedger(dir).length === 3, "ledger appends across instances");

  // A torn last line (crash mid-append) hides nothing but itself.
  fs.appendFileSync(path.join(dir, "usage.jsonl"), '{"at":"2026-09-02T15:00:00Z","mod');
  eq(readLedger(dir).length === 3, "torn trailing line is skipped, the rest still reads");

  // Missing ledger is an empty history, not an error.
  eq(readLedger(path.join(dir, "nope")).length === 0, "no ledger yet -> empty list");
  fs.rmSync(dir, { recursive: true, force: true });
}

// --- rate-limit header parsing ---
{
  eq(readRateLimits(undefined) === null, "no headers -> null");
  eq(readRateLimits(new Headers({ "content-type": "application/json" })) === null,
     "headers without ratelimit fields -> null");
  const snap = readRateLimits(new Headers({
    "anthropic-ratelimit-input-tokens-remaining": "18000",
    "anthropic-ratelimit-requests-remaining": "49",
    "anthropic-ratelimit-input-tokens-reset": "2026-07-31T10:00:00Z",
  }));
  eq(snap?.inputTokensRemaining === 18000 && snap?.requestsRemaining === 49,
     "reads remaining input tokens and requests from headers");
  eq(snap?.resetsAt === "2026-07-31T10:00:00Z", "reads the reset timestamp");
}

console.log(ok ? "\nselftest: PASS" : "\nselftest: FAIL");
process.exit(ok ? 0 : 1);
