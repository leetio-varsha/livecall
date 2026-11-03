// Headless front-end for Livecall.app. The app owns capture and
// the hotkeys (so macOS attaches the permission grants to the signed bundle,
// not to a terminal) and drives this process:
//
//   app  → core : the same 8-byte frame protocol as the helper, on STDIN
//                 (source 0/1 = PCM, source 2 = JSON control frame)
//   core → app  : one JSON object per line on STDOUT
//
// STDOUT is the protocol — everything human-readable goes to stderr.
//
//   node src/ipc.ts

import { loadConfig, type AnswerMode } from "./config.ts";
import { FrameParser, SOURCE, type ControlFrame, type HelperFrame } from "./frames.ts";
import { Engine } from "./engine.ts";

const cfg = loadConfig();

function emit(event: Record<string, unknown>): void {
  process.stdout.write(JSON.stringify(event) + "\n");
}

const engine = new Engine(cfg, {
  onNotice: (text) => emit({ type: "notice", text }),
  onAudioHealth: (h) => emit({ type: "audio_health", me: h.me, them: h.them }),
  onSessionReset: (reason) => emit({ type: "session_reset", reason }),
  onTranscript: (seg) => emit({ type: "transcript", ...seg }),
  onBusy: (i) => emit({ type: "busy", ...i }),
  onQueued: (i) => emit({ type: "typed_queued", ...i }),
  onNoteAdded: (chars) => emit({ type: "note_added", chars }),
  onAskStart: (i) => emit({ type: "ask_start", ...i }),
  onFirstToken: (ms, i) => emit({ type: "first_token", ms, ...i }),
  onAnswerToken: (text) => emit({ type: "answer_delta", text }),
  onAnswerDone: (i) =>
    emit({
      type: "answer_done",
      ...i,
      // Flattened so the Swift side doesn't need nested decoding.
      spend: i.usage?.line,
      spendToday: i.usage?.today.cost,
      calls: i.usage?.today.calls,
      inputTokensRemaining: i.rateLimits?.inputTokensRemaining,
      outputTokensRemaining: i.rateLimits?.outputTokensRemaining,
    }),
  onDelivered: (target, ok, error) => emit({ type: "delivered", target, ok, error }),
  onAnswerError: (message, i) => emit({ type: "answer_error", message, ...i }),
  onScoutPulled: (files, chars) => emit({ type: "scout_pulled", files, chars }),
});

try {
  const loadMs = await engine.start();
  emit({
    type: "ready",
    loadMs: Math.round(loadMs),
    backend: cfg.llm.backend,
    model: cfg.llm.backend === "api" ? cfg.llm.fast.model : cfg.llm.cliModel,
    telegram: engine.telegramReady,
    silent: cfg.silent,
  });
} catch (e) {
  emit({ type: "fatal", message: (e as Error).message });
  process.exit(1);
}

const parser = new FrameParser();
process.stdin.on("data", (chunk: Buffer) => {
  let frames: HelperFrame[];
  try {
    frames = parser.push(chunk);
  } catch (e) {
    emit({ type: "fatal", message: `frame stream broken: ${(e as Error).message}` });
    shutdown(1);
    return;
  }
  for (const f of frames) {
    if (f.kind === "audio") engine.feed(f.source === SOURCE.me ? "me" : "them", f.pcm);
    else onControl(f);
  }
});

// The app closing our stdin is the normal way to say "stop".
process.stdin.on("end", () => shutdown(0));

function onControl(frame: ControlFrame): void {
  switch (frame.event) {
    case "hotkey": {
      const mode: AnswerMode = frame.mode === "deep" ? "deep" : "fast";
      void engine.ask(mode, frame.shot ? "screen" : "hotkey", frame.shot);
      break;
    }
    case "ask": {
      const mode: AnswerMode = frame.mode === "deep" ? "deep" : "fast";
      void engine.ask(mode, "menu");
      break;
    }
    case "typed":
      // Text typed into the panel. mode "note" = remember silently for the
      // next answer; anything else = answer the typed text right now.
      if (frame.text?.trim()) {
        if (frame.mode === "note") {
          engine.addNote(frame.text);
        } else {
          const mode: AnswerMode = frame.mode === "deep" ? "deep" : "fast";
          void engine.ask(mode, "typed", undefined, frame.text.trim());
        }
      }
      break;
    case "call_start":
      engine.newCall("call detected");
      break;
    case "call_end":
      emit({ type: "call_end" });
      break;
    case "reset":
      engine.newCall("manual reset");
      break;
    case "context":
      if (frame.text) {
        engine.addContext(frame.text);
        // `chars` is the engine's own total, not the app's — it is proof the
        // text reached the system prompt, not just the IPC socket.
        emit({ type: "context_added", text: frame.text, chars: engine.contextChars });
      }
      break;
    case "project_context":
      // Replace semantics — the app re-sends the active project's files fresh
      // on every call start (and clears with empty text on deselect). The
      // shelf rides in the same frame, so both slots stay in sync: a cleared
      // project must not leave the scout holding the old project's files.
      engine.setProjectShelf(frame.shelf ?? []);
      engine.setProjectContext(frame.text ?? "");
      emit({
        type: "project_context_set",
        chars: (frame.text ?? "").trim().length,
        shelfFiles: (frame.shelf ?? []).length,
      });
      break;
    case "quit":
      shutdown(0);
      break;
    case "usage":
      void engine.usageWithBilling().then((u) =>
        emit({
          type: "usage",
          line: u.line,
          today: u.today.cost,
          calls: u.today.calls,
          partial: u.today.partial,
          billedToday: u.billedToday,
          billingError: u.billingError,
          telegram: engine.telegramReady,
        }),
      );
      break;
    case "telegram_test":
      void engine.testTelegram().then((r) =>
        emit({ type: "telegram_test_result", ok: r.ok, error: r.error }),
      );
      break;
    default:
      break; // forward-compatible: unknown events are not errors
  }
}

let shuttingDown = false;

function shutdown(code: number): void {
  if (shuttingDown) return;
  shuttingDown = true;
  engine.stop();
  process.exit(code);
}

for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
  process.on(sig, () => shutdown(0));
}
