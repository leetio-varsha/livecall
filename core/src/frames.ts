// Wire protocol between the Swift helper and the core (see FrameWriter.swift):
//   byte 0     : source — 0 = me (mic), 1 = them (system audio), 2 = control
//   bytes 1..3 : reserved (0)
//   bytes 4..7 : UInt32LE payload length
//   payload    : s16le 16kHz mono PCM for 0/1, UTF-8 JSON for 2
//
// stdout gives us an arbitrarily chopped byte stream, so frames arrive split
// across reads and several at a time — that reassembly lives here (and is
// covered by npm test) instead of inline in live.ts.

export const SOURCE = { me: 0, them: 1, control: 2 } as const;

const HEADER_BYTES = 8;
/** Audio frames are a few KB; anything near this means the stream desynced. */
const MAX_PAYLOAD_BYTES = 1 << 20;

export interface AudioFrame {
  kind: "audio";
  source: typeof SOURCE.me | typeof SOURCE.them;
  pcm: Buffer;
}

export interface ControlFrame {
  kind: "control";
  event: string;
  /** Present on `hotkey` frames: which answer mode was requested. */
  mode?: string;
  /** Present on `context` frames: the text to add to the call context. */
  text?: string;
  /** Present on a screen question: path to the PNG the app just captured. */
  shot?: string;
  /** Present on `project_context` frames: paths of the project's shelf files
   * (saved but NOT briefed), kept for the mid-call scout. */
  shelf?: string[];
}

export type HelperFrame = AudioFrame | ControlFrame;

/**
 * Incremental reader for the helper's stdout. Feed it whatever `data` events
 * deliver; it returns the complete frames contained so far and keeps the
 * remainder for next time.
 */
export class FrameParser {
  private acc: Buffer = Buffer.alloc(0);

  /** @throws if a length field is implausible — the stream is unrecoverable. */
  push(chunk: Buffer): HelperFrame[] {
    this.acc = this.acc.length ? Buffer.concat([this.acc, chunk]) : chunk;
    const frames: HelperFrame[] = [];

    while (this.acc.length >= HEADER_BYTES) {
      const len = this.acc.readUInt32LE(4);
      if (len > MAX_PAYLOAD_BYTES) {
        this.acc = Buffer.alloc(0);
        throw new Error(`frame stream desynced: payload length ${len} exceeds ${MAX_PAYLOAD_BYTES}`);
      }
      if (this.acc.length < HEADER_BYTES + len) break; // wait for the rest

      const source = this.acc[0];
      const payload = this.acc.subarray(HEADER_BYTES, HEADER_BYTES + len);
      this.acc = this.acc.subarray(HEADER_BYTES + len);

      if (source === SOURCE.me || source === SOURCE.them) {
        frames.push({ kind: "audio", source, pcm: payload });
      } else if (source === SOURCE.control) {
        const control = parseControl(payload);
        if (control) frames.push(control);
      }
      // unknown source: header was still valid, so just drop the payload
    }
    return frames;
  }
}

function parseControl(payload: Buffer): ControlFrame | null {
  try {
    const obj = JSON.parse(payload.toString("utf8")) as Record<string, unknown>;
    if (typeof obj.event !== "string") return null;
    const shelf = readShelf(obj.shelf);
    return {
      kind: "control",
      event: obj.event,
      ...(typeof obj.mode === "string" ? { mode: obj.mode } : {}),
      ...(typeof obj.text === "string" ? { text: obj.text } : {}),
      ...(typeof obj.shot === "string" ? { shot: obj.shot } : {}),
      ...(shelf ? { shelf } : {}),
    };
  } catch {
    return null; // malformed control frame — ignore, audio must keep flowing
  }
}

/**
 * The Swift side's writeControl carries string fields only, so the shelf
 * array arrives JSON-encoded inside a string; a raw array is accepted too.
 * Anything else reads as absent, never as an error — audio must keep flowing.
 */
function readShelf(v: unknown): string[] | undefined {
  let raw = v;
  if (typeof raw === "string") {
    try {
      raw = JSON.parse(raw);
    } catch {
      return undefined;
    }
  }
  if (Array.isArray(raw) && raw.every((s): s is string => typeof s === "string")) return raw;
  return undefined;
}
