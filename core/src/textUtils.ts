// The repetition-loop guard: whisper occasionally gets stuck emitting the same
// phrase over and over on a noisy chunk. Proved itself on real multilingual calls.

/** Normalize a token/phrase for repeat-detection: fold case, strip punctuation. */
function normForRepeat(s: string): string {
  return s.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

/**
 * Collapse pathological repetition loops that whisper falls into on marginal /
 * overlapping audio ("I think that's a great point." ×hundreds). Deterministic
 * safety net: any phrase (1..maxPhraseLen tokens) repeating consecutively
 * >= minReps times is capped to `keep` copies. Real speech ("yeah yeah") stays.
 */
export function collapseRepeatedPhrases(
  text: string,
  { maxPhraseLen = 12, minReps = 3, keep = 2 } = {},
): string {
  const tokens = String(text || "").split(/\s+/).filter(Boolean);
  if (tokens.length < minReps) return String(text || "").trim();
  const norm = tokens.map(normForRepeat);
  const out: string[] = [];
  let i = 0;
  while (i < tokens.length) {
    let collapsed = false;
    const maxLen = Math.min(maxPhraseLen, Math.floor((tokens.length - i) / minReps));
    for (let len = 1; len <= maxLen; len++) {
      const key = norm.slice(i, i + len).join(" ");
      if (!key) continue;
      let reps = 1;
      while (
        i + (reps + 1) * len <= tokens.length &&
        norm.slice(i + reps * len, i + (reps + 1) * len).join(" ") === key
      ) {
        reps++;
      }
      if (reps >= minReps) {
        for (let r = 0; r < Math.min(keep, reps); r++) {
          out.push(...tokens.slice(i, i + len));
        }
        i += reps * len;
        collapsed = true;
        break;
      }
    }
    if (!collapsed) {
      out.push(tokens[i]);
      i++;
    }
  }
  return out.join(" ");
}
