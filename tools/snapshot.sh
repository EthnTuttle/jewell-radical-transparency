#!/usr/bin/env bash
# snapshot.sh — daily rolling snapshot of the public Jewell calendar feed.
#
# Google re-exports the feed in a different byte order (and fresh DTSTAMPs) on
# nearly every fetch, so raw SHA-256 changes constantly. "Did the record
# change?" is therefore decided on a CANONICAL hash: unfolded lines, DTSTAMPs
# dropped, VEVENT blocks sorted by UID. When the canonical hash differs, the
# raw download (bytes exactly as served) is archived under
# snapshots/YYYY-MM-DD/ and anchored with OpenTimestamps; the .ots always
# verifies against the raw bytes of THAT file.
#
# Policy: one entry per UTC day (the first stamp wins); unchanged feeds are a
# no-op. Each run also upgrades still-pending proofs and records confirmed
# Bitcoin block heights. Commits + pushes to GitHub Pages on any change.
set -euo pipefail

SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "$SITE_DIR/.." && pwd)"
OTS="$PROJECT_DIR/.venv/bin/ots"
PY="$PROJECT_DIR/.venv/bin/python"
FEED_URL="https://calendar.google.com/calendar/ical/jewell.john%40gmail.com/public/basic.ics"
MANIFEST="snapshots/snapshots.json"
LOG_PREFIX="[snapshot $(date -u +%FT%TZ)]"

cd "$SITE_DIR"

TMP="$(mktemp --suffix=.ics)"
trap 'rm -f "$TMP"' EXIT

canon() {  # canonical content hash of an ics file -> stdout
  "$PY" - "$1" <<'PY'
import hashlib, re, sys
t = open(sys.argv[1], encoding='utf-8', errors='replace').read()
t = re.sub(r'\r?\n[ \t]', '', t)
lines = [l for l in t.splitlines() if not l.startswith('DTSTAMP')]
t = '\n'.join(lines)
blocks = re.findall(r'BEGIN:VEVENT.*?END:VEVENT', t, re.S)
blocks.sort(key=lambda b: (re.search(r'^UID:(.*)$', b, re.M) or [None, ''])[1] + b)
rest = t
for b in re.findall(r'BEGIN:VEVENT.*?END:VEVENT', t, re.S):
    rest = rest.replace(b, '', 1)
print(hashlib.sha256((rest + '\n'.join(blocks)).encode()).hexdigest())
PY
}

echo "$LOG_PREFIX fetching feed…"
curl -sfL --retry 3 --retry-delay 10 -o "$TMP" "$FEED_URL"
NEW_RAW="$(sha256sum "$TMP" | awk '{print $1}')"
NEW_CANON="$(canon "$TMP")"
LATEST_CANON="$("$PY" -c 'import json;d=json.load(open("snapshots/snapshots.json"));print(d[-1]["canon"])')"
LATEST_DATE="$("$PY" -c 'import json;d=json.load(open("snapshots/snapshots.json"));print(d[-1]["date"])')"
TODAY="$(date -u +%F)"

CHANGED=0

if [ "$LATEST_DATE" = "$TODAY" ]; then
  echo "$LOG_PREFIX already stamped today; skipping."
elif [ "$NEW_CANON" != "$LATEST_CANON" ]; then
  DIR="snapshots/$TODAY"
  mkdir -p "$DIR"
  cp "$TMP" "$DIR/jewell-latest.ics"
  echo "$LOG_PREFIX record changed; raw=$NEW_RAW canon=$NEW_CANON; stamping…"
  "$OTS" stamp "$DIR/jewell-latest.ics"
  "$PY" - "$MANIFEST" "$TODAY" "$(date -u +%FT%TZ)" "$NEW_RAW" "$NEW_CANON" "$DIR/jewell-latest.ics" <<'PY'
import json, os, re, sys
manifest, date, stamped, sha, canon_hash, ics = sys.argv[1:7]
data = json.load(open(manifest))
raw = open(ics, encoding='utf-8', errors='replace').read()
data.append({
    "date": date,
    "entered_utc": stamped,
    "file": ics,
    "proof": ics + ".ots",
    "sha256": sha,
    "canon": canon_hash,
    "events": len(re.findall(r'BEGIN:VEVENT', raw)),
    "bytes": os.path.getsize(ics),
    "status": "pending",
    "block": None,
})
json.dump(data, open(manifest, 'w'), indent=2)
print(f"manifest: registered {date} ({data[-1]['events']} events)")
PY
  CHANGED=1
else
  echo "$LOG_PREFIX no content change (canon $NEW_CANON)."
fi

# Upgrade pending proofs; harvest confirmed block heights
PENDING="$("$PY" -c 'import json;print("\n".join(e["proof"] for e in json.load(open("snapshots/snapshots.json")) if e["status"]=="pending"))' || true)"
while read -r proof; do
  [ -z "$proof" ] && continue
  echo "$LOG_PREFIX upgrade attempt: $proof"
  "$OTS" upgrade "$proof" 2>/dev/null || true
  if out="$("$OTS" verify "$proof" 2>&1)"; then
    block="$(echo "$out" | grep -oP 'Bitcoin block \K\d+' | head -1 || true)"
    if [ -n "${block:-}" ]; then
      "$PY" - "$MANIFEST" "$proof" "$block" <<'PY'
import json, sys
manifest, proof, block = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = json.load(open(manifest))
for e in data:
    if e["proof"] == proof:
        e["status"] = "anchored"; e["block"] = block
json.dump(data, open(manifest, 'w'), indent=2)
print(f"manifest: {proof} anchored at block {block}")
PY
      CHANGED=1
    fi
  fi
done <<< "$PENDING"

if [ "$CHANGED" = "1" ]; then
  git add -A
  git -c user.name="transparentfredco-bot" \
      -c user.email="EthnTuttle@users.noreply.github.com" \
      commit -qm "Snapshot register update $(date -u +%F)"
  git push -q
  echo "$LOG_PREFIX pushed register update."
else
  echo "$LOG_PREFIX done, no push."
fi
