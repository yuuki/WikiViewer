#!/usr/bin/env python3
"""Writes what the Graph tab shows about each cluster and between clusters
(#39), for `wikiindex --extras DIR`:

    python3 scripts/export-graph-lens.py --vault VAULT --state STATE --out EXTRAS [--summarize]

- EXTRAS/cluster-notes.json: per cluster of the indexer's link graph
  (STATE/graph-clusters.json, written by wikiindex), its open questions —
  the `## 未解決の問い` items of the cluster's most linked concept pages —
  and, with --summarize, a two- or three-sentence summary by Claude. A
  summary is kept until the cluster's members change (less than 70% of the
  members it was written from are still among them), so only changed
  clusters cost a Claude call (--max-summaries per run).
- EXTRAS/gaps.json: gap candidates from the vault's wiki-gap reports
  (wiki/meta/gap-report-*.md, newest first): the two sides, the reasoning,
  the recommended bridging literature and the verdict. Gaps the report
  judged intentional are left out.

The vault is only read. Claude, when used, gets read-only tools (Read,
Grep, Glob) and no web access.

Environment: CLAUDE_BIN, WIKIVIEWER_CLAUDE_MODEL, WIKIVIEWER_MAX_BUDGET_USD
(per summary, default 1).
"""

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

QUESTION_HEADING = "## 未解決の問い"
QUESTIONS_PER_CONCEPT = 2
QUESTIONS_PER_CLUSTER = 6
KEEP_SUMMARY_OVERLAP = 0.7


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}-", delete=False) as tmp:
        json.dump(value, tmp, ensure_ascii=False, indent=1)
    os.chmod(tmp.name, 0o644)
    os.replace(tmp.name, path)


def read(vault, rel):
    try:
        return (vault / rel).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


def section(text, heading):
    """Lines under a `## heading` up to the next level-2 heading."""
    lines = text.splitlines()
    out, inside = [], False
    for line in lines:
        if line.startswith("## "):
            if inside:
                break
            inside = line.strip() == heading or line.strip().startswith(heading)
            continue
        if inside:
            out.append(line)
    return out


def open_questions(text):
    questions = []
    for line in section(text, QUESTION_HEADING):
        if not line.startswith("- "):
            continue  # nested lines explain an item
        item = line[2:].strip()
        if not item or "今後の ingest" in item or item.startswith("（") and item.endswith("）"):
            continue
        questions.append(re.sub(r"\s+", " ", item)[:300])
    return questions


# MARK: Gaps

def parse_gap_report(text, report):
    gaps, verdict, current = [], None, None

    def close():
        if current and current["sides"] and verdict != "intentional":
            current["detail"] = "\n".join(current.pop("lines")).strip()
            current["verdict"] = verdict
            gaps.append(current)

    table_header = None
    for line in text.splitlines():
        if line.startswith("## "):
            close()
            current = None
            title = line[3:]
            verdict = "real-gap" if "実在" in title else "weak" if "弱" in title else "intentional" if "意図" in title else None
            continue
        if line.startswith("### "):
            close()
            title = re.sub(r"^\d+\.\s*", "", line[4:].strip())
            current = {"title": title, "sides": [], "recommendations": [], "lines": [], "report": report}
            table_header = None
            continue
        if current is None:
            continue
        stripped = line.strip()
        if stripped.startswith("**両側**"):
            current["sides"] = re.findall(r"\[\[([^\]|#]+)", stripped)[:2]
            continue
        if stripped.startswith("|"):
            cells = [c.strip() for c in stripped.strip("|").split("|")]
            if table_header is None:
                table_header = cells
            elif not all(set(c) <= set("-: ") for c in cells):
                row = dict(zip(table_header, cells))
                title = row.get("タイトル") or (cells[1] if len(cells) > 1 else "")
                ident = row.get("識別子", "")
                state = row.get("状態", "").replace("*", "")
                current["recommendations"].append(" — ".join(x for x in [title, ident, state] if x))
            continue
        table_header = None
        if stripped == "---":
            continue
        if stripped.startswith(("**構造的証拠**", "**判定根拠**", "**推奨アクション**")):
            current["lines"].append(stripped.replace("**", ""))
    close()
    for gap in gaps:
        if len(gap["sides"]) != 2:
            gap["sides"] = []
    return [g for g in gaps if g["sides"]]


def export_gaps(vault, limit_reports):
    reports = sorted((vault / "wiki" / "meta").glob("gap-report-*.md"), reverse=True)[:limit_reports]
    gaps, seen = [], set()
    for path in reports:
        rel = str(path.relative_to(vault))
        for gap in parse_gap_report(path.read_text(encoding="utf-8"), rel):
            key = tuple(sorted(gap["sides"]))
            if key in seen:
                continue  # the newest report's judgement wins
            seen.add(key)
            gaps.append(gap)
    return {"gaps": gaps}


# MARK: Cluster notes

