#!/usr/bin/env bash
# snapshot.sh — daily rolling snapshot of the public Jewell calendar feed.
#
# Google re-exports the feed in a different byte order (and fresh DTSTAMPs) on
# nearly every fetch, so raw SHA-256 changes constantly. "Did the record
# change?" is therefore decided on a CANONICAL hash: unfolded lines, DTSTAMP
# properties dropped, VEVENT/VTIMEZONE blocks sorted by key. When the canonical
# hash differs, the raw download (bytes exactly as served) is archived under
# snapshots/YYYY-MM-DD/ and anchored with OpenTimestamps; the .ots always
# verifies against the raw bytes of THAT file.
#
# Policy: one entry per UTC day (first stamp wins). Each run also upgrades
# still-pending proofs and harvests confirmed block heights from `ots info`
# (no Bitcoin node required — `ots verify` would need one; we deliberately
# avoid it). Commits + pushes to GitHub Pages when anything changed, or when
# there are unpushed local commits (publication is a standing obligation,
# independent of feed changes).
#
# Operational hardening (per multi-review pass):
#   - flock against overlapping runs
#   - atomic manifest writes (tmp + fsync + os.replace)
#   - staging dir for captures: file+proof are asserted consistent BEFORE
#     promotion, so an interrupted run can never wedge or publish a mismatch
#   - curl is time/size bounded; the response must parse as VCALENDAR
#   - only snapshots/ (+ the refreshed pinned root .ots) are ever staged
#   - self-expiry after HORIZON_END (~6-month evidence window)
set -euo pipefail

HORIZON_END="2027-04-21"
NOW="$(date -u +%FT%TZ)"; TODAY="${NOW%%T*}"
log() { echo "[snapshot ${NOW}] $*"; }

if [[ "$TODAY" > "$HORIZON_END" ]]; then
  log "watch concluded (horizon ${HORIZON_END} reached). The register stands as published."
  exit 0
fi

SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "$SITE_DIR/.." && pwd)"
OTS="$PROJECT_DIR/.venv/bin/ots"
PY="$PROJECT_DIR/.venv/bin/python"
FEED_URL="https://calendar.google.com/calendar/ical/jewell.john%40gmail.com/public/basic.ics"
MANIFEST="snapshots/snapshots.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/jewell"
mkdir -p "$STATE_DIR"

exec 9>"$STATE_DIR/snapshot.lock"
flock -n 9 || { log "another run in progress; exiting."; exit 0; }

cd "$SITE_DIR"

STAGE="$(mktemp -d)"
TMP="$STAGE/feed.ics"
trap 'rm -rf "$STAGE"' EXIT

# ---- canonical content hashing ---------------------------------------------
canon() {  # canonical content hash of an ics file -> stdout (see tools/canon.py)
  "$PY" "$SITE_DIR/tools/canon.py" "$1"
}

count_events() { grep -c '^BEGIN:VEVENT' "$1" || true; }

# ---- fetch ------------------------------------------------------------------
log "fetching feed…"
curl -sfL --retry 3 --retry-delay 10 --connect-timeout 15 --max-time 120 \
     --max-filesize 25000000 --proto '=https' --proto-redir '=https' \
     -o "$TMP" "$FEED_URL"
head -c 24 "$TMP" | grep -q '^BEGIN:VCALENDAR' || { log "FEED INVALID (not VCALENDAR); refusing to archive."; exit 1; }
NEW_RAW="$(sha256sum "$TMP" | awk '{print $1}')"
NEW_CANON="$(canon "$TMP")"
NEW_COUNT="$(count_events "$TMP")"

LATEST="$("$PY" - "$MANIFEST" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    last = d[-1] if d else {}
    print(last.get("canon", ""), last.get("date", ""), last.get("events", 0))
except (FileNotFoundError, json.JSONDecodeError):
    print("BOOTSTRAP", "", 0)
PY
)"
read -r LATEST_CANON LATEST_DATE LATEST_EVENTS <<< "$LATEST"

CHANGED=0

# ---- stamp a new snapshot if the canonical record changed --------------------
if [[ "$LATEST_DATE" = "$TODAY" ]]; then
  log "already stamped today; skipping capture."
