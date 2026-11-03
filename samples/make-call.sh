#!/usr/bin/env bash
# Generate a fake product-demo call that ends with a question addressed to the
# user, using macOS `say`. Output: samples/call.wav (16kHz mono).
# Usage: ./samples/make-call.sh
# Any installed `say` voice works, so a mixed-language call is one edit away.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$DIR/call.wav}"
TMP="$(mktemp -d -t livecall)"
trap 'rm -rf "$TMP"' EXIT

i=0
line() { # line <voice> <text>
  i=$((i+1))
  say -v "$1" "$2" -o "$TMP/$(printf '%02d' "$i").aiff"
}

# A short client call. All speakers are "them"; the final question is
# addressed to the user.
line Samantha "Okay, quick status on the search feature before we get into the demo. We shipped the new price filter to staging yesterday."
line Daniel   "On my side, the supplier integration is finished, but it's not enabled in production yet because I'm waiting on code review."
line Karen    "Great. The analytics dashboard is done as well, I'll share the link after the call."
line Samantha "Now the main question. The business side is asking us to remove pagination from search and return all hotels in a single response, up to a thousand of them."
line Daniel   "I don't love it. The upstream API may not survive a payload that size."
line Karen    "So, what do you think: should we remove the pagination like they asked, and if not, what do we offer them instead?"

# Concatenate and downsample to what whisper expects.
LIST="$TMP/list.txt"
for f in "$TMP"/*.aiff; do echo "file '$f'" >> "$LIST"; done
ffmpeg -y -f concat -safe 0 -i "$LIST" -ar 16000 -ac 1 -c:a pcm_s16le "$OUT" 2>/dev/null

echo "Wrote $OUT"
