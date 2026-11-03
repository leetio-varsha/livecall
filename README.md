# Livecall — a real-time call copilot for macOS

A menu-bar app for demos, client calls and technical discussions. It
transcribes both sides of the call on-device (whisper.cpp, Metal), takes
briefing context from your own docs, and on a global hotkey streams a short,
speakable answer to whatever was just asked — into a floating panel that never
steals focus from the call.

Audio never leaves the machine. The only remote call is the answer request,
and it carries transcript text, never audio.

## What it does

- **Hears both sides.** Microphone = `[Me]`, system audio = `[Them]`, as two
  separate tracks, so the transcript knows who said what.
- **Knows when a call starts.** Watches which other processes hold the mic;
  a new call starts a fresh session automatically.
- **Answers on a hotkey.** A tap of right ⌥ sends the transcript plus your
  briefing to Claude and streams the answer back. ⇧ + right ⌥ asks for a
  thorough one. Left ⌥ attaches a screenshot of the call window to the
  question.
- **Reads your briefing.** Attach a spec, a proposal, meeting notes — or a
  whole folder. Checked files go into every request; unchecked ones sit on a
  shelf and a small "scout" model pulls them in when their topic comes up.
- **Keeps answers speakable.** Short, one idea first, no jargon the other
  side has not used, and a separate "do not read aloud" zone for follow-up
  material and corrections to your own numbers.

## How the capture works

This is the part that took the longest to get right.

**Two tracks, one stream.** A Swift helper captures the microphone through an
`AVAudioEngine` input tap and the remote participants through a
ScreenCaptureKit audio-only stream (our own process audio excluded, the video
stream kept tiny and unconsumed). Both are converted to 16 kHz mono PCM and
written to the core as length-prefixed frames tagged `me` / `them`. The same
sources compile into both the menu-bar app and a standalone CLI helper.

**Chunking at pauses, not on a timer.** The core cuts a chunk when at least
700 ms of speech is followed by 600 ms of quiet (RMS below a threshold), with a
hard cap of 6 s. Each chunk goes to `whisper-server`, which keeps the model
resident in memory, so a chunk costs inference only — no multi-gigabyte model
reload per request, which is what makes spawning `whisper-cli` per file
unusable for real time. Silero VAD runs inside whisper so silence and
breathing do not turn into hallucinated words; a repetition guard collapses
the "same phrase 200 times" loops whisper occasionally produces on noisy
input.

**The hotkey flushes first.** When you press the hotkey, the chunk that is
still being recorded is cut and transcribed before the question is assembled,
so the answer is about the sentence that was just said, not the one before
it. The budget for hotkey → first visible token is under 2 s on the API
backend.

**Call detection.** The per-process Core Audio HAL (macOS 14.4+) reports which
processes run audio input on a real input device. Tap-based listeners that
analyse playback (`corespeechd`) report no device and are ignored, as are
daemons our own capture spins up (`replayd`) and a second copy of the app
during a rebuild-and-relaunch. Anything else holding the mic is a call:
session reset on start, 5 s debounce on end. Add your own exclusions with
`DETECT_EXCLUDE=Loom,Slack`.

**Capture that stays alive.** `AVAudioEngine` stops itself on a configuration
change — a Bluetooth headset switching to hands-free mode, a sample-rate
change — and does not throw. The helper observes the notification and
rebuilds the tap, with the one ObjC call that can raise an exception wrapped
so it returns an error instead of taking the app down mid-call. A watchdog
in the core treats frames as the ground truth: a track that delivers nothing
for 8 s is marked stalled, and the panel says so in the place you are already
looking. "Started successfully once" earns no checkmark.

**Hotkeys that take nothing away.** A CGEventTap in the helper catches the
keys while Zoom or Meet stays in front. A modifier *tap* only counts when the
key goes down and up with nothing in between — no keystroke, no click, no
scroll — and within 400 ms, so holding ⌥ as a modifier never fires and
⌥+letter input keeps working. Combos (`opt+cmd+a`, `f13`) are swallowed so
the call app never sees them. The tap compares key codes and modifiers only;
nothing is buffered or logged.

## Privacy

- Transcription is local: whisper.cpp with Metal on this Mac.
- The answer request sends transcript text and your briefing text to the
  Anthropic API (or OpenAI, only if you configure it as a fallback). Never
  audio.
- Screenshots are taken only on the dedicated screen hotkey, aimed at the
  call window, and the app's own windows are always excluded.
- Permissions attach to the signed app bundle, not to your terminal, so your
  terminal never holds the right to see keystrokes system-wide.
- Telegram delivery, if you turn it on, goes through a bot you own.

