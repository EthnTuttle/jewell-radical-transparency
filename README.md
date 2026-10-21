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

## Vendored assets

- `vendor/opentimestamps.min.js` — opentimestamps v0.4.9 official browser
  bundle (from opentimestamps.org), sha256
  `f6181ae00cce58773f8710894c99d0656058f6a1e08c57360b263cd46c54fbf2`

