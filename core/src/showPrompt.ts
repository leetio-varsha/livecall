// Print the exact system prompt Livecall will send, so "did it even read my
// prompt?" stops being a guess you make after a bad answer.
//
//   node src/showPrompt.ts                 # the base prompt alone
//   node src/showPrompt.ts my-context.txt  # ...with a context file attached
//   node src/showPrompt.ts ctx.txt --stats # sizes only, skip the text

import fs from "node:fs";
import { loadConfig } from "./config.ts";
import { buildSystemPrompt } from "./session.ts";

const argv = process.argv.slice(2);
const statsOnly = argv.includes("--stats");
const files = argv.filter((a) => !a.startsWith("--"));

const context = files.map((f) => {
  try {
    return fs.readFileSync(f, "utf8");
  } catch (e) {
    console.error(`cannot read ${f}: ${(e as Error).message}`);
    process.exit(1);
  }
});

const prompt = buildSystemPrompt(loadConfig(), context);

if (!statsOnly) console.log(prompt);

// Same script-weighted estimate the app's context window shows, so the two
// numbers can be compared directly instead of eyeballed.
let ascii = 0;
let wide = 0;
for (const ch of prompt) (ch.charCodeAt(0) < 128 ? ascii++ : wide++);

const attached = context.reduce((n, c) => n + c.length, 0);
console.error(
  `\n— system prompt: ${prompt.length.toLocaleString()} chars ` +
    `(≈${Math.floor(ascii / 4 + wide / 2).toLocaleString()} tokens), ` +
    `${attached.toLocaleString()} of them attached context from ` +
    `${files.length} file(s) —`,
);
if (context.length && !prompt.includes("## CALL CONTEXT")) {
  console.error("!! context did NOT make it into the prompt — this is a bug");
  process.exit(1);
}
