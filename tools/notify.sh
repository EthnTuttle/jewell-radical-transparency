#!/usr/bin/env bash
# notify.sh — fire-and-forget notification via the Marmot nostr DM bot.
#
# Usage: notify.sh "subject" "message body"
#
# CONTRACT: this script NEVER fails its caller. Whatever happens — bot absent,
# nix eval timeout, relay down — it exits 0. Notification failures are recorded
# in $STATE_DIR/notify.log and (on a real send attempt) warned to stderr,
# nothing more.
#
# Spool & drain (the bell must not depend on the thing that's broken):
#   - If the bot is absent OR a send fails, the notification is appended to
#     $SPOOL as <unixts>-<rand>.json ({"ts","subject","body"}, mode 600 via
#     umask 077), logged NOT SENT, and we exit 0.
#   - On every run where the bot IS invocable we FIRST drain the spool: oldest
#     file first, at most 20 per run, each sent as
#     "<subject>\n\n<body> [drained from <ts>]"; a spool file is deleted only
#     after a confirmed success (bot exit 0). Then the current message is sent.
#
# Every run also writes a machine-readable status line to $STATUS
# ("last_rc=<n> last_ok_ts=<unix>", atomic-ish via tmp + mv), so callers can
# tell a confirmed send from a spooled/lost one.
umask 077
PROJECT_DIR="/home/ethan/code/jewell"
BOT="$PROJECT_DIR/bot/marmot_bot.py"
PYBOT="$PROJECT_DIR/.venv-bot/bin/python"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/jewell"
LOG="$STATE_DIR/notify.log"
SPOOL="$STATE_DIR/spool"
STATUS="$STATE_DIR/notify.status"
SUBJECT="${1:-}"
BODY="${2:-}"

mkdir -p "$STATE_DIR" "$SPOOL" 2>/dev/null || true
stamp() { date -u +%FT%TZ; }

LAST_RC=1       # rc of the most recent bot invocation this run (1 = none yet / failed)
LAST_OK_TS=""   # unix ts of the most recent confirmed-successful send this run

write_status() { # atomic-ish; must never break the caller
  local tmp="$STATUS.tmp.$$"
  if printf 'last_rc=%s last_ok_ts=%s\n' "$LAST_RC" "$LAST_OK_TS" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$STATUS" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# Log preview cut at a code-point boundary, so a mid-UTF-8 slice can't corrupt
# the log line; falls back to `cut -c` when python3 is absent.
preview() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys; sys.stdout.write(sys.stdin.read(4096)[:120].replace("\n", " "))' \
      <<< "$1" 2>/dev/null || printf '%s' "$1" | cut -c1-120
  else
    printf '%s' "$1" | cut -c1-120
  fi
}

json_escape() { # python3-free JSON string escaping (spool fallback path only)
  awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); if(NR>1) printf "\\n"; printf "%s",$0}' <<< "$1"
}

spool_msg() { # persist the current SUBJECT/BODY as an unsent notification
  mkdir -p "$SPOOL" 2>/dev/null || return 0
  local ts f
  ts="$(date +%s)"
  f="$SPOOL/${ts}-$RANDOM.json"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.dump({"ts":int(sys.argv[1]),"subject":sys.argv[2],"body":sys.argv[3]}, open(sys.argv[4],"w"), ensure_ascii=False)' \
      "$ts" "$SUBJECT" "$BODY" "$f" 2>/dev/null || true
  else
    printf '{"ts":%s,"subject":"%s","body":"%s"}\n' \
      "$ts" "$(json_escape "$SUBJECT")" "$(json_escape "$BODY")" > "$f" 2>/dev/null || true
  fi
  return 0
}

send_raw() { # one bot invocation; sets LAST_RC / LAST_OK_TS; returns the bot rc
  local rc
  if timeout --kill-after=30 120 nix develop "$PROJECT_DIR" -c "$PYBOT" "$BOT" send "$1" >> "$LOG" 2>&1; then
    rc=0
    LAST_OK_TS="$(date +%s)"
  else
    rc=$?
  fi
  LAST_RC=$rc
  return $rc
}

drain_spool() { # send queued notifications; delete each file ONLY on bot exit 0
  [ -d "$SPOOL" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[notify $(stamp)] python3 absent; spool drain deferred" >> "$LOG" 2>/dev/null || true
    return 0
  fi
  local f n=0 s_ts s_sub s_body
  for f in "$SPOOL"/*.json; do   # lexical sort == chronological (fixed-width unix ts)
    [ -e "$f" ] || continue
    [ "$n" -ge 20 ] && break     # cap: at most 20 drained per run
    n=$((n+1))
    s_ts=""; s_sub=""; s_body=""
    {
      IFS= read -r -d '' s_ts
      IFS= read -r -d '' s_sub
      IFS= read -r -d '' s_body || true
    } < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.stdout.write(str(d.get("ts",""))+"\0"+str(d.get("subject",""))+"\0"+str(d.get("body","")))' "$f" 2>/dev/null)
    if [ -z "$s_sub" ]; then
      echo "[notify $(stamp)] spool file unreadable, kept: $f" >> "$LOG" 2>/dev/null || true
      continue
    fi
    if send_raw "$s_sub

$s_body [drained from $s_ts]"; then
      rm -f "$f" 2>/dev/null || true
      echo "[notify $(stamp)] drained OK (spooled $s_ts): $s_sub" >> "$LOG" 2>/dev/null || true
    else
      echo "[notify $(stamp)] drain FAILED (rc=$LAST_RC; kept): $s_sub" >> "$LOG" 2>/dev/null || true
    fi
  done
  return 0
}

if [ -z "$SUBJECT" ]; then
  echo "[notify $(stamp)] missing subject; ignored" >> "$LOG" 2>/dev/null || true
  write_status
  exit 0
fi

MESSAGE="$SUBJECT

$BODY"

# Bot binary absent (or not yet built): spool, note, and move on quietly.
if [ ! -f "$BOT" ]; then
  echo "[notify $(stamp)] bot absent ($BOT); NOT SENT (spooled): $SUBJECT -- $(preview "$BODY")" \
    >> "$LOG" 2>/dev/null || true
  spool_msg
  write_status
  exit 0
fi

# Bot invocable: drain anything queued FIRST, then send the current message.
drain_spool

echo "[notify $(stamp)] sending: $SUBJECT" >> "$LOG" 2>/dev/null || true
if send_raw "$MESSAGE"; then
  echo "[notify $(stamp)] sent OK: $SUBJECT" >> "$LOG" 2>/dev/null || true
else
  echo "[notify $(stamp)] send FAILED (rc=$LAST_RC); NOT SENT (spooled): $SUBJECT -- $(preview "$BODY")" \
    >> "$LOG" 2>/dev/null || true
  echo "notify.sh: WARNING: notification failed (rc=$LAST_RC), swallowed + spooled: $SUBJECT" >&2
  spool_msg
fi
write_status
exit 0
