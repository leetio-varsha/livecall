import { wavHeader } from "./chunker.ts";

export interface SegmenterOptions {
  /** Trailing quiet needed to cut a chunk at a natural pause. */
  silenceMs: number;
  /** RMS (int16 scale) below which a block counts as silence. */
  silenceRms: number;
  /** Don't cut on a pause until at least this much speech is buffered. */
  minSpeechMs: number;
  /** Hard cap — cut even mid-speech (whisper quality degrades on long chunks). */
  maxChunkMs: number;
}

export interface AudioChunk {
  startMs: number;
  endMs: number;
  wav: Buffer;
}

const BYTES_PER_MS = 32; // 16kHz mono s16le

/**
 * Turns a continuous PCM stream into transcription chunks cut at natural
 * pauses instead of fixed 5s boundaries (m1's word-clipping fix). One
 * instance per speaker. Silence-only stretches are dropped without ever
 * reaching whisper. flush() force-emits the current partial chunk — used on
 * hotkey so the just-asked question is always in the transcript.
 */
export class Segmenter {
  private opts: SegmenterOptions;
  private parts: Buffer[] = [];
  private bufferedBytes = 0;
  private startMs = 0; // stream time at buffer start
  private streamMs = 0; // total stream time consumed
  private trailingSilenceMs = 0;
  private hasSpeech = false;

  constructor(opts: SegmenterOptions) {
    this.opts = opts;
  }

  /** Feed one PCM block (any even byte length). Returns a chunk if one was cut. */
  push(pcm: Buffer): AudioChunk | null {
    if (pcm.length < 2) return null;
    const blockMs = pcm.length / BYTES_PER_MS;
    const silent = rms(pcm) < this.opts.silenceRms;

    // Don't buffer leading silence — slide the window start forward instead,
    // so a quiet mic doesn't accumulate minutes of dead air.
    if (silent && !this.hasSpeech) {
      this.streamMs += blockMs;
      this.startMs = this.streamMs;
      return null;
    }

    this.parts.push(pcm);
    this.bufferedBytes += pcm.length;
    this.streamMs += blockMs;
    if (silent) {
      this.trailingSilenceMs += blockMs;
    } else {
      this.trailingSilenceMs = 0;
      this.hasSpeech = true;
    }

    const bufferedMs = this.bufferedBytes / BYTES_PER_MS;
    const speechMs = bufferedMs - this.trailingSilenceMs;
    if (speechMs >= this.opts.minSpeechMs && this.trailingSilenceMs >= this.opts.silenceMs) {
      return this.emit(); // natural pause
    }
    if (bufferedMs >= this.opts.maxChunkMs) {
      return this.emit(); // hard cap, mid-speech
    }
    return null;
  }

  /** Force-emit whatever is buffered (hotkey press / call end). */
  flush(): AudioChunk | null {
    const bufferedMs = this.bufferedBytes / BYTES_PER_MS;
    if (!this.hasSpeech || bufferedMs - this.trailingSilenceMs < 200) {
      this.reset();
      return null;
    }
    return this.emit();
  }

  private emit(): AudioChunk {
    const data = Buffer.concat(this.parts);
    const chunk: AudioChunk = {
      startMs: Math.round(this.startMs),
      endMs: Math.round(this.streamMs),
      wav: Buffer.concat([wavHeader(data.length), data]),
    };
    this.reset();
    return chunk;
  }

  private reset(): void {
    this.parts = [];
    this.bufferedBytes = 0;
    this.startMs = this.streamMs;
    this.trailingSilenceMs = 0;
    this.hasSpeech = false;
  }
}

/** Root-mean-square of an s16le buffer. */
export function rms(pcm: Buffer): number {
  const samples = pcm.length >> 1;
  if (!samples) return 0;
  let sum = 0;
  for (let i = 0; i < samples; i++) {
    const s = pcm.readInt16LE(i << 1);
    sum += s * s;
  }
  return Math.sqrt(sum / samples);
}