## Setup

Requirements: Apple Silicon Mac on macOS 14.4+, Xcode command line tools
(`swiftc`, `xcrun`), Node 23.6+ (TypeScript runs without a build step),
`ffmpeg` for the sample script, and a [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
build with `whisper-server`, the `large-v3` model and the Silero VAD model.
`core/.env.example` assumes whisper.cpp lives in `~/whisper.cpp`.

```bash
cd core && npm install && cp .env.example .env   # set ANTHROPIC_API_KEY, paths
cd .. && ./app/build.sh                          # builds app/build/Livecall.app
open app/build/Livecall.app
```

The build script needs no Xcode project: it compiles the sources with
`swiftc`, assembles the bundle and signs it. Sign with a stable identity
(an "Apple Development" certificate, or a self-signed "Livecall Self-Signed"
code-signing certificate from Keychain Access) — ad-hoc signing changes the
app's identity on every rebuild, and macOS asks for all four permissions
again. `SKIP_INSTALL=1` builds without copying into `/Applications`.

On first launch open **Permissions & setup…** from the menu-bar icon: it
shows the live state of Microphone, Screen Recording, Accessibility and Input
Monitoring, each with a button to the exact Settings pane, plus node and
API-key checks. After granting a permission, quit and relaunch — macOS
re-reads some of them only at launch.

Diagnostics that need neither GUI nor permissions:

```bash
app/build/Livecall.app/Contents/MacOS/Livecall --core-selftest   # app ↔ core path
app/build/Livecall.app/Contents/MacOS/Livecall --panel-selftest  # panel builds & shows
open -a Livecall --args --tcc-report && cat ~/Library/Logs/Livecall-tcc-report.txt
```

Run the TCC report via `open`, not from a shell: a binary started from a
terminal inherits the terminal's *responsible process*, so the keyboard
grants would report the terminal's permissions instead of the app's.

### Terminal mode

The same capture code runs as a CLI helper with a REPL front-end, which is
handy for development and for replaying recordings:

```bash
./helper/build.sh                               # builds helper/build/livecall-helper
cd core && node src/live.ts                     # live capture
node src/live.ts --replay ../samples/call.wav --rate 4   # same path, no mic needed
./samples/make-call.sh                          # generates a fake call with macOS `say`
```

REPL: `Enter` = quick answer, `/deep` = thorough answer, `/ctx <text>` = add
context, `/reset` = new call, `/q` = quit. Flags: `--no-mic --no-system
--no-detect --no-hotkey`. In terminal mode the permission grants attach to
the terminal app, which is exactly what the menu-bar app exists to avoid.

## Usage

1. Start Livecall two or three minutes early. The model takes 30–40 s to
   load; the menu status reads `mic ✓ · system ✓ · hotkeys ✓` once frames
   are actually arriving.
2. Press the FAST hotkey once before the call. If the panel answers, the whole
   chain is alive. Then **New call** to start clean.
3. On the call: right ⌥ for a quick answer, ⇧ + right ⌥ for a thorough one,
   left ⌥ to ask about what is on screen. The panel streams the answer, shows
   first-token and total latency, and copies with one click.
4. The panel's text field takes typed input: ⏎ asks (or corrects the question
   the model picked), ⌥⏎ notes something silently for the next answer.
5. ‹ › pages through earlier answers; paging back is visibly a different
   mode so a stale answer is never read out as a fresh one.

Every answer opens with a `→ …` line restating the question the model
picked. That line is how you catch a wrong pick before reading the wrong
answer aloud.

Hotkeys are configured in `.env`, two spec styles:

- **tap** — `ropt`, `lopt`, `rcmd`, `lcmd`, `rctrl`, optionally `shift+…`.
  Never swallowed.
- **combo** — `opt+cmd+a`, `shift+opt+cmd+a`, `f13`. Swallowed.

## Briefing context

**Add call context…** opens an editor: paste text, or attach briefing notes —
a PDF, txt, md or rtf: a spec, a proposal, meeting notes, a pricing sheet.
PDFs are read with PDFKit; a scanned PDF has no text layer and is rejected
with a clear message rather than silently adding nothing (there is no OCR).

Attach a **folder** and you get a checklist: checked files are the core and
go into every request; unchecked files become the **shelf**. A small scout
model watches the transcript and pulls a shelf file into the conversation
when its topic comes up (judged by filename, `.md`/`.txt` only, at most once
every two minutes). **Save as project** remembers the selection; an armed
project re-reads its files from disk at every call start, so you can edit
the briefing up to the last minute. A file that vanished between saving and
the call is reported, never skipped silently.

