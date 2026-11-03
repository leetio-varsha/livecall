// Liveness of the two capture tracks.
//
// The distinction that makes this reliable: PCM frames flow CONTINUOUSLY, and
// silence is just quiet samples. So missing frames never means "nobody is
// talking" — it always means the capture died. That is why the watchdog can be
// blunt without ever false-alarming during a pause in the conversation.
//
// Kept dependency-free on purpose: the engine pulls in the LLM SDKs, and this
// has to stay testable without them.

/**
 * `off`     — never delivered a single frame; capture never started.
 * `live`    — frames arriving.
 * `stalled` — frames stopped arriving.
 */
export type TrackHealth = "off" | "live" | "stalled";

export interface AudioHealth {
  me: TrackHealth;
  them: TrackHealth;
}

/** Pure decision, so the watchdog is testable without a clock or a mic. */
export function trackHealth(lastFrameAt: number, now: number, stallMs: number): TrackHealth {
  if (!lastFrameAt) return "off";
  return now - lastFrameAt > stallMs ? "stalled" : "live";
}
