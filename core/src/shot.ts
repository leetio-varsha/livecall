import { readFile, stat, unlink } from "node:fs/promises";

/** A screenshot handed over by the app, ready to go into a user turn. */
export interface Shot {
  mediaType: "image/png";
  base64: string;
  bytes: number;
}

/** Bigger than this is a bug upstream, not a screenshot of a window. */
const MAX_BYTES = 8 * 1024 * 1024;

/**
 * Read the PNG the app just wrote, then delete it.
 *
 * The app hands over a path rather than the bytes: the control channel is the
 * same pipe the PCM frames ride on, and pushing a megabyte of base64 through it
 * would stall audio behind the image. Same machine, so a path costs nothing.
 *
 * The file is removed whatever happens. It is a picture of whatever the user
 * had on screen mid-call, and that is not something to leave lying in /tmp.
 */
export async function loadShot(path: string): Promise<Shot | null> {
  try {
    const info = await stat(path);
    if (!info.isFile() || info.size === 0 || info.size > MAX_BYTES) return null;
    const data = await readFile(path);
    return { mediaType: "image/png", base64: data.toString("base64"), bytes: data.length };
  } catch {
    return null;
  } finally {
    void unlink(path).catch(() => {});
  }
}