elif [[ "$NEW_CANON" != "$LATEST_CANON" ]]; then
  if [[ "$LATEST_EVENTS" -gt 0 && "$NEW_COUNT" -lt $(( LATEST_EVENTS / 2 )) ]]; then
    log "ANOMALY: event count collapsed (${LATEST_EVENTS} -> ${NEW_COUNT}); not archiving today."
  else
    log "record changed (canon ${NEW_CANON:0:12}…, ${NEW_COUNT} events); staging seal…"
    install -m 0644 "$TMP" "$STAGE/snapshot.ics"
    "$OTS" stamp "$STAGE/snapshot.ics" </dev/null 2>&1 | tail -2
    # post-stamp consistency assertion (CAT test): proof transcript must name
    # this exact file's digest before anything is promoted into the register.
    PROOF_DIGEST="$("$OTS" info "$STAGE/snapshot.ics.ots" | grep -m1 -oP 'File sha256 hash: \K[0-9a-f]{64}')"
    STAGED_HASH="$(sha256sum "$STAGE/snapshot.ics" | awk '{print $1}')"
    [[ "$PROOF_DIGEST" = "$STAGED_HASH" ]] || { log "FATAL: staged proof/file mismatch."; exit 1; }
    DIR="snapshots/$TODAY"
    mkdir -p "$DIR"
    install -m 0644 "$STAGE/snapshot.ics" "$DIR/jewell-latest.ics"
    install -m 0644 "$STAGE/snapshot.ics.ots" "$DIR/jewell-latest.ics.ots"
    "$PY" - "$MANIFEST" "$TODAY" "$NOW" "$STAGED_HASH" "$NEW_CANON" "$DIR/jewell-latest.ics" "$NEW_COUNT" <<'PY'
import json, os, sys
manifest, date, stamped, sha, canon_hash, ics, events = sys.argv[1:8]
tmp = manifest + ".tmp"
try: data = json.load(open(manifest))
except (FileNotFoundError, json.JSONDecodeError): data = []
data.append({
    "date": date, "entered_utc": stamped,
    "file": ics, "proof": ics + ".ots",
    "sha256": sha, "canon": canon_hash,
    "events": int(events), "bytes": os.path.getsize(ics),
    "status": "pending", "block": None,
})
with open(tmp, "w") as f:
    json.dump(data, f, indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
os.replace(tmp, manifest)
print(f"manifest: registered {date} ({events} events)")
PY
    CHANGED=1
  fi
else
  log "no content change (canon ${NEW_CANON:0:12}…)."
fi

# ---- upgrade pending proofs; harvest block heights via ots info -------------
PENDING="$("$PY" -c "
try:
    import json; print('\n'.join(e['proof'] for e in json.load(open('$MANIFEST')) if e['status']=='pending'))
except Exception: print('')" || true)"
while read -r proof; do
  [ -z "${proof:-}" ] && continue
  log "upgrade attempt: $proof"
  "$OTS" upgrade "$proof" </dev/null >/dev/null 2>&1 || true
  block="$("$OTS" info "$proof" 2>/dev/null | grep -oP 'BitcoinBlockHeaderAttestation\(\K\d+' | sort -n | head -1 || true)"
  if [ -n "${block:-}" ]; then
    "$PY" - "$MANIFEST" "$proof" "$block" <<'PY'
import json, os, sys
manifest, proof, block = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = json.load(open(manifest))
tmp = manifest + ".tmp"
for e in data:
    if e["proof"] == proof:
        e["status"] = "anchored"; e["block"] = block
with open(tmp, "w") as f:
    json.dump(data, f, indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
os.replace(tmp, manifest)
print(f"manifest: {proof} anchored at block {block}")
PY
    # keep the pinned root exhibit proof in lockstep with its dated twin
    if [ "$proof" = "snapshots/2026-10-21/jewell-latest.ics.ots" ]; then
      cp "$proof" jewell-latest.ics.ots
    fi
    CHANGED=1
  fi
done <<< "$PENDING"
rm -f snapshots/*/*.bak 2>/dev/null || true

# ---- ledger self-check (CAT test): every row must verify against its file ----
"$PY" - "$MANIFEST" <<'PY'
import hashlib, json, sys
data = json.load(open(sys.argv[1]))
bad = []
for e in data:
    h = hashlib.sha256(open(e["file"], 'rb').read()).hexdigest()
    if h != e["sha256"]: bad.append(f"{e['file']}: {h} != {e['sha256']}")
    elif bytes.fromhex(e["sha256"]) not in open(e["proof"], 'rb').read():
        bad.append(f"{e['proof']}: digest absent")
if bad:
    print("SELF-CHECK FAILED:\n  " + "\n  ".join(bad)); sys.exit(1)
print(f"self-check OK ({len(data)} entries, every proof matches its file)")
PY

# ---- publish ----------------------------------------------------------------
git add -- snapshots/ jewell-latest.ics.ots
if [ "$CHANGED" = "1" ]; then
  git -c user.name="transparentfredco-bot" \
      -c user.email="EthnTuttle@users.noreply.github.com" \
      commit -qm "Snapshot register update ${TODAY}"
fi
git pull --rebase --autostash -q || true
if [ -n "$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" ] && \
   [ "$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" != "0" ]; then
  git push -q
  log "pushed register update."
else
  log "nothing to push."
fi
