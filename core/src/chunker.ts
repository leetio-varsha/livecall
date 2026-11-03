import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

/** Convert any audio file to 16kHz mono s16le WAV via ffmpeg. */
export function toWav16k(inputPath: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const out = path.join(os.tmpdir(), `livecall-${crypto.randomBytes(6).toString("hex")}.wav`);
    const args = ["-y", "-i", inputPath, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", out];
    const ff = spawn("ffmpeg", args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    ff.stderr.on("data", (d) => (stderr += d.toString()));
    ff.on("error", (err) =>
      reject(new Error(`Failed to launch ffmpeg (is it installed?): ${err.message}`)),
    );
    ff.on("close", (code) => {
      if (code === 0 && fs.existsSync(out)) resolve(out);
      else reject(new Error(`ffmpeg failed (code ${code}):\n${stderr.slice(-2000)}`));
    });
  });
}

export interface WavChunk {
  startMs: number;
  endMs: number;
  wav: Buffer;
}

export const BYTES_PER_SEC = 16_000 * 2; // 16kHz mono s16le

export function wavHeader(dataBytes: number): Buffer {
  const h = Buffer.alloc(44);
  h.write("RIFF", 0);
  h.writeUInt32LE(36 + dataBytes, 4);
  h.write("WAVE", 8);
  h.write("fmt ", 12);
  h.writeUInt32LE(16, 16); // fmt chunk size
  h.writeUInt16LE(1, 20); // PCM
  h.writeUInt16LE(1, 22); // mono
  h.writeUInt32LE(16_000, 24); // sample rate
  h.writeUInt32LE(BYTES_PER_SEC, 28); // byte rate
  h.writeUInt16LE(2, 32); // block align
  h.writeUInt16LE(16, 34); // bits per sample
  h.write("data", 36);
  h.writeUInt32LE(dataBytes, 40);
  return h;
}

/** Locate the `data` chunk inside a RIFF/WAVE file (ffmpeg may add LIST etc.). */
export function findDataChunk(wav: Buffer): { offset: number; size: number } {
  if (wav.toString("ascii", 0, 4) !== "RIFF" || wav.toString("ascii", 8, 12) !== "WAVE") {
    throw new Error("not a RIFF/WAVE file");
  }
  let pos = 12;
  while (pos + 8 <= wav.length) {
    const id = wav.toString("ascii", pos, pos + 4);
    const size = wav.readUInt32LE(pos + 4);
    if (id === "data") return { offset: pos + 8, size: Math.min(size, wav.length - pos - 8) };
    pos += 8 + size + (size % 2); // chunks are word-aligned
  }
  throw new Error("no data chunk found in WAV");
}

/**
 * Slice a 16kHz mono WAV into standalone WAV chunks of `chunkSeconds`,
 * simulating what live capture feeds in live mode.
 */
export function sliceWav(wavPath: string, chunkSeconds: number): WavChunk[] {
  const wav = fs.readFileSync(wavPath);
  const { offset, size } = findDataChunk(wav);
  const chunkBytes = Math.floor(BYTES_PER_SEC * chunkSeconds / 2) * 2; // sample-aligned
  const chunks: WavChunk[] = [];
  for (let pos = 0; pos < size; pos += chunkBytes) {
    const slice = wav.subarray(offset + pos, offset + Math.min(pos + chunkBytes, size));
    if (slice.length < BYTES_PER_SEC * 0.25) break; // ignore a <250ms tail
    chunks.push({
      startMs: Math.round((pos / BYTES_PER_SEC) * 1000),
      endMs: Math.round(((pos + slice.length) / BYTES_PER_SEC) * 1000),
      wav: Buffer.concat([wavHeader(slice.length), slice]),
    });
  }
  return chunks;
}
