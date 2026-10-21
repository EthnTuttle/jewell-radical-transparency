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
ots verify jewell-latest.ics.ots
```
