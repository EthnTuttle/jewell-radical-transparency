# John Jewell: A Study in Radical Transparency

A static page celebrating the publicly accessible Google Calendar of
John Jewell, Chairman of the Frederick County (VA) Board of Supervisors,
and the OpenTimestamps proof anchoring its October 2026 snapshot in the
Bitcoin blockchain.

## Contents

- `index.html` — the page (self-contained, no dependencies)
- `jewell-latest.ics` — public feed exported via Google's public iCal endpoint on 2026-10-21 (~01:21 UTC)
- `jewell-latest.ics.ots` — OpenTimestamps proof for the file above

## Verify

```bash
sha256sum jewell-latest.ics
# c6372c684440b9e845587084105d8c73d2652c363389fdb6a6b517c86828670a

pip install opentimestamps-client
ots upgrade jewell-latest.ics.ots   # once the Bitcoin tx confirms
ots verify jewell-latest.ics.ots    # requires a local Bitcoin node
```

Or press "Inspect the Seal in This Browser" on the page — it verifies the
newest register entry entirely client-side (file hash + on-chain attestation,
via the public Esplora API).

## Rolling register

- `snapshots/YYYY-MM-DD/` — one archived capture (+ proof) per UTC day on
  which the feed's *canonicalized* content changed
- `snapshots/snapshots.json` — manifest consumed by the page ledger
- `tools/snapshot.sh` — daily watcher (cron): fetch → canonical compare
  (`tools/canon.py`) → stamp raw bytes → upgrade pending proofs → harvest
  block heights from `ots info` (no bitcoind needed) → self-check → push
- Horizon: the watcher self-terminates after **2027-04-21** (≈6-month window)

### Alerting

`tools/notify.sh "subject" "body"` sends a nostr DM via the Marmot bot
(`bot/marmot_bot.py`, run under `nix develop`). It is strictly
fire-and-forget: bot absent, timeout, or send failure are logged to
`~/.local/state/jewell/notify.log` and swallowed (always exits 0), so the
watcher can never be broken by a failed notification. `snapshot.sh` calls
it on: new snapshot sealed, seal anchored to a block, ANOMALY rejection,
watcher failure (EXIT trap), and horizon conclusion (once). The no-change
path stays silent.

Operator notes:
- **Spool/drain:** if the bot is absent or a send fails, the notification is
  queued to `~/.local/state/jewell/spool/<unixts>-<rand>.json` (mode 600) and
  drained — oldest first, ≤20 per run, suffixed `[drained from <ts>]` — on the
  next run with a working bot; a file is deleted only after a confirmed send.
- **Heartbeat:** if a run sends nothing and the last confirmed-OK send is
  >7 days old, the watcher emits "record unchanged, seals healthy" (with
  days-since-last-change), so a dead notification path can't masquerade as a
  quiet register.
- **Machine-readable status:** each `notify.sh` run writes
  `last_rc=<n> last_ok_ts=<unix>` to `~/.local/state/jewell/notify.status`
  (tmp + mv); `snapshot.sh` refreshes its heartbeat latch only when `last_rc=0`.

## Vendored assets

- `vendor/opentimestamps.min.js` — opentimestamps v0.4.9 official browser
  bundle (from opentimestamps.org), sha256
  `f6181ae00cce58773f8710894c99d0656058f6a1e08c57360b263cd46c54fbf2`

