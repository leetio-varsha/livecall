import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import type { Config } from "./config.ts";

/**
 * Wraps whisper.cpp's `whisper-server`: the model stays resident in memory, so
 * each chunk costs only inference (no 3GB model reload per chunk, which is
 * what makes a spawn-whisper-cli-per-file approach unusable for realtime).
 */
export class WhisperServer {
  private proc: ChildProcess | null = null;
  readonly url: string;
  private ownsProcess: boolean;
  private cfg: Config["whisper"];

  constructor(cfg: Config["whisper"]) {
    this.cfg = cfg;
    this.url = cfg.serverUrl || `http://127.0.0.1:${cfg.port}`;
    this.ownsProcess = !cfg.serverUrl;
  }

  async start(): Promise<void> {
    if (!this.ownsProcess) {
      await this.waitReady(5_000);
      return;
    }
    // Someone is already on our port — a server leaked by a previous run, or
    // one started by hand. Adopt it instead of loading a second 3GB copy of
    // the model (which would fail to bind anyway and leave a doomed child).
    if (await this.ping()) {
      this.ownsProcess = false;
      console.error(
        `whisper-server already listening on ${this.url} — reusing it. ` +
          "It was not started by us, so it stays running after we exit " +
          `(kill it with: pkill -f 'whisper-server.*--port ${this.cfg.port}').`,
      );
      return;
    }
    if (!fs.existsSync(this.cfg.serverBin)) {
      throw new Error(`whisper-server not found at ${this.cfg.serverBin}`);
    }
    if (!fs.existsSync(this.cfg.modelPath)) {
      throw new Error(`whisper model not found at ${this.cfg.modelPath}`);
    }

    const args = [
      "-m", this.cfg.modelPath,
      "--host", "127.0.0.1",
      "--port", String(this.cfg.port),
      "-l", this.cfg.lang || "auto",
      "-sns", // suppress non-speech tokens (anti-hallucination)
    ];
    if (this.cfg.vadModel && fs.existsSync(this.cfg.vadModel)) {
      args.push("--vad", "--vad-model", this.cfg.vadModel);
    }

    const proc = spawn(this.cfg.serverBin, args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    proc.stderr?.on("data", (d) => (stderr += d.toString()));
    proc.on("error", (err) => {
      throw new Error(`Failed to launch whisper-server: ${err.message}`);
    });
    this.proc = proc;

    try {
      await this.waitReady(90_000); // large-v3 takes a few seconds to load
    } catch (e) {
      this.stop();
      throw new Error(`whisper-server did not become ready: ${(e as Error).message}\n${stderr.slice(-2000)}`);
    }
  }

  /** True when something answers HTTP on our URL. */
  private async ping(): Promise<boolean> {
    try {
      const res = await fetch(this.url, { signal: AbortSignal.timeout(1000) });
      return res.status < 500; // any HTTP answer = server is up
    } catch {
      return false;
    }
  }

  private async waitReady(timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.proc && this.proc.exitCode !== null) {
        throw new Error(`whisper-server exited with code ${this.proc.exitCode}`);
      }
      if (await this.ping()) return;
      await new Promise((r) => setTimeout(r, 300));
    }
    throw new Error(`timeout after ${timeoutMs}ms`);
  }

  /**
   * Transcribe one 16kHz mono WAV chunk. Returns plain text ("" on silence).
   * Degrades gracefully: a failed chunk logs and returns "" rather than
   * killing the pipeline.
   */
  async transcribe(wav: Buffer): Promise<string> {
    const fd = new FormData();
    fd.append("file", new Blob([new Uint8Array(wav)], { type: "audio/wav" }), "chunk.wav");
    fd.append("response_format", "json");
    try {
      const res = await fetch(`${this.url}/inference`, {
        method: "POST",
        body: fd,
        signal: AbortSignal.timeout(120_000),
      });
      if (!res.ok) {
        console.error(`whisper-server ${res.status}: ${(await res.text()).slice(0, 300)}`);
        return "";
      }
      const data = (await res.json()) as { text?: string };
      return (data.text ?? "").trim();
    } catch (e) {
      console.error(`whisper chunk failed: ${(e as Error).message}`);
      return "";
    }
  }

  stop(): void {
    if (this.ownsProcess && this.proc && this.proc.exitCode === null) {
      this.proc.kill("SIGTERM");
    }
    this.proc = null;
  }
}