Context goes into the **system prompt**, not into the first user turn, so a
section like "Not built yet — do not claim" is read as an instruction rather
than as background chatter. It also survives a session reset: re-detecting
the mic restarts the transcript, not your briefing. To see exactly what the
model will receive:

```bash
npm run prompt -- my-briefing.md          # the full assembled system prompt
npm run prompt -- my-briefing.md --stats  # sizes only
```

Being in the system prompt means it is included in **every** hotkey press for
the rest of the call, so the window shows what it will cost before you
commit. Anything past `CONTEXT_MAX_CHARS` (default 60,000) is trimmed, and the
window says how much was dropped. See [BRIEFING.md](BRIEFING.md) for how to
write a briefing pack the app makes the most of.

## Answer modes and backends

- **FAST** — effort low, thinking off, 1024 tokens. An instant pointer for
  short questions; this is what the < 2 s budget is about.
- **DEEP** — effort high, adaptive thinking, 4096 tokens. For "how would you
  build X" questions, where a few seconds buy a structured answer with
  trade-offs. Both modes share one cached system prompt and one session.

Backends form a fallback chain, `anthropic api → openai → claude-cli`; each
attempt is abandoned if the provider sends nothing within
`LLM_FIRST_EVENT_TIMEOUT_MS` (default 6 s).

- `api` — Anthropic API, streaming. Needs `ANTHROPIC_API_KEY`.
- `openai` — optional cross-provider insurance, used only when the Anthropic
  attempt fails. Needs `OPENAI_API_KEY`.
- `claude-cli` — reuses a local Claude Code login; the primary when there is
  no API key. Works, but CLI startup adds 2–4 s.

## Telegram and silent mode

Finished answers can be pushed to Telegram, and **Silent** mode (menu bar, or
`SILENT_MODE=1`) stops the panel from appearing at all — for calls where a
window popping up on a shared screen is the problem.

Setup is a **bot**, deliberately, not your account session: a bot token can
only post into chats the bot is already in, so a leak means "someone can
message you" rather than full account access. `@BotFather` → `/newbot` →
`TELEGRAM_BOT_TOKEN`; open the bot and press **Start**; `TELEGRAM_CHAT_ID`
is your own user id. **Permissions & setup…** has a *Send test* button.
Delivery is best-effort and never delays the answer on screen.

## Cost controls

The menu shows the last answer's cost and a running total for the day,
computed from the real token counts in each API response times the published
rates — cache reads at 0.1x, cache writes at 1.25x (5-minute cache) or 2x
(1-hour cache, the default). The day total persists across restarts.

The prompt cache is what makes a long call affordable: the briefing, the
transcript and every previous answer are read back at a tenth of the price on
each press. It holds only while it is used, so `CACHE_TTL` matters more than
any rate: `1h` survives the pauses a real call is made of; `5m` is a little
cheaper for a short, dense session where the key is pressed every couple of
minutes. A pause longer than the TTL, or switching FAST↔DEEP (a change of
thinking or effort invalidates the cached prefix), pays the write again.
Shelf files the scout pulls mid-call ride in the next turn, not the system
prompt, precisely so a pull does not.

Every request is appended to
`~/Library/Application Support/Livecall/usage.jsonl` — timestamp, answer or
scout, mode, model, the four token counts and the cost:

```bash
npm run spend                 # one line per day on record
npm run spend -- 2026-09-02   # that day request by request, with cache share
```

There is deliberately no "balance" figure: no Anthropic or OpenAI endpoint
reports remaining credit on a key. Optionally, `ANTHROPIC_ADMIN_KEY` adds
Anthropic's own billed figure next to the local estimate (organization
accounts only). Models without a built-in rate report tokens only — supply
`PRICE_<MODEL>_IN` / `_OUT` to price them.

## Layout

| Part | Role |
| --- | --- |
| `app/` | `Livecall.app` — menu bar, answer panel, briefing window, spawns the core |
| `helper/` | capture, call detection, hotkeys, screenshots — shared Swift sources, also built as a CLI |
| `core/src/engine.ts` | the pipeline: PCM in, answers out |
| `core/src/ipc.ts` | app front-end (frames on stdin, JSON events on stdout) |
| `core/src/live.ts` | terminal front-end (REPL, spawns the helper) |
| `core/prompts/answer.md` | the system prompt |

```bash
cd core && npm test    # pure-logic self-tests (no whisper, no network)
```

The capture approach, the anti-hallucination guards and the api / claude-cli
backend pattern are shared with [Echo](https://github.com/leetio-varsha/echo),
a dictation app for macOS.

## License

MIT — see [LICENSE](LICENSE).
