#!/usr/bin/env python3
"""What the reader has been reading (#42), for the vault's skills.

WikiViewer devices send their reading history to the Mac, where
`wikiindex requests --signals DIR` keeps it outside the vault and writes
DIR/summary.json. This script answers the questions the skills ask of it:

    python3 scripts/reading-signals.py top --signals DIR [--days 30] [--limit 20]
        Notes read the most (by time on screen), with pins: for ranking
        what hn-curation and wiki-survey-recommend propose.

    python3 scripts/reading-signals.py unconceptualized --signals DIR --vault VAULT [--min-seconds 60]
        Source pages (wiki/sources/) read for at least --min-seconds that no
        concept page (wiki/concepts/) links to or lists in `sources:` yet —
        candidates for folding into concepts (wiki-refactor).

Output is JSON on stdout. Nothing is written anywhere.
"""

import argparse
import datetime
import json
import re
import sys
from pathlib import Path


def load_summary(signals):
    path = Path(signals) / "summary.json"
    if not path.is_file():
        sys.exit(f"{path} not found: no reading history has been received yet")
    return json.loads(path.read_text(encoding="utf-8"))


def parse_date(value):
    if not value:
        return None
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def top(args):
    summary = load_summary(args.signals)
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=args.days)
    notes = [n for n in summary["notes"] if n.get("pinned") or (parse_date(n.get("lastRead")) or since) >= since]
    notes.sort(key=lambda n: (n.get("pinned", False), n.get("seconds", 0)), reverse=True)
    return notes[: args.limit]


def unconceptualized(args):
    summary = load_summary(args.signals)
    vault = Path(args.vault)
    concepts = vault / "wiki" / "concepts"
    text = "\n".join(p.read_text(encoding="utf-8", errors="ignore") for p in concepts.glob("*.md")) if concepts.is_dir() else ""
    linked = set(re.findall(r"\[\[([^\]|#]+)", text))
    out = []
    for note in summary["notes"]:
        path = note["path"]
        if not path.startswith("wiki/sources/") or note.get("seconds", 0) < args.min_seconds:
            continue
        stem = Path(path).stem
        if stem in linked or f"wiki/sources/{stem}" in linked:
            continue
        out.append({"path": path, "title": note.get("title"), "seconds": note.get("seconds"), "lastRead": note.get("lastRead")})
    out.sort(key=lambda n: n["seconds"], reverse=True)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("top")
    p.add_argument("--signals", required=True)
    p.add_argument("--days", type=int, default=30)
    p.add_argument("--limit", type=int, default=20)
    p = sub.add_parser("unconceptualized")
    p.add_argument("--signals", required=True)
    p.add_argument("--vault", required=True)
    p.add_argument("--min-seconds", type=int, default=60)
    args = parser.parse_args()
    result = top(args) if args.command == "top" else unconceptualized(args)
    print(json.dumps(result, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
