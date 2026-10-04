#!/usr/bin/env python3
"""Makes recall questions about notes read a few days ago (#40), for
`wikiindex --extras DIR`:

    python3 scripts/make-recall.py --signals SIGNALS --vault VAULT --out EXTRAS [--mechanical]

It reads the reading history the devices sent (SIGNALS/summary.json, see
`wikiindex requests --signals`), picks notes last read between
--min-days and --max-days ago for at least --min-seconds that have no
questions yet, and writes questions with answers and the section they come
from into EXTRAS/recall.json (existing questions are kept; the app keeps
its own schedule per question id). Run it nightly.

By default Claude writes the questions (read-only tools, no web; one call
per note, --max-notes per run). --mechanical makes simple questions from
the note's sections instead, without Claude.

Environment: CLAUDE_BIN, WIKIVIEWER_CLAUDE_MODEL, WIKIVIEWER_MAX_BUDGET_USD
(per note, default 0.5).
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

KEEP_ITEMS = 2000


def item_id(note, question):
    return hashlib.sha1(f"{note}\n{question}".encode()).hexdigest()[:16]


def plain(text):
    text = re.sub(r"!\[\[[^\]]*\]\]", "", text)  # embeds
    text = re.sub(r"\[![^\]]*\][+-]?", "", text)  # callout markers
    text = re.sub(r"(^|\s)\^[A-Za-z0-9-]+", " ", text)  # block ids
    text = re.sub(r"\[\[([^\]|#]*)(?:#[^\]|]*)?(?:\|([^\]]*))?\]\]", lambda m: m.group(2) or m.group(1).split("/")[-1], text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[*_`>]+", "", text)
    return re.sub(r"\s+", " ", text).strip()


def sections(body):
    """(heading, text) for each level-2/3 section with some prose."""
    out, heading, lines = [], None, []
    in_fence = False
    for line in body.splitlines():
        if line.strip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = re.match(r"^(#{2,3})\s+(.*)", line)
        if m:
            if heading:
                out.append((heading, plain(" ".join(lines))))
            heading, lines = m.group(2).strip(), []
        elif heading and line.strip() and not line.startswith("|"):
            lines.append(line)
    if heading:
        out.append((heading, plain(" ".join(lines))))
    return [(h, t) for h, t in out if len(t) >= 40 and h not in ("出典", "関連", "Sources", "References")]


def strip_frontmatter(text):
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end >= 0:
            return text[end + 4:]
    return text


def mechanical(vault, note, title, per_note):
    body = strip_frontmatter((vault / note).read_text(encoding="utf-8", errors="ignore"))
    items = []
    for heading, text in sections(body)[:per_note]:
        question = f"「{title}」の「{heading}」は何を述べていたか。"
        items.append({"heading": heading, "question": question, "answer": text[:600]})
    return items


def with_claude(vault, note, title, per_note):
    claude = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
    if not claude:
        raise RuntimeError("claude is not on PATH (use --mechanical)")
    prompt = f"""読者が数日前に読んだノート `{note}`(題: {title})について、思い出す練習の問いを {per_note} つ作る。
ノートを Read で読み、
- 本文の要点を思い出せたかを確かめる問い(用語の暗記ではなく、主張・理由・条件・対比を問う)
- 答えはノートの記述に基づき 1〜3 文。ノートに無いことは答えにしない
- heading には答えが書かれている節の見出し(# は付けない)
を返す。ファイルは書かない。日本語常体。"""
    schema = {"type": "object", "properties": {"items": {"type": "array", "items": {"type": "object", "properties": {
        "question": {"type": "string"}, "answer": {"type": "string"}, "heading": {"type": ["string", "null"]}},
        "required": ["question", "answer"]}}}, "required": ["items"]}
    cmd = [claude, "-p", prompt, "--output-format", "json", "--json-schema", json.dumps(schema),
           "--allowedTools", "Read", "--disallowedTools", "Write", "Edit", "Bash", "WebFetch", "WebSearch",
           "--max-budget-usd", os.environ.get("WIKIVIEWER_MAX_BUDGET_USD", "0.5"), "--no-session-persistence"]
    if os.environ.get("WIKIVIEWER_CLAUDE_MODEL"):
        cmd += ["--model", os.environ["WIKIVIEWER_CLAUDE_MODEL"]]
    proc = subprocess.run(cmd, cwd=vault, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    envelope = json.loads(proc.stdout or "{}")
    if proc.returncode != 0 or envelope.get("is_error"):
        raise RuntimeError(str(envelope.get("result") or proc.stderr.strip()[-200:]))
    result = envelope.get("structured_output") or json.loads(envelope.get("result", "{}"))
    return (result.get("items") or [])[:per_note]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--signals", required=True, type=Path)
    parser.add_argument("--vault", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path, help="the extras directory")
    parser.add_argument("--min-days", type=float, default=2)
    parser.add_argument("--max-days", type=float, default=14)
    parser.add_argument("--min-seconds", type=int, default=60)
    parser.add_argument("--max-notes", type=int, default=10)
    parser.add_argument("--per-note", type=int, default=3)
    parser.add_argument("--mechanical", action="store_true", help="questions from the note's sections, without Claude")
    args = parser.parse_args()
    vault, out = args.vault.resolve(), args.out.resolve()
    if out == vault or vault in out.parents:
        sys.exit("--out must be outside the vault")

    summary = json.loads((args.signals / "summary.json").read_text(encoding="utf-8"))
    path = out / "recall.json"
    existing = json.loads(path.read_text(encoding="utf-8"))["items"] if path.is_file() else []
    asked = {item["note"] for item in existing}
    now = datetime.datetime.now(datetime.timezone.utc)
    candidates = []
    for note in summary["notes"]:
        last = note.get("lastRead")
        if not last or note["path"] in asked or note.get("seconds", 0) < args.min_seconds:
            continue
        age = (now - datetime.datetime.fromisoformat(last.replace("Z", "+00:00"))).total_seconds() / 86400
        if args.min_days <= age <= args.max_days and (vault / note["path"]).is_file():
            candidates.append(note)
    candidates.sort(key=lambda n: n.get("seconds", 0), reverse=True)

    today = datetime.date.today().isoformat()
    made = []
    for note in candidates[: args.max_notes]:
        try:
            make = mechanical if args.mechanical else with_claude
            for q in make(vault, note["path"], note.get("title") or Path(note["path"]).stem, args.per_note):
                made.append({"id": item_id(note["path"], q["question"]), "note": note["path"], "heading": q.get("heading"),
                             "question": q["question"], "answer": q["answer"], "created": today})
        except Exception as e:  # the note gets questions next time
            print(f"skip {note['path']}: {e}", file=sys.stderr)
    items = sorted(existing + made, key=lambda i: (i["created"], i["id"]), reverse=True)[:KEEP_ITEMS]
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=out, prefix=".recall-", delete=False) as tmp:
        json.dump({"items": items}, tmp, ensure_ascii=False, indent=1)
    os.chmod(tmp.name, 0o644)
    os.replace(tmp.name, path)
    print(f"{len(made)} new questions about {len({m['note'] for m in made})} notes; {len(items)} kept", file=sys.stderr)


if __name__ == "__main__":
    main()
