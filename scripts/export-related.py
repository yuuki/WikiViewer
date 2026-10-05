#!/usr/bin/env python3
"""Exports the vault's role-labelled neighbours (wiki-related) for every
wiki page, for `wikiindex --extras DIR` (#38).

    python3 scripts/export-related.py --vault /path/to/Vault --out /path/to/extras/related.jsonl

It loads the vault's own `scripts/wiki-related.py` and calls its
`related_for` once per page of the wiki graph (`.vault-meta/graph.json`),
with the graph, the clusters and the contradiction records loaded once.
It only reads the vault: passing them in disables wiki-related's cache, so
nothing is written under `.vault-meta/`. The output goes to a file outside
the vault, replaced atomically, one JSON object per line:

    {"seed": "wiki/concepts/X.md", "roles": {"definition": [{"page_path": "...", "why": "..."}], ...}}

Run it after the vault's graph is rebuilt (wiki-retrieve-refresh), e.g.
nightly from a LaunchAgent; `wikiindex watch` publishes the change.
"""

import argparse
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path


def load_related(vault):
    script = vault / "scripts" / "wiki-related.py"
    if not script.is_file():
        sys.exit(f"{script} not found: is this the research vault?")
    os.environ["WIKI_VAULT_ROOT"] = str(vault)
    spec = importlib.util.spec_from_file_location("wiki_related", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--vault", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--limit", type=int, default=0, help="only the first N pages (testing)")
    args = parser.parse_args()
    vault = args.vault.resolve()
    out = args.out.resolve()
    if out == vault or vault in out.parents:
        sys.exit("--out must be outside the vault")

    related = load_related(vault)
    graph = related.graph_mod.load_graph(vault / ".vault-meta" / "graph.json")
    if not graph:
        sys.exit("the vault has no .vault-meta/graph.json (run wiki-retrieve-refresh first)")
    clusters = related.clusters_mod.load_clusters(vault / ".vault-meta" / "clusters.json") or {}
    records = related.load_contradiction_records(graph, vault)

    seeds = sorted(graph.get("nodes") or {})
    if args.limit:
        seeds = seeds[: args.limit]
    out.parent.mkdir(parents=True, exist_ok=True)
    written = 0
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=out.parent, prefix=".related-", delete=False) as tmp:
        for seed in seeds:
            try:
                code, payload = related.related_for(seed, graph=graph, clusters=clusters, records=records, root=vault, use_cache=False)
            except Exception as e:  # one bad page must not stop the export
                print(f"skip {seed}: {e}", file=sys.stderr)
                continue
            if code != 0:
                continue
            roles = {
                role: [{"page_path": c["page_path"], "why": c.get("why", "")} for c in candidates]
                for role, candidates in (payload.get("roles") or {}).items()
                if candidates
            }
            if roles:
                tmp.write(json.dumps({"seed": seed, "roles": roles}, ensure_ascii=False) + "\n")
                written += 1
    os.chmod(tmp.name, 0o644)
    os.replace(tmp.name, out)
    print(f"wrote {written} pages to {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
