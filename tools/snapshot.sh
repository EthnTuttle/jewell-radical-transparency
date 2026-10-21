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
SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "$SITE_DIR/.." && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/jewell"
RUN_LOG="$STATE_DIR/snapshot.log"

# ---- notifications (Marmot nostr DM bot; fire-and-forget, must never fail) --
# NOTIFY and the traps are installed BEFORE the mkdir below, so that even a
# failing mkdir still rings the bell. (SIGKILL is uncoverable: no trap can
# fire on it; that gap is accepted and documented here.)
NOTIFY="$SITE_DIR/tools/notify.sh"
# `9>&-`: the flock fd 9 (acquired below) must never leak into the notify pipeline.
notify() { "$NOTIFY" "$1" "$2" 9>&- || true; }
NOTIFIED_FAILURE=0
on_exit() {
  trap - EXIT TERM INT HUP        # one-shot: the exit/kill below must not re-enter
  local sig="${1:-}" rc=$?
  case "$sig" in                  # 128+signo convention for the failure report
    HUP)  rc=129 ;;
    INT)  rc=130 ;;
    TERM) rc=143 ;;
  esac
  # a failing rm must not suppress the failure bell
  [ -z "${STAGE:-}" ] || rm -rf "$STAGE" 2>/dev/null || true
  if [ "$rc" -ne 0 ] && [ "$NOTIFIED_FAILURE" = "0" ]; then
    NOTIFIED_FAILURE=1
    notify "jewell watch: WATCHER FAILED" \
      "snapshot.sh exited rc=$rc${sig:+ (SIG$sig)} on ${TODAY}. Last log lines:
$(tail -n 25 "$RUN_LOG" 2>/dev/null || true)"
  fi
  if [ -n "$sig" ]; then
    kill -s "$sig" $$ 2>/dev/null || exit "$rc"  # re-raise: cron observes a real signal death
    exit "$rc"
  fi
}
trap on_exit EXIT
trap 'on_exit TERM' TERM
trap 'on_exit INT' INT
trap 'on_exit HUP' HUP

mkdir -p "$STATE_DIR"
# cron already redirects stdout+stderr to $RUN_LOG; plain echo only — tee would
# log every line twice.
log() { echo "[snapshot ${NOW}] $*"; }

if [[ "$TODAY" > "$HORIZON_END" ]]; then
  log "watch concluded (horizon ${HORIZON_END} reached). The register stands as published."
  if [ ! -f "$STATE_DIR/horizon-notified" ]; then
    # latch BEFORE notify: a slow (up to 120s) in-flight send must never
    # allow a concurrent run to double-notify the horizon.
    : > "$STATE_DIR/horizon-notified" 2>/dev/null || true
    notify "jewell watch: HORIZON REACHED" \
      "evidence window ${HORIZON_END} has passed; the register stands as published. Watcher is now silent."
  fi
  exit 0
fi

OTS="$PROJECT_DIR/.venv/bin/ots"
PY="$PROJECT_DIR/.venv/bin/python"
FEED_URL="https://calendar.google.com/calendar/ical/jewell.john%40gmail.com/public/basic.ics"
MANIFEST="snapshots/snapshots.json"

exec 9>"$STATE_DIR/snapshot.lock"
flock -n 9 || { log "another run in progress; exiting."; exit 0; }

cd "$SITE_DIR"

STAGE="$(mktemp -d)"
TMP="$STAGE/feed.ics"

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
    # Deliberate once-per-anomaly guard (same idea as the horizon latch): the
    # marker stores the LATEST_EVENTS/NEW_COUNT pair; we re-notify ONLY if the
    # counts change again. Healthy paths below clear the marker. Latch before
    # notify so a slow send can't race into a double notification.
    ANOMALY_KEY="$LATEST_EVENTS $NEW_COUNT"
    if [ "$(cat "$STATE_DIR/anomaly-notified" 2>/dev/null || true)" != "$ANOMALY_KEY" ]; then
      printf '%s\n' "$ANOMALY_KEY" > "$STATE_DIR/anomaly-notified" 2>/dev/null || true
      notify "jewell watch: ANOMALY" \
        "event count collapsed (${LATEST_EVENTS} -> ${NEW_COUNT}) on ${TODAY}; today's capture rejected, register unchanged."
    else
      log "ANOMALY unchanged (${ANOMALY_KEY}); already notified, staying quiet."
    fi
  else
    rm -f "$STATE_DIR/anomaly-notified" 2>/dev/null || true  # healthy capture: reset the guard
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
    notify "jewell watch: NEW SNAPSHOT sealed ${TODAY}" \
      "events:      ${NEW_COUNT}
raw sha256:  ${STAGED_HASH:0:16}…
canon hash:  ${NEW_CANON:0:16}…
snapshot:    ${DIR}"
  fi
else
  log "no content change (canon ${NEW_CANON:0:12}…)."
  rm -f "$STATE_DIR/anomaly-notified" 2>/dev/null || true  # feed matches register: reset the guard
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
    ENTRY_DATE="${proof#snapshots/}"; ENTRY_DATE="${ENTRY_DATE%%/*}"
    notify "jewell watch: SEAL ANCHORED block #${block}" \
      "entry date: ${ENTRY_DATE} (proof: ${proof})"
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
git pull --rebase --autostash -q 9>&- || true
if [ -n "$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" ] && \
   [ "$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" != "0" ]; then
  git push -q 9>&-
  log "pushed register update."
else
  log "nothing to push."
fi

# ---- weekly liveness heartbeat: silence is unverifiable ----------------------
# A quiet register and a dead notification path look identical from the
# outside. If this run sent no notifications (no new seal, nothing anchored)
# and the last confirmed-OK send is older than 7 days (or unknown), emit a
# heartbeat. The latch ($HB_FILE) is refreshed ONLY when notify.sh reports
# last_rc=0 in notify.status. Every step is guarded — non-fatal under set -e.
if [ "$CHANGED" = "0" ]; then
  HB_FILE="$STATE_DIR/last-notify-ok-ts"
  NOW_S="$(date +%s)"
  status_rc() { sed -n 's/.*\blast_rc=\([0-9][0-9]*\).*/\1/p' "$STATE_DIR/notify.status" 2>/dev/null | tail -n 1; }
  # a successful send earlier in THIS run (e.g. ANOMALY) also proves liveness
  if [ "$(status_rc)" = "0" ]; then
    printf '%s\n' "$NOW_S" > "$HB_FILE" 2>/dev/null || true
  else
    LAST_OK="$(cat "$HB_FILE" 2>/dev/null || echo 0)"
    case "$LAST_OK" in ''|*[!0-9]*) LAST_OK=0 ;; esac
    if [ $(( NOW_S - LAST_OK )) -gt 604800 ]; then
      HB_DAYS="$("$PY" - "$MANIFEST" 2>/dev/null <<'PY' || echo "?"
import json, sys, datetime
try:
    d = json.load(open(sys.argv[1]))
    t = datetime.datetime.fromisoformat(d[-1]["entered_utc"].replace("Z", "+00:00"))
    print((datetime.datetime.now(datetime.timezone.utc) - t).days)
except Exception:
    print("?")
PY
)"
      notify "jewell watch: heartbeat — record unchanged, seals healthy" \
        "no register changes and no confirmed notifications for 7+ days; watcher alive. Last register change: ${HB_DAYS} days before this run."
      # refresh the latch only if the heartbeat actually went out
      if [ "$(status_rc)" = "0" ]; then
        printf '%s\n' "$NOW_S" > "$HB_FILE" 2>/dev/null || true
      fi
    fi
  fi
fi
