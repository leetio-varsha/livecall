export type Speaker = "me" | "them";

export interface Segment {
  startMs: number;
  endMs: number;
  speaker: Speaker;
  text: string;
}

const LABEL: Record<Speaker, string> = { me: "Me", them: "Them" };

/** Group time-ordered segments into "[Me] ...\n[Them] ..." lines. */
export function renderSegments(segments: Segment[]): string {
  const lines: string[] = [];
  let cur: { speaker: Speaker; text: string } | null = null;
  const flush = () => {
    if (cur) lines.push(`[${LABEL[cur.speaker]}] ${cur.text}`);
  };
  for (const s of segments) {
    if (cur && cur.speaker === s.speaker) {
      cur.text += " " + s.text;
    } else {
      flush();
      cur = { speaker: s.speaker, text: s.text };
    }
  }
  flush();
  return lines.join("\n");
}

/**
 * Rolling transcript of the current call: time-ordered, speaker-tagged
 * segments. Keeps the FULL call; windowed/delta views are computed on read.
 */
export class TranscriptBuffer {
  segments: Segment[] = [];

  add(seg: Segment): void {
    if (!seg.text.trim()) return;
    // Insert keeping startMs order (two-track feeds interleave out of order).
    let i = this.segments.length;
    while (i > 0 && this.segments[i - 1].startMs > seg.startMs) i--;
    this.segments.splice(i, 0, seg);
  }

  get lastEndMs(): number {
    return this.segments.reduce((m, s) => Math.max(m, s.endMs), 0);
  }

  fullText(): string {
    return renderSegments(this.segments);
  }

  /** Segments whose end falls inside the last `windowMs` of the call. */
  windowText(windowMs: number): string {
    const from = this.lastEndMs - windowMs;
    return renderSegments(this.segments.filter((s) => s.endMs >= from));
  }

  /** Render segments starting at index `fromIndex` (for per-question deltas). */
  sinceIndex(fromIndex: number): string {
    return renderSegments(this.segments.slice(fromIndex));
  }

  reset(): void {
    this.segments = [];
  }
}
