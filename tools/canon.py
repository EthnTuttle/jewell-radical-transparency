#!/usr/bin/env python3
"""Canonical content hash of an iCalendar (.ics) file.

Google re-exports the same calendar with different byte ordering and fresh
DTSTAMP properties on nearly every fetch, so raw SHA-256 churns without any
semantic change. The canonical form:
  1. unfolds wrapped lines (RFC 5545 folding),
  2. drops DTSTAMP properties (transmission metadata),
  3. extracts VEVENT + VTIMEZONE components and sorts them by UID + content,
  4. hashes (remaining skeleton + sorted components) as UTF-8.

Used only for CHANGE DETECTION; archived evidence is always the raw bytes.
Usage: canon.py file.ics  -> prints hex digest
"""
import hashlib
import re
import sys

COMPONENT = re.compile(
    r'^BEGIN:(?:VEVENT|VTIMEZONE)\r?$.*?^END:(?:VEVENT|VTIMEZONE)\r?$',
    re.S | re.M,
)


def canon_hash(path: str) -> str:
    with open(path, encoding='utf-8') as f:  # strict: refuse mojibake
        text = f.read()
    text = text.replace('\r\n', '\n').replace('\r', '\n')
    text = re.sub(r'\n[ \t]', '', text)                   # unfold folded lines
    text = re.sub(r'^DTSTAMP[;:][^\n]*\n', '', text,      # drop DTSTAMP properties,
                  flags=re.M)                             # line and newline together
    blocks = COMPONENT.findall(text)
    blocks.sort(key=lambda b: (_uid(b), b))
    skeleton = COMPONENT.sub('', text)
    return hashlib.sha256((skeleton + '\n'.join(blocks)).encode()).hexdigest()


def _uid(block: str) -> str:
    m = re.search(r'^UID:(.*)$', block, re.M)
    return m.group(1) if m else ''


if __name__ == '__main__':
    print(canon_hash(sys.argv[1]))
