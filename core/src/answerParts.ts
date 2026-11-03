// An answer has two audiences: the part [Me] reads out loud, and the part
// written FOR [Me] — follow-up material and term glosses that make no sense
// spoken ("Deeper, if they press, colon"). Every surface that shows an
// answer has to keep them apart, or the note gets read aloud exactly once,
// live, in front of other people.
//
// A third piece rides in front of both: the `→` line where the model restates
// the question it picked out of a messy transcript. It exists so [Me] can
// catch a wrong pick BEFORE reading the wrong answer aloud — and it is just as
// unsayable as the note, so every surface strips it from the spoken part.
//
// Mirrored in Swift as `SplitAnswer` in app/Livecall/Sources/AnswerPanel.swift —
// the panel splits mid-stream, so it cannot call this. Change both together.

export interface AnswerParts {
  /** The model's restatement of the question it is answering (the `→` line). */
  reading?: string;
  /** Safe to say out loud. */
  spoken: string;
  /** Never say this out loud. */
  note?: string;
}

/** The `→` line opens the answer per prompts/answer.md; `---` opens the
 * footnote block; «Deeper …:» is the lead the briefing convention sets up
 * (see BRIEFING.md). Matched loosely: the exact wording after each marker
 * belongs to the model. */
export function splitAnswer(text: string): AnswerParts {
  let reading: string | undefined;
  let body = text;

  const lead = text.trimStart();
  if (lead.startsWith("→")) {
    const nl = lead.indexOf("\n");
    reading = (nl === -1 ? lead.slice(1) : lead.slice(1, nl)).trim() || undefined;
    body = nl === -1 ? "" : lead.slice(nl + 1);
  }

  const withReading = (parts: Omit<AnswerParts, "reading">): AnswerParts =>
    reading ? { reading, ...parts } : parts;

  const lines = body.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    const isFootnoteRule = trimmed === "---";
    const isDeeper = trimmed.toLowerCase().startsWith("deeper") && trimmed.includes(":");
    if (!isFootnoteRule && !isDeeper) continue;

    const spoken = lines.slice(0, i).join("\n").trim();
    // Drop the marker itself — the surface renders its own, louder — but keep
    // anything trailing it on the same line.
    const rest: string[] = [];
    if (isDeeper) {
      const tail = trimmed.slice(trimmed.indexOf(":") + 1).trim();
      if (tail) rest.push(tail);
    }
    rest.push(...lines.slice(i + 1));
    const note = rest.join("\n").trim();
    return withReading(note ? { spoken, note } : { spoken });
  }
  return withReading({ spoken: body.trim() });
}
