# BRIEFING.md — how to prepare a briefing pack

A briefing pack is a folder you attach in **Add call context…** before a
demo, a client call or a technical discussion. This file describes what to
put in it so the app makes the most of it. If a rule here contradicts what
the app does, the app wins and this file has a bug.

## How the app consumes a pack

| Mechanic | What it means for the pack |
|---|---|
| `BRIEFING.md` is pre-checked by filename when a folder is attached | The one file that should always exist: the briefing core |
| Context cap is 60,000 characters; over the cap blocks Add | Keep the checked core at ≤ ~45k characters, leaving headroom for ad-hoc additions |
| Rough token cost: ~4 characters per token for Latin text, ~2 for Cyrillic | Terse beats prose; numbers beat sentences |
| An armed project re-reads its files from disk at every call start | Edit the pack up to the last minute; never keep "final" copies elsewhere |
| Unchecked files become the **shelf**: a scout model watches the transcript and pulls a shelf file in when its topic comes up | Put "might come up" material on the shelf, not in the core |
| The scout judges shelf files **by filename only**, pulls `.md`/`.txt` only, at most 30k characters per call, not more often than every 2 minutes | Name shelf files by topic (`pricing-tiers.md`, not `notes2.md`); no PDFs on the shelf |
| Everything after a `---` line or a `Deeper (if they press):` line is shown but never meant to be spoken | Put for-eyes-only material behind those markers in any example answers |
| Every answer opens with a `→ <question as understood>` line | Nothing to prepare, but expect it |
| Answers follow the FAST pyramid: one sentence that stands alone, ≤ 3 supporting sentences, a hook | Write facts so the first sentence is extractable: number first, then context |
| Questions needing more than ~4 items or a table are treated as requests for a written artifact | List in `MAP.md` where each such artifact would live |
| When [Me] misstates a number against the context, the next answer opens its note block with a correction | Every number in the pack must be **verified and dated** — a wrong pack number becomes a confident wrong correction |
| A section listing what has NOT been built, measured or done is a hard constraint | Always include it; it is the highest-value section in the pack |

## Pack layout

```
<project>-<calltype>-<YYYY-MM-DD>/
  BRIEFING.md   the briefing core (always checked, see below)
  ...           type-specific files (table below)
  shelf files   everything useful-but-unlikely, named by topic
```

`BRIEFING.md` structure, in order:

1. **Header** — one paragraph: who is on the call, what it is about, what
   [Me] wants out of it. This feeds the "what is this about" press when no
   explicit question was asked; without it that press has nothing to stand
   on.
2. **Answer protocol** — the per-call-type behaviour lines (table below).
   The context is authoritative, so protocol written here IS how the app
   behaves on this call; no code changes needed.
3. **Anchors** — URLs, routes, ids, commands to read out verbatim on request.
4. **Verified facts** — the numbers, each with its verification date
   ("verified 26 Aug"). Number first, then what it is.
5. **Do not claim** — frozen scope, unlaunched work, unmeasured numbers,
   other people's areas.

## Call types

| | Core (checked) | Shelf (unchecked) | Protocol lines for BRIEFING.md |
|---|---|---|---|
| **Product demo / client call** | BRIEFING.md, STATE.md (generated), MAP.md | coverage docs, issue bodies, SCRIPT.md, past-call notes | "≤ 3 lines, the number first"; artifact questions → promise a doc; "don't know" in one word plus where to look |
| **Technical discussion** | BRIEFING.md (agenda, our decisions and promises, open tickets with numbers) | past transcripts, related specs | lead with the position, one reason, a question back |
| **No-context call** | — don't arm a project at all | — | the default prompt behaviour is already right |

Notes:

- **Demo:** `STATE.md` should be **generated from the code, not written by
  hand** (a `demo:state`-style script in the project repo): per pricing row,
  the limit constant and the enforcement site; per badge or signal, wired or
  stub. Hand-written state goes stale weekly, and the client asks about
  state, not about the demo route. `MAP.md` is the "where does the answer
  live" table — `question → file:symbol → command` — so the answer can be
  "that lives in TierLimit, I'll send the exact line in writing" instead of a
  bluff or a blank.
- **Discussion:** the "our decisions and promises" block is what turns the
  copilot from a search engine into a colleague who remembers what was agreed
  last time.

## Writing rules

- **Number first, source date attached.** "67% — model-based valuation
  (verified 26 Aug)" is extractable as a first sentence and correctable when
  stale.
- **Speakable words.** [Me] reads answers aloud under pressure. If a term is
  not in the pack or likely to come from the other side, give the plain
  phrasing next to it — the prompt will prefer it.

- **No yesterday's pack.** Copying the previous pack forward is how stale
  URLs, dead tokens and old counts get read to a client. Regenerate STATE,
  re-verify every number, and move the old pack out of the folder. An
  `archive/` subfolder is NOT hidden from the folder scan — its files still
  show up in the list, so leave them unchecked.
- **Shelf names are the retrieval index.** The scout sees only filenames.
  `harris-county-rollout.md` gets pulled when Harris County comes up;
  `misc.md` never gets pulled at all.

## Pre-call checklist

1. Pack folder named `<project>-<calltype>-<date>`.
2. `BRIEFING.md` opens with the header; the protocol matches the call type.
3. Every number carries a verification date from TODAY, or is deleted.
4. STATE.md regenerated; MAP.md covers the other side's recurring questions.
5. Core ≤ ~45k characters — `Livecall --context-selftest <folder>` prints
   per-file estimates headlessly; shelf files are `.md`/`.txt` and
   topic-named.
6. In the app: Add call context… → attach the folder → check the core files
   → Save as project (same name as last time = clean update) → arm it in the
   **Project: …** menu → the status line confirms files and characters.
7. Smoke test: press the FAST hotkey once before the call; **New call** to
   clear.