def summarize(vault, cluster):
    claude = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
    if not claude:
        raise RuntimeError("claude is not on PATH")
    members = "\n".join(f"- {m['path']}({m['title']})" for m in cluster["members"][:15])
    prompt = f"""vault のリンクグラフのクラスタ「{cluster['label']}」({cluster['size']} ノート)が何の話かを要約する。
よくリンクされるノート:
{members}

これらのノートを Read で読み(全文でなく定義と主題節と `## 未解決の問い` で足りる)、
- summary: このクラスタが何の話か、日本語常体で 2〜3 文。固有の論点を具体的に。
- questions: このクラスタでまだ分かっていない問いを最大 5 つ。各ページの未解決の問いから重要なものを選ぶか、ページ間の食い違いから立てる。
を返す。ファイルは書かない。"""
    schema = {"type": "object", "properties": {"summary": {"type": "string"}, "questions": {"type": "array", "items": {"type": "string"}}},
              "required": ["summary", "questions"]}
    cmd = [claude, "-p", prompt, "--output-format", "json", "--json-schema", json.dumps(schema),
           "--allowedTools", "Read", "Grep", "Glob", "--disallowedTools", "Write", "Edit", "Bash", "WebFetch", "WebSearch",
           "--max-budget-usd", os.environ.get("WIKIVIEWER_MAX_BUDGET_USD", "1"), "--no-session-persistence"]
    if os.environ.get("WIKIVIEWER_CLAUDE_MODEL"):
        cmd += ["--model", os.environ["WIKIVIEWER_CLAUDE_MODEL"]]
    proc = subprocess.run(cmd, cwd=vault, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    envelope = json.loads(proc.stdout or "{}")
    if proc.returncode != 0 or envelope.get("is_error"):
        raise RuntimeError(str(envelope.get("result") or proc.stderr.strip()[-200:]))
    result = envelope.get("structured_output") or json.loads(envelope.get("result", "{}"))
    return result.get("summary"), result.get("questions") or []


def export_cluster_notes(vault, clusters, previous, do_summarize, max_summaries):
    by_id = {c["id"]: c for c in previous.get("clusters", [])}
    out, summarized = [], 0
    for cluster in clusters:
        members = [m["path"] for m in cluster["members"]]
        questions = []
        for member in cluster["members"]:
            if member.get("type") != "concept" or len(questions) >= QUESTIONS_PER_CLUSTER:
                continue
            for q in open_questions(read(vault, member["path"]))[:QUESTIONS_PER_CONCEPT]:
                questions.append(f"{q}({member['title']})")
        entry = {"id": cluster["id"], "members": members, "questions": questions[:QUESTIONS_PER_CLUSTER]}
        old = by_id.get(cluster["id"])
        old_members = set((old or {}).get("members") or [])
        unchanged = old and old_members and len(old_members & set(members)) / len(old_members) >= KEEP_SUMMARY_OVERLAP
        if unchanged and old.get("summary"):
            entry["summary"] = old["summary"]
            entry["members"] = old["members"]  # what the summary was written from
            entry["generated_at"] = old.get("generated_at")
            if old.get("claude_questions"):
                entry["claude_questions"] = old["claude_questions"]
                entry["questions"] = (old["claude_questions"] + entry["questions"])[:QUESTIONS_PER_CLUSTER]
        elif do_summarize and summarized < max_summaries:
            try:
                summary, claude_questions = summarize(vault, cluster)
                summarized += 1
                entry["summary"] = summary
                entry["claude_questions"] = claude_questions[:5]
                entry["questions"] = (claude_questions[:5] + entry["questions"])[:QUESTIONS_PER_CLUSTER]
                entry["generated_at"] = datetime.date.today().isoformat()
            except Exception as e:  # keep going; the cluster is summarized next time
                print(f"summary of cluster {cluster['id']} failed: {e}", file=sys.stderr)
        if entry.get("summary") or entry["questions"]:
            out.append(entry)
    print(f"{len(out)} clusters with notes, {summarized} summarized", file=sys.stderr)
    return {"clusters": out}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--vault", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path, help="wikiindex --state (for graph-clusters.json)")
    parser.add_argument("--out", required=True, type=Path, help="the extras directory")
    parser.add_argument("--summarize", action="store_true", help="ask Claude for summaries of new or changed clusters")
    parser.add_argument("--max-summaries", type=int, default=10)
    parser.add_argument("--reports", type=int, default=5, help="newest gap reports to read")
    args = parser.parse_args()
    vault, out = args.vault.resolve(), args.out.resolve()
    if out == vault or vault in out.parents:
        sys.exit("--out must be outside the vault")

    write_json(out / "gaps.json", export_gaps(vault, args.reports))
    export = args.state / "graph-clusters.json"
    if not export.is_file():
        sys.exit(f"{export} not found: run wikiindex build or watch first")
    clusters = json.loads(export.read_text(encoding="utf-8"))["clusters"]
    previous_path = out / "cluster-notes.json"
    previous = json.loads(previous_path.read_text(encoding="utf-8")) if previous_path.is_file() else {}
    write_json(previous_path, export_cluster_notes(vault, clusters, previous, args.summarize, args.max_summaries))


if __name__ == "__main__":
    main()
